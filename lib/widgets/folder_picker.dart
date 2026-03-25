import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class FolderPicker extends StatefulWidget {
  final String tenantId;
  final String? preselectedFolder;
  final ValueChanged<String?> onFolderSelected;

  //don't show folder itself and descendants
  final String? excludeFolderId;

  //don't show current parent of this folder
  final String? excludeParentOfFolderId;

  //current folder
  final String? currentFolderId;

  final bool allowTopLevel;
  final String placeholder;

  const FolderPicker({
    super.key,
    required this.tenantId,
    this.preselectedFolder,
    required this.onFolderSelected,
    this.excludeFolderId,
    this.excludeParentOfFolderId,
    this.currentFolderId,
    this.allowTopLevel = true,
    this.placeholder = "Select folder",
  });

  @override
  State<FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<FolderPicker> {
  static const String _topSentinel = "__TOP__";

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  List<String?> selectedPath = [null];
  List<List<QueryDocumentSnapshot<Map<String, dynamic>>>> levels = [];

  Set<String> _blockedIds = <String>{};
  bool _ready = false;

  CollectionReference<Map<String, dynamic>> get _foldersRef {
    return _firestore
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("folders");
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  bool _isOutOfStockFolderData(Map<String, dynamic> data) {
    return data["isSystemFolder"] == true ||
        (data["systemType"] ?? "").toString().trim() == "out_of_stock";
  }

  Future<void> _init() async {
    try {
      final blocked = <String>{};

      if (widget.excludeFolderId != null && widget.excludeFolderId!.isNotEmpty) {
        blocked.addAll(
          await _collectDescendantsIncludingSelf(widget.excludeFolderId!),
        );
      }

      if (widget.excludeParentOfFolderId != null &&
          widget.excludeParentOfFolderId!.isNotEmpty) {
        final snap = await _foldersRef.doc(widget.excludeParentOfFolderId!).get();
        final data = snap.data() ?? <String, dynamic>{};
        final parent = (data["parentId"] ?? "").toString().trim();
        if (parent.isNotEmpty) {
          blocked.add(parent);
        }
      }

      _blockedIds = blocked;
      selectedPath = [null];
      levels = [];

      await _loadLevel(parentId: null, level: 0);

      if (widget.preselectedFolder != null &&
          widget.preselectedFolder!.trim().isNotEmpty) {
        await _preselectFolder(widget.preselectedFolder!.trim());
      } else {
        widget.onFolderSelected(null);
      }

      if (!mounted) return;
      setState(() {
        _ready = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _ready = true;
      });
    }
  }

  Future<Set<String>> _collectDescendantsIncludingSelf(String rootId) async {
    final blocked = <String>{rootId};
    final queue = <String>[rootId];

    while (queue.isNotEmpty) {
      final parent = queue.removeAt(0);

      final snap = await _foldersRef.where("parentId", isEqualTo: parent).get();

      for (final d in snap.docs) {
        if (blocked.add(d.id)) {
          queue.add(d.id);
        }
      }
    }

    return blocked;
  }

  Future<bool> _hasSelectableChildren(String folderId) async {
    final snap = await _foldersRef.where("parentId", isEqualTo: folderId).get();

    for (final doc in snap.docs) {
      if (_blockedIds.contains(doc.id)) continue;

      final data = doc.data();
      if (_isOutOfStockFolderData(data)) continue;

      return true;
    }

    return false;
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _fetchLevelDocs({
    required String? parentId,
    required int level,
  }) async {
    Query<Map<String, dynamic>> query = _foldersRef;

    if (level == 0) {
      query = query.where("parentId", isNull: true);
    } else {
      query = query.where("parentId", isEqualTo: parentId);
    }

    final snapshot = await query.orderBy("name").get();

    final filtered = <QueryDocumentSnapshot<Map<String, dynamic>>>[];

    final String? selectedAtThisLevel =
    selectedPath.length > level + 1 ? selectedPath[level + 1] : null;

    for (final d in snapshot.docs) {
      if (_blockedIds.contains(d.id)) continue;

      final data = d.data();

      //never show out-of-stock (system) folders as options
      if (_isOutOfStockFolderData(data)) continue;

      if (widget.currentFolderId != null &&
          d.id == widget.currentFolderId &&
          selectedAtThisLevel != d.id) {
        final hasSelectableChildren = await _hasSelectableChildren(d.id);
        if (!hasSelectableChildren) {
          continue;
        }
      }

      filtered.add(d);
    }

    return filtered;
  }

  Future<void> _loadLevel({
    required String? parentId,
    required int level,
  }) async {
    final filteredDocs = await _fetchLevelDocs(parentId: parentId, level: level);

    if (!mounted) return;

    setState(() {
      if (filteredDocs.isEmpty) {
        if (levels.length > level) {
          levels = levels.sublist(0, level);
        }

        if (selectedPath.length > level + 1) {
          selectedPath = selectedPath.sublist(0, level + 1);
        }

        return;
      }

      if (levels.length > level) {
        levels[level] = filteredDocs;
        levels = levels.sublist(0, level + 1);
      } else {
        levels.add(filteredDocs);
      }

      while (selectedPath.length < level + 2) {
        selectedPath.add(null);
      }
    });
  }

  Future<void> _preselectFolder(String folderId) async {
    if (_blockedIds.contains(folderId)) {
      selectedPath = [null];
      levels = [];
      await _loadLevel(parentId: null, level: 0);
      widget.onFolderSelected(null);
      return;
    }

    String? currentId = folderId;
    final chain = <String>[];

    while (currentId != null && currentId.isNotEmpty) {
      chain.add(currentId);

      final doc = await _foldersRef.doc(currentId).get();
      final data = doc.data() ?? <String, dynamic>{};
      final parent = (data["parentId"] ?? "").toString().trim();

      if (parent.isEmpty) break;
      currentId = parent;
    }

    final ordered = chain.reversed.toList();

    selectedPath = [null];
    levels = [];

    await _loadLevel(parentId: null, level: 0);

    for (int i = 0; i < ordered.length; i++) {
      final folderIdAtLevel = ordered[i];

      if (levels.length <= i) break;

      final existsInLevel = levels[i].any((doc) => doc.id == folderIdAtLevel);
      if (!existsInLevel) break;

      if (!mounted) return;

      setState(() {
        while (selectedPath.length < i + 2) {
          selectedPath.add(null);
        }
        selectedPath[i + 1] = folderIdAtLevel;
      });

      await _loadLevel(parentId: folderIdAtLevel, level: i + 1);
    }

    widget.onFolderSelected(folderId);
  }

  String? _toFolderId(String? raw) {
    if (raw == _topSentinel) return null;
    return raw;
  }

  bool _isSelectableFolderValue(String? value) {
    return value != null && value != _topSentinel;
  }

  InputDecoration _decoration() {
    return InputDecoration(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      filled: true,
      fillColor: Colors.grey.shade200,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 12,
      ),
    );
  }

  Widget _buildDisabledPlaceholder() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: double.infinity),
        child: DropdownButtonFormField<String?>(
          value: null,
          decoration: _decoration(),
          hint: Text(widget.placeholder),
          items: const [],
          onChanged: null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [_buildDisabledPlaceholder()],
      );
    }

    if (levels.isEmpty) {
      if (!widget.allowTopLevel) {
        return const SizedBox.shrink();
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: double.infinity),
              child: DropdownButtonFormField<String?>(
                value: _topSentinel,
                decoration: _decoration(),
                isExpanded: true,
                hint: Text(widget.placeholder),
                items: const [
                  DropdownMenuItem<String?>(
                    value: _topSentinel,
                    child: Text("Files"),
                  ),
                ],
                onChanged: (value) {
                  widget.onFolderSelected(_toFolderId(value));
                },
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(levels.length, (levelIndex) {
        final foldersAtLevel = levels[levelIndex];
        final selectedValue =
        selectedPath.length > levelIndex + 1 ? selectedPath[levelIndex + 1] : null;

        final itemValues = <String?>{
          if (levelIndex == 0 && widget.allowTopLevel) _topSentinel,
          ...foldersAtLevel.map((f) => f.id),
        };

        final safeSelectedValue =
        itemValues.contains(selectedValue) ? selectedValue : null;

        final items = <DropdownMenuItem<String?>>[
          if (levelIndex == 0 && widget.allowTopLevel)
            const DropdownMenuItem<String?>(
              value: _topSentinel,
              child: Text("Files"),
            ),
          ...foldersAtLevel.map(
                (f) => DropdownMenuItem<String?>(
              value: f.id,
              child: Text(
                (f.data()["name"] ?? "").toString(),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ];

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: double.infinity),
            child: DropdownButtonFormField<String?>(
              key: ValueKey("folder_level_$levelIndex"),
              value: safeSelectedValue,
              decoration: _decoration(),
              isExpanded: true,
              hint: Text(
                levelIndex == 0 ? widget.placeholder : "Select subfolder",
              ),
              items: items,
              onChanged: (value) async {
                if (!mounted) return;

                setState(() {
                  while (selectedPath.length < levelIndex + 2) {
                    selectedPath.add(null);
                  }

                  selectedPath[levelIndex + 1] = value;
                  selectedPath = selectedPath.sublist(0, levelIndex + 2);

                  if (levels.length > levelIndex + 1) {
                    levels = levels.sublist(0, levelIndex + 1);
                  }
                });

                widget.onFolderSelected(_toFolderId(value));

                if (_isSelectableFolderValue(value)) {
                  await _loadLevel(parentId: value, level: levelIndex + 1);
                }
              },
            ),
          ),
        );
      }),
    );
  }
}