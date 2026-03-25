//manage users by adding, editing or deleting
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/tenant_context_service.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/top_toast.dart';
import 'add_user_screen.dart';
import 'edit_user_screen.dart';

class ManageUsersScreen extends StatefulWidget {
  const ManageUsersScreen({super.key});

  @override
  State<ManageUsersScreen> createState() => _ManageUsersScreenState();
}

class _ManageUsersScreenState extends State<ManageUsersScreen> {
  static const Duration _searchDebounce = Duration(milliseconds: 350);

  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _debouncedSearchQuery = ValueNotifier<String>("");

  late final Future<String> _tenantIdFuture;

  StreamSubscription<User?>? _authSub;
  Timer? _searchTimer;

  bool _handledSignedOut = false;

  String get _myUid => FirebaseAuth.instance.currentUser?.uid ?? "";

  @override
  void initState() {
    super.initState();
    _tenantIdFuture = TenantContextService().getTenantIdOrThrow();
    _listenToAuthChanges();
    _searchController.addListener(_onSearchChanged);
  }

  void _listenToAuthChanges() {
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted || _handledSignedOut) return;

      if (user == null) {
        _handledSignedOut = true;
        _unfocusSafely();

        final navigator = Navigator.maybeOf(context);

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (navigator != null && navigator.canPop()) {
            navigator.pop();
          }
        });
      }
    });
  }

  void _onSearchChanged() {
    _searchTimer?.cancel();

    final nextValue = _searchController.text.trim().toLowerCase();

    _searchTimer = Timer(_searchDebounce, () {
      if (!mounted || _handledSignedOut) return;
      if (_debouncedSearchQuery.value != nextValue) {
        _debouncedSearchQuery.value = nextValue;
      }
    });
  }

  void _unfocusSafely() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  bool _canUseContext() => mounted && !_handledSignedOut;

  //used before navigation so focus changes and UI updates finish first
  Future<void> _nextFrame() {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  Future<void> _safePop() async {
    if (!_canUseContext()) return;

    final navigator = Navigator.maybeOf(context);
    if (navigator == null) return;

    _unfocusSafely();
    await _nextFrame();

    if (!mounted || _handledSignedOut) return;

    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  //opens another screen
  Future<T?> _safePush<T>(Route<T> route) async {
    if (!_canUseContext()) return null;

    final navigator = Navigator.maybeOf(context);
    if (navigator == null) return null;

    _unfocusSafely();
    await _nextFrame();

    if (!mounted || _handledSignedOut) return null;

    return navigator.push<T>(route);
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _authSub?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _debouncedSearchQuery.dispose();
    super.dispose();
  }

  CollectionReference<Map<String, dynamic>> _tenantUsersCol(String tenantId) {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(tenantId)
        .collection("users");
  }

  String _cleanErr(Object e) =>
      e.toString().replaceFirst("Exception: ", "").trim();

  //convert roles into readable text
  String _formatRole(String role) {
    final cleaned = role.trim().toLowerCase();
    if (cleaned.isEmpty) return "Staff";

    return cleaned
        .split('_')
        .map((word) {
      if (word.isEmpty) return word;
      return word[0].toUpperCase() + word.substring(1);
    })
        .join(' ');
  }

  //delete user through cloud function
  Future<void> deleteUser({
    required String tenantId,
    required String uid,
  }) async {
    if (uid == _myUid) {
      throw FirebaseFunctionsException(
        code: 'failed-precondition',
        message: 'You cannot delete yourself.',
      );
    }

    final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
    final callable = functions.httpsCallable('deleteAuthUser');

    await callable.call({
      "tenantId": tenantId,
      "uid": uid,
    });
  }

  String _friendlyError(Object e) {
    if (e is FirebaseFunctionsException) {
      switch (e.code) {
        case 'permission-denied':
          return 'Only admins can delete users.';
        case 'unauthenticated':
          return 'You must be logged in.';
        case 'failed-precondition':
          return e.message ?? 'Action not allowed.';
        case 'not-found':
          return 'User not found.';
        case 'unavailable':
          return 'Service is unavailable. Check your internet and try again.';
        case 'invalid-argument':
          return 'Invalid request. Please try again.';
        default:
          return e.message ?? 'Failed to delete user.';
      }
    }

    final cleaned = _cleanErr(e);
    return cleaned.isEmpty
        ? 'Failed to delete user. Please try again.'
        : cleaned;
  }

  void _showSuccess(String message) {
    if (!_canUseContext()) return;
    TopToast.success(context, message);
  }

  void _showError(String message) {
    if (!_canUseContext()) return;
    TopToast.error(context, message);
  }

  Future<bool> _confirmDelete() async {
    if (!_canUseContext()) return false;

    _unfocusSafely();

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Delete user?"),
        content: const Text(
          "This will permanently remove the user from Authentication and the database.",
        ),
        actions: [
          TextButton(
            onPressed: () {
              _unfocusSafely();
              Navigator.of(dialogContext).pop(false);
            },
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            onPressed: () {
              _unfocusSafely();
              Navigator.of(dialogContext).pop(true);
            },
            child: const Text("Delete"),
          ),
        ],
      ),
    );

    return ok == true;
  }

  //search matching logic
  bool _matchesSearch(Map<String, dynamic> data, String query) {
    final name = (data["name"] ?? "").toString().toLowerCase();
    final email = (data["email"] ?? "").toString().toLowerCase();
    final role = (data["role"] ?? "").toString().toLowerCase();

    if (query.isEmpty) return true;
    return name.contains(query) || email.contains(query) || role.contains(query);
  }

  //sorting and filtering users
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _applySearchAndSort(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
      String query,
      ) {
    final filtered = docs.where((d) {
      return _matchesSearch(d.data(), query);
    }).toList();

    filtered.sort((a, b) {
      final aIsMe = a.id == _myUid;
      final bIsMe = b.id == _myUid;

      if (aIsMe && !bIsMe) return -1;
      if (!aIsMe && bIsMe) return 1;

      final aName = (a.data()["name"] ?? "").toString().toLowerCase();
      final bName = (b.data()["name"] ?? "").toString().toLowerCase();

      return aName.compareTo(bName);
    });

    return filtered;
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: ValueListenableBuilder<String>(
        valueListenable: _debouncedSearchQuery,
        builder: (context, _, __) {
          return TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: "Search users...",
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                onPressed: () {
                  _searchTimer?.cancel();
                  _searchController.clear();
                  _debouncedSearchQuery.value = "";
                  _unfocusSafely();
                },
                icon: const Icon(Icons.close),
              ),
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(String tenantId) {
    return AppBar(
      backgroundColor: const Color(0xff0B1E40),
      title: const Text(
        "Manage Users",
        style: TextStyle(color: Colors.white),
      ),
      iconTheme: const IconThemeData(color: Colors.white),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: _safePop,
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.add, color: Colors.white),
          tooltip: "Add user",
          onPressed: () async {
            final created = await _safePush<bool>(
              MaterialPageRoute(
                builder: (context) => AddUserScreen(
                  tenantId: tenantId,
                ),
              ),
            );

            if (!_canUseContext()) return;

            if (created == true) {
              _showSuccess("User created.");
            }
          },
        ),
      ],
    );
  }

  Widget _buildTenantLoading(bool keyboardOpen) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xff0B1E40),
        title: const Text(
          "Manage Users",
          style: TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: const Center(child: CircularProgressIndicator()),
      bottomNavigationBar: keyboardOpen
          ? null
          : const BottomNav(
        currentIndex: 4,
        hasFab: false,
        isRootScreen: false,
      ),
    );
  }

  Widget _buildTenantError(Object? error, bool keyboardOpen) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xff0B1E40),
        title: const Text(
          "Manage Users",
          style: TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: _safePop,
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            error != null ? _cleanErr(error) : "Failed to load tenant.",
            textAlign: TextAlign.center,
          ),
        ),
      ),
      bottomNavigationBar: keyboardOpen
          ? null
          : const BottomNav(
        currentIndex: 4,
        hasFab: false,
        isRootScreen: false,
      ),
    );
  }

  //main list area
  Widget _buildUsersList(
      String tenantId,
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
      ) {
    return ValueListenableBuilder<String>(
      valueListenable: _debouncedSearchQuery,
      builder: (context, query, _) {
        final filtered = _applySearchAndSort(docs, query);

        if (filtered.isEmpty) {
          return const Center(
            child: Text("No matching users found"),
          );
        }

        return ListView.builder(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.only(bottom: 16),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final user = filtered[index];
            final uid = user.id;
            final data = user.data();

            final name = (data["name"] ?? "No Name").toString();
            final email = (data["email"] ?? "").toString();
            final role = (data["role"] ?? "staff").toString();
            final isMe = uid == _myUid;

            return ListTile(
              title: Text(name),
              subtitle: Text(
                "$email — ${_formatRole(role)}${isMe ? " (you)" : ""}",
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.edit,
                      color: Color(0xFF0B1C3C),
                    ),
                    tooltip: "Edit user",
                    onPressed: () async {
                      final updated = await _safePush<bool>(
                        MaterialPageRoute(
                          builder: (context) => EditUserScreen(
                            tenantId: tenantId,
                            uid: uid,
                            name: name,
                            email: email,
                            role: role,
                          ),
                        ),
                      );

                      if (!_canUseContext()) return;

                      if (updated == true) {
                        _showSuccess("User updated.");
                      }
                    },
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.delete,
                      color: isMe ? Colors.grey : Colors.red,
                    ),
                    tooltip: isMe ? "You cannot delete yourself" : "Delete user",
                    onPressed: isMe
                        ? null
                        : () async {
                      final ok = await _confirmDelete();
                      if (!ok || !_canUseContext()) return;

                      try {
                        await deleteUser(
                          tenantId: tenantId,
                          uid: uid,
                        );

                        if (!_canUseContext()) return;
                        _showSuccess("User deleted.");
                      } catch (e) {
                        if (!_canUseContext()) return;
                        _showError(_friendlyError(e));
                      }
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

    return FutureBuilder<String>(
      future: _tenantIdFuture,
      builder: (context, tenantSnap) {
        if (tenantSnap.connectionState == ConnectionState.waiting) {
          return _buildTenantLoading(keyboardOpen);
        }

        if (tenantSnap.hasError || !tenantSnap.hasData) {
          return _buildTenantError(tenantSnap.error, keyboardOpen);
        }

        final tenantId = tenantSnap.data!;

        return Scaffold(
          appBar: _buildAppBar(tenantId),
          resizeToAvoidBottomInset: true,
          body: SafeArea(
            child: Column(
              children: [
                _buildSearchBar(),
                Expanded(
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _tenantUsersCol(tenantId).snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return const Center(
                          child: Text("Error loading users"),
                        );
                      }

                      if (!snapshot.hasData) {
                        return const Center(
                          child: CircularProgressIndicator(),
                        );
                      }

                      final docs = snapshot.data!.docs;

                      return _buildUsersList(tenantId, docs);
                    },
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: keyboardOpen
              ? null
              : const BottomNav(
            currentIndex: 4,
            hasFab: false,
            isRootScreen: false,
          ),
        );
      },
    );
  }
}