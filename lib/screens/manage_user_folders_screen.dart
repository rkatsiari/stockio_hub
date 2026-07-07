import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

enum _FolderVisibilityFilter {
  all,
  visible,
  hidden,
}

class ManageUserFoldersScreen extends StatefulWidget {
  final String tenantId;
  final String userId;
  final String userName;
  final String userEmail;

  const ManageUserFoldersScreen({
    super.key,
    required this.tenantId,
    required this.userId,
    required this.userName,
    required this.userEmail,
  });

  @override
  State<ManageUserFoldersScreen> createState() =>
      _ManageUserFoldersScreenState();
}

class _ManageUserFoldersScreenState extends State<ManageUserFoldersScreen> {
  final Set<String> _expandedFolderIds = <String>{};
  final Set<String> _savingFolderIds = <String>{};

  Set<String>? _optimisticVisibleFolderIds;

  _FolderVisibilityFilter _filter = _FolderVisibilityFilter.all;

  DocumentReference<Map<String, dynamic>> get _userRef {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("users")
        .doc(widget.userId);
  }

  CollectionReference<Map<String, dynamic>> get _foldersRef {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("folders");
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xff0B1E40),
      iconTheme: const IconThemeData(color: Colors.white),
      title: Text(
        widget.userName.trim().isEmpty ? "User Folders" : widget.userName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  List<_FolderNode> _buildFolderTree(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
      ) {
    final nodesById = <String, _FolderNode>{};

    for (final doc in docs) {
      final data = doc.data();

      final name = (data["name"] ?? "Unnamed folder").toString().trim();
      final parentId = (data["parentId"] ?? "").toString().trim();

      nodesById[doc.id] = _FolderNode(
        id: doc.id,
        name: name.isEmpty ? "Unnamed folder" : name,
        parentId: parentId.isEmpty ? null : parentId,
      );
    }

    final roots = <_FolderNode>[];

    for (final node in nodesById.values) {
      final parentId = node.parentId;

      if (parentId == null || !nodesById.containsKey(parentId)) {
        roots.add(node);
      } else {
        final parentNode = nodesById[parentId]!;
        node.parentName = parentNode.name;
        parentNode.children.add(node);
      }
    }

    void sortNodes(List<_FolderNode> nodes) {
      nodes.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );

      for (final node in nodes) {
        sortNodes(node.children);
      }
    }

    sortNodes(roots);

    void assignBreadcrumbs(
        List<_FolderNode> nodes,
        List<String> parentPathNames,
        ) {
      for (final node in nodes) {
        node.parentBreadcrumb = parentPathNames.isEmpty
            ? null
            : parentPathNames.join(" > ");

        assignBreadcrumbs(
          node.children,
          [...parentPathNames, node.name],
        );
      }
    }

    assignBreadcrumbs(roots, <String>[]);

    return roots;
  }

  Set<String> _readVisibleFolderIds({
    required Map<String, dynamic>? userData,
    required Set<String> allFolderIds,
  }) {
    final raw = userData?["visibleFolderIds"];

    // If visibleFolderIds does not exist yet,
    // the user can see all folders by default.
    if (raw == null) {
      return Set<String>.from(allFolderIds);
    }

    if (raw is Iterable) {
      return raw.map((e) => e.toString()).toSet();
    }

    return Set<String>.from(allFolderIds);
  }

  Set<String> _collectSelfAndDescendantIds(_FolderNode node) {
    final ids = <String>{node.id};

    for (final child in node.children) {
      ids.addAll(_collectSelfAndDescendantIds(child));
    }

    return ids;
  }

  Map<String, _FolderNode> _flattenFolderNodes(List<_FolderNode> roots) {
    final nodesById = <String, _FolderNode>{};

    void walk(_FolderNode node) {
      nodesById[node.id] = node;

      for (final child in node.children) {
        walk(child);
      }
    }

    for (final root in roots) {
      walk(root);
    }

    return nodesById;
  }

  Set<String> _collectSelfAndAncestorIds(
      _FolderNode node,
      Map<String, _FolderNode> nodesById,
      ) {
    final ids = <String>{node.id};
    String? parentId = node.parentId;

    while (parentId != null && parentId.trim().isNotEmpty) {
      final parent = nodesById[parentId];
      if (parent == null) break;

      ids.add(parent.id);
      parentId = parent.parentId;
    }

    return ids;
  }

  bool _passesFilter({
    required bool isVisible,
  }) {
    switch (_filter) {
      case _FolderVisibilityFilter.all:
        return true;
      case _FolderVisibilityFilter.visible:
        return isVisible;
      case _FolderVisibilityFilter.hidden:
        return !isVisible;
    }
  }

  Future<void> _toggleFolderVisibility({
    required _FolderNode node,
    required bool currentlyVisible,
    required Set<String> visibleFolderIds,
    required Map<String, _FolderNode> nodesById,
  }) async {
    if (_savingFolderIds.contains(node.id)) return;

    final nextVisibleFolderIds = Set<String>.from(visibleFolderIds);

    if (currentlyVisible) {
      // Hide the selected folder + every direct/nested subfolder.
      // This applies to both main folders and subfolders.
      final selfAndDescendantIds = _collectSelfAndDescendantIds(node);
      nextVisibleFolderIds.removeAll(selfAndDescendantIds);
    } else {
      final isMainFolder = node.parentId == null || node.parentId!.trim().isEmpty;

      if (isMainFolder) {
        // If a main/parent folder is shown, show all folders inside it too.
        final selfAndDescendantIds = _collectSelfAndDescendantIds(node);
        nextVisibleFolderIds.addAll(selfAndDescendantIds);
      } else {
        // If only a subfolder is shown, show that subfolder and its ancestors
        // so the user can reach it, but do not show that subfolder's children.
        final selfAndAncestorIds = _collectSelfAndAncestorIds(node, nodesById);
        nextVisibleFolderIds.addAll(selfAndAncestorIds);
      }
    }

    setState(() {
      _savingFolderIds.add(node.id);
      _optimisticVisibleFolderIds = nextVisibleFolderIds;
    });

    try {
      await _userRef.set(
        {
          "visibleFolderIds": nextVisibleFolderIds.toList(),
          "folderAccessUpdatedAt": FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (_) {
      _showMessage("Could not update folder visibility. Please try again.");

      if (mounted) {
        setState(() {
          _optimisticVisibleFolderIds = null;
        });
      }
    } finally {
      if (!mounted) return;

      setState(() {
        _savingFolderIds.remove(node.id);
      });
    }
  }

  Widget _filterButton({
    required _FolderVisibilityFilter filter,
    required IconData icon,
    required String label,
  }) {
    final selected = _filter == filter;

    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          setState(() => _filter = filter);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xff0B1E40) : const Color(0xFFE1E2EA),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: selected ? Colors.white : const Color(0xFF444750),
                size: 21,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : const Color(0xFF444750),
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilters() {
    return Row(
      children: [
        _filterButton(
          filter: _FolderVisibilityFilter.all,
          icon: Icons.folder_copy_outlined,
          label: "All",
        ),
        const SizedBox(width: 8),
        _filterButton(
          filter: _FolderVisibilityFilter.visible,
          icon: Icons.visibility_outlined,
          label: "Visible",
        ),
        const SizedBox(width: 8),
        _filterButton(
          filter: _FolderVisibilityFilter.hidden,
          icon: Icons.visibility_off_outlined,
          label: "Hidden",
        ),
      ],
    );
  }

  // Widget _buildUserHeader() {
  //   return Container(
  //     width: double.infinity,
  //     decoration: BoxDecoration(
  //       color: const Color(0xFFE1E2EA),
  //       borderRadius: BorderRadius.circular(14),
  //     ),
  //     padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
  //     child: Row(
  //       children: [
  //         const Icon(
  //           Icons.person_search_outlined,
  //           color: Color(0xFF444750),
  //           size: 25,
  //         ),
  //         const SizedBox(width: 14),
  //         Expanded(
  //           child: Text(
  //             widget.userEmail.trim().isEmpty
  //                 ? widget.userName
  //                 : "${widget.userName} • ${widget.userEmail}",
  //             maxLines: 1,
  //             overflow: TextOverflow.ellipsis,
  //             style: const TextStyle(
  //               color: Color(0xFF444750),
  //               fontSize: 16,
  //               fontWeight: FontWeight.w700,
  //             ),
  //           ),
  //         ),
  //       ],
  //     ),
  //   );
  // }

  void _toggleExpanded(String folderId) {
    setState(() {
      if (_expandedFolderIds.contains(folderId)) {
        _expandedFolderIds.remove(folderId);
      } else {
        _expandedFolderIds.add(folderId);
      }
    });
  }

  List<Widget> _buildFolderRows({
    required List<_FolderNode> nodes,
    required int depth,
    required Set<String> visibleFolderIds,
    required Map<String, _FolderNode> nodesById,
  }) {
    final rows = <Widget>[];

    for (final node in nodes) {
      final isVisible = visibleFolderIds.contains(node.id);
      final hasChildren = node.children.isNotEmpty;
      final isExpanded = _expandedFolderIds.contains(node.id);
      final isSaving = _savingFolderIds.contains(node.id);

      final shouldShow = _passesFilter(isVisible: isVisible);

      if (shouldShow) {
        rows.add(
          _FolderListRow(
            node: node,
            depth: depth,
            isVisible: isVisible,
            isSaving: isSaving,
            hasChildren: hasChildren,
            isExpanded: isExpanded,
            onToggleVisibility: () {
              _toggleFolderVisibility(
                node: node,
                currentlyVisible: isVisible,
                visibleFolderIds: visibleFolderIds,
                nodesById: nodesById,
              );
            },
            onToggleExpanded: hasChildren
                ? () {
              _toggleExpanded(node.id);
            }
                : null,
          ),
        );
      }

      if (hasChildren && isExpanded) {
        rows.addAll(
          _buildFolderRows(
            nodes: node.children,
            depth: depth + 1,
            visibleFolderIds: visibleFolderIds,
            nodesById: nodesById,
          ),
        );
      }
    }

    return rows;
  }

  Widget _buildMessageBody({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: Colors.grey.shade500),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.grey.shade700,
                  fontSize: 14,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody({
    required Map<String, dynamic>? userData,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> folderDocs,
  }) {
    if (folderDocs.isEmpty) {
      return _buildMessageBody(
        icon: Icons.folder_off_outlined,
        title: "No folders found",
        message: "There are no folders to manage yet.",
      );
    }

    final roots = _buildFolderTree(folderDocs);
    final nodesById = _flattenFolderNodes(roots);
    final allFolderIds = folderDocs.map((doc) => doc.id).toSet();

    final firestoreVisibleFolderIds = _readVisibleFolderIds(
      userData: userData,
      allFolderIds: allFolderIds,
    );

    final visibleFolderIds =
        _optimisticVisibleFolderIds ?? firestoreVisibleFolderIds;

    final rows = _buildFolderRows(
      nodes: roots,
      depth: 0,
      visibleFolderIds: visibleFolderIds,
      nodesById: nodesById,
    );

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.only(top: 12),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: _buildFilters(),
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 80),
              child: _buildMessageBody(
                icon: _filter == _FolderVisibilityFilter.visible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                title: "No folders in this filter",
                message: "Try selecting another filter.",
              ),
            )
          else
            DecoratedBox(
              decoration: const BoxDecoration(
                color: Colors.white,
              ),
              child: Column(
                children: rows,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _buildAppBar(),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _userRef.snapshots(),
        builder: (context, userSnapshot) {
          if (userSnapshot.hasError) {
            return _buildMessageBody(
              icon: Icons.error_outline,
              title: "Unable to load user",
              message: "Please try again.",
            );
          }

          if (!userSnapshot.hasData) {
            return const SafeArea(
              child: Center(
                child: CircularProgressIndicator(),
              ),
            );
          }

          final userData = userSnapshot.data!.data();

          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _foldersRef.snapshots(),
            builder: (context, folderSnapshot) {
              if (folderSnapshot.hasError) {
                return _buildMessageBody(
                  icon: Icons.error_outline,
                  title: "Unable to load folders",
                  message: "Please try again.",
                );
              }

              if (!folderSnapshot.hasData) {
                return const SafeArea(
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                );
              }

              return _buildBody(
                userData: userData,
                folderDocs: folderSnapshot.data!.docs,
              );
            },
          );
        },
      ),
    );
  }
}

class _FolderListRow extends StatelessWidget {
  final _FolderNode node;
  final int depth;
  final bool isVisible;
  final bool isSaving;
  final bool hasChildren;
  final bool isExpanded;
  final VoidCallback onToggleVisibility;
  final VoidCallback? onToggleExpanded;

  const _FolderListRow({
    required this.node,
    required this.depth,
    required this.isVisible,
    required this.isSaving,
    required this.hasChildren,
    required this.isExpanded,
    required this.onToggleVisibility,
    required this.onToggleExpanded,
  });

  @override
  Widget build(BuildContext context) {
    final subtitleParts = <String>[
      if (!isVisible && depth > 0 && node.parentBreadcrumb != null)
        node.parentBreadcrumb!,
      if (hasChildren)
        "${node.children.length} subfolder${node.children.length == 1 ? "" : "s"}",
    ];

    return Column(
      children: [
        InkWell(
          onTap: hasChildren ? onToggleExpanded : null,
          child: Padding(
            padding: EdgeInsets.only(
              left: 18.0 + (depth * 22.0),
              right: 18,
              top: 13,
              bottom: 13,
            ),
            child: Row(
              children: [
                Icon(
                  depth == 0
                      ? Icons.folder_outlined
                      : Icons.subdirectory_arrow_right,
                  color: const Color(0xFF444750),
                  size: 27,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        node.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF2F3137),
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (subtitleParts.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitleParts.join(" • "),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF4F535C),
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 74,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: Center(
                          child: isSaving
                              ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                              : InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: onToggleVisibility,
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                isVisible
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                color: isVisible
                                    ? Colors.green
                                    : Colors.grey,
                                size: 23,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 34,
                        height: 34,
                        child: hasChildren
                            ? InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: onToggleExpanded,
                          child: Icon(
                            isExpanded
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            color: const Color(0xFF444750),
                            size: 28,
                          ),
                        )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(
          height: 1,
          thickness: 0.8,
          color: Color(0xFFD7D7D7),
        ),
      ],
    );
  }
}

class _FolderNode {
  final String id;
  final String name;
  final String? parentId;
  String? parentName;
  String? parentBreadcrumb;
  final List<_FolderNode> children;

  _FolderNode({
    required this.id,
    required this.name,
    required this.parentId,
  }) : children = <_FolderNode>[];
}