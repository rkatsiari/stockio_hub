import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/tenant_context_service.dart';
import 'manage_user_folders_screen.dart';

enum _UserRoleFilter {
  all,
  manager,
  accountant,
  staff,
  reseller,
}

class ManageUsersFoldersScreen extends StatefulWidget {
  const ManageUsersFoldersScreen({super.key});

  @override
  State<ManageUsersFoldersScreen> createState() =>
      _ManageUsersFoldersScreenState();
}

class _ManageUsersFoldersScreenState extends State<ManageUsersFoldersScreen> {
  late final StreamSubscription<User?> _authSub;

  final TenantContextService _tenantContextService = TenantContextService();
  final TextEditingController _searchController = TextEditingController();

  User? _currentUser;
  Future<_ManageUsersFoldersBootstrapState>? _bootstrapFuture;

  _UserRoleFilter _roleFilter = _UserRoleFilter.all;
  String _searchText = "";

  @override
  void initState() {
    super.initState();

    _currentUser = FirebaseAuth.instance.currentUser;
    _bootstrapFuture = _buildBootstrapForUser(_currentUser);

    _searchController.addListener(() {
      final nextText = _searchController.text.trim().toLowerCase();
      if (nextText == _searchText) return;

      setState(() {
        _searchText = nextText;
      });
    });

    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted) return;

      final previousUid = _currentUser?.uid;
      final nextUid = user?.uid;

      if (previousUid == nextUid) return;

      setState(() {
        _currentUser = user;
        _bootstrapFuture = _buildBootstrapForUser(user);
      });
    });
  }

  @override
  void dispose() {
    _authSub.cancel();
    _searchController.dispose();
    super.dispose();
  }

  bool _isAuthOrPermissionError(Object error) {
    final msg = error.toString().toLowerCase();

    return msg.contains(TenantContextService.kSignedOutMessage.toLowerCase()) ||
        msg.contains("permission-denied") ||
        msg.contains("permission denied") ||
        msg.contains("unauthenticated") ||
        msg.contains("user is not signed in") ||
        msg.contains("requires authentication") ||
        msg.contains("user_signed_out") ||
        msg.contains("user signed out");
  }

  Future<_ManageUsersFoldersBootstrapState> _buildBootstrapForUser(
      User? user,
      ) async {
    if (user == null) {
      return const _ManageUsersFoldersBootstrapState.signedOut();
    }

    try {
      Map<String, dynamic>? profile =
      await _tenantContextService.tryGetCurrentUserProfileCacheOnly();

      profile ??= await _tenantContextService.tryGetCurrentUserProfile();

      if (profile == null) {
        return const _ManageUsersFoldersBootstrapState.error(
          message: "Unable to load profile.",
        );
      }

      final tenantId = (profile["tenantId"] ?? "").toString().trim();
      final role = (profile["role"] ?? "staff").toString().trim();

      if (tenantId.isEmpty) {
        return const _ManageUsersFoldersBootstrapState.missingTenant();
      }

      if (role != "admin") {
        return const _ManageUsersFoldersBootstrapState.notAllowed();
      }

      return _ManageUsersFoldersBootstrapState.ready(
        tenantId: tenantId,
        role: role,
      );
    } catch (e) {
      if (_isAuthOrPermissionError(e)) {
        return const _ManageUsersFoldersBootstrapState.signedOut();
      }

      final message = e.toString().replaceFirst("Exception: ", "").trim();

      return _ManageUsersFoldersBootstrapState.error(
        message: message.isEmpty ? "Unable to load profile." : message,
      );
    }
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xff0B1E40),
      iconTheme: const IconThemeData(color: Colors.white),
      title: const Text(
        "Manage User Folders",
        style: TextStyle(color: Colors.white),
      ),
    );
  }

  Widget _buildLoadingScaffold() {
    return Scaffold(
      appBar: _buildAppBar(),
      body: const SafeArea(
        child: Center(
          child: CircularProgressIndicator(),
        ),
      ),
    );
  }

  Widget _buildMessage({
    required IconData icon,
    required String title,
    required String message,
    Widget? action,
  }) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: SafeArea(
        child: Center(
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
                  if (action != null) ...[
                    const SizedBox(height: 20),
                    action,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _roleFilterLabel(_UserRoleFilter filter) {
    switch (filter) {
      case _UserRoleFilter.all:
        return "All";
      case _UserRoleFilter.manager:
        return "Manager";
      case _UserRoleFilter.accountant:
        return "Accountant";
      case _UserRoleFilter.staff:
        return "Staff";
      case _UserRoleFilter.reseller:
        return "Reseller";
    }
  }

  String? _roleValueForFilter(_UserRoleFilter filter) {
    switch (filter) {
      case _UserRoleFilter.all:
        return null;
      case _UserRoleFilter.manager:
        return "manager";
      case _UserRoleFilter.accountant:
        return "accountant";
      case _UserRoleFilter.staff:
        return "staff";
      case _UserRoleFilter.reseller:
        return "reseller";
    }
  }

  Widget _buildSearchBox() {
    return Container(
      height: 58,
      decoration: BoxDecoration(
        color: const Color(0xFFE1E2EA),
        borderRadius: BorderRadius.circular(13),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          const Icon(
            Icons.search,
            color: Color(0xFF4A4D55),
            size: 26,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: "Search users by name or email...",
                hintStyle: TextStyle(
                  color: Color(0xFF4A4D55),
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: const TextStyle(
                color: Color(0xFF2F3137),
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_searchText.isNotEmpty)
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () {
                _searchController.clear();
              },
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(
                  Icons.close,
                  color: Color(0xFF4A4D55),
                  size: 22,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRoleFilterButton(_UserRoleFilter filter) {
    final selected = _roleFilter == filter;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () {
          setState(() {
            _roleFilter = filter;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFE7ECFF) : Colors.white,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected
                  ? const Color(0xFFE7ECFF)
                  : const Color(0xFF8E929C),
              width: 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                const Icon(
                  Icons.check,
                  size: 18,
                  color: Color(0xff0B1E40),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                _roleFilterLabel(filter),
                style: const TextStyle(
                  color: Color(0xFF3F424A),
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Widget _buildRoleFilters() {
  //   return SingleChildScrollView(
  //     scrollDirection: Axis.horizontal,
  //     child: Row(
  //       children: const [
  //         SizedBox(width: 0),
  //       ],
  //     ),
  //   );
  // }

  Widget _buildRoleFiltersRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          _buildRoleFilterButton(_UserRoleFilter.all),
          _buildRoleFilterButton(_UserRoleFilter.staff),
          _buildRoleFilterButton(_UserRoleFilter.reseller),
          _buildRoleFilterButton(_UserRoleFilter.manager),
          _buildRoleFilterButton(_UserRoleFilter.accountant),
        ],
      ),
    );
  }

  IconData _roleIcon(String role) {
    return Icons.person_outline;
  }

  String _roleLabel(String role) {
    final safeRole = role.trim().toLowerCase();

    switch (safeRole) {
      case "manager":
        return "Manager";
      case "accountant":
        return "Accountant";
      case "staff":
        return "Staff";
      case "reseller":
        return "Reseller";
      default:
        return safeRole.isEmpty ? "Staff" : safeRole;
    }
  }

  bool _matchesRoleFilter(String role) {
    final selectedRole = _roleValueForFilter(_roleFilter);
    if (selectedRole == null) return true;

    return role.trim().toLowerCase() == selectedRole;
  }

  bool _matchesSearch({
    required String name,
    required String email,
    required String role,
  }) {
    if (_searchText.isEmpty) return true;

    final combined = "$name $email $role".toLowerCase();
    return combined.contains(_searchText);
  }

  Widget _buildUserRow({
    required String tenantId,
    required QueryDocumentSnapshot<Map<String, dynamic>> doc,
  }) {
    final data = doc.data();

    final name = (data["name"] ?? "Unknown").toString().trim();
    final email = (data["email"] ?? "").toString().trim();
    final role = (data["role"] ?? "staff").toString().trim();

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ManageUserFoldersScreen(
              tenantId: tenantId,
              userId: doc.id,
              userName: name.isEmpty ? "Unknown" : name,
              userEmail: email,
            ),
          ),
        );
      },
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
            child: Row(
              children: [
                Icon(
                  _roleIcon(role),
                  color: const Color(0xFF444750),
                  size: 27,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? "Unknown" : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF2F3137),
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        email.isEmpty
                            ? _roleLabel(role)
                            : "$email • ${_roleLabel(role)}",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF4F535C),
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.chevron_right,
                  color: Color(0xFF444750),
                  size: 30,
                ),
              ],
            ),
          ),
          const Divider(
            height: 1,
            thickness: 0.8,
            color: Color(0xFFD7D7D7),
          ),
        ],
      ),
    );
  }

  Widget _buildUsersList(String tenantId) {
    final usersRef = FirebaseFirestore.instance
        .collection("tenants")
        .doc(tenantId)
        .collection("users");

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: usersRef.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _buildMessage(
            icon: Icons.error_outline,
            title: "Unable to load users",
            message: "Please try again.",
          );
        }

        if (!snapshot.hasData) {
          return _buildLoadingScaffold();
        }

        final docs = snapshot.data!.docs.where((doc) {
          final data = doc.data();
          final role = (data["role"] ?? "staff").toString().trim();

          if (role == "admin" || role == "storage_manager") {
            return false;
          }

          final name = (data["name"] ?? "").toString().trim();
          final email = (data["email"] ?? "").toString().trim();

          return _matchesRoleFilter(role) &&
              _matchesSearch(
                name: name,
                email: email,
                role: role,
              );
        }).toList();

        docs.sort((a, b) {
          final aName = (a.data()["name"] ?? "").toString().toLowerCase();
          final bName = (b.data()["name"] ?? "").toString().toLowerCase();

          return aName.compareTo(bName);
        });

        return Scaffold(
          backgroundColor: Colors.white,
          appBar: _buildAppBar(),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.only(top: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: _buildSearchBox(),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: _buildRoleFiltersRow(),
                ),
                const SizedBox(height: 12),
                if (docs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 80),
                    child: _buildEmptyUsersMessage(),
                  )
                else
                  DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                    ),
                    child: Column(
                      children: [
                        for (final doc in docs)
                          _buildUserRow(
                            tenantId: tenantId,
                            doc: doc,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyUsersMessage() {
    final hasSearch = _searchText.isNotEmpty;
    final roleLabel = _roleFilterLabel(_roleFilter);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasSearch ? Icons.search_off : Icons.people_outline,
                size: 56,
                color: Colors.grey.shade500,
              ),
              const SizedBox(height: 16),
              Text(
                hasSearch || _roleFilter != _UserRoleFilter.all
                    ? "No users found"
                    : "No users available",
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                hasSearch || _roleFilter != _UserRoleFilter.all
                    ? "No users match your search or the $roleLabel filter."
                    : "There are no users available. Admins and storage managers are excluded.",
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

  @override
  Widget build(BuildContext context) {
    final future = _bootstrapFuture ?? _buildBootstrapForUser(_currentUser);

    return FutureBuilder<_ManageUsersFoldersBootstrapState>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildLoadingScaffold();
        }

        final state = snapshot.data ??
            const _ManageUsersFoldersBootstrapState.error(
              message: "Unable to load profile.",
            );

        if (state.isSignedOut) {
          return _buildMessage(
            icon: Icons.lock_outline,
            title: "Not signed in",
            message: "Please sign in again.",
          );
        }

        if (state.isMissingTenant) {
          return _buildMessage(
            icon: Icons.apartment_outlined,
            title: "Tenant not found",
            message: "Your account is not assigned to a tenant.",
          );
        }

        if (state.isNotAllowed) {
          return _buildMessage(
            icon: Icons.admin_panel_settings_outlined,
            title: "Admin only",
            message: "Only admins can manage user folder visibility.",
          );
        }

        if (!state.isReady) {
          return _buildMessage(
            icon: Icons.error_outline,
            title: "Unable to load",
            message: state.message ?? "Something went wrong.",
            action: ElevatedButton(
              onPressed: () {
                setState(() {
                  _bootstrapFuture = _buildBootstrapForUser(_currentUser);
                });
              },
              child: const Text("Retry"),
            ),
          );
        }

        return _buildUsersList(state.tenantId!);
      },
    );
  }
}

class _ManageUsersFoldersBootstrapState {
  final String? tenantId;
  final String? role;
  final bool isSignedOut;
  final bool isMissingTenant;
  final bool isNotAllowed;
  final String? message;

  const _ManageUsersFoldersBootstrapState._({
    required this.tenantId,
    required this.role,
    required this.isSignedOut,
    required this.isMissingTenant,
    required this.isNotAllowed,
    required this.message,
  });

  const _ManageUsersFoldersBootstrapState.ready({
    required String tenantId,
    required String role,
  }) : this._(
    tenantId: tenantId,
    role: role,
    isSignedOut: false,
    isMissingTenant: false,
    isNotAllowed: false,
    message: null,
  );

  const _ManageUsersFoldersBootstrapState.signedOut()
      : this._(
    tenantId: null,
    role: null,
    isSignedOut: true,
    isMissingTenant: false,
    isNotAllowed: false,
    message: null,
  );

  const _ManageUsersFoldersBootstrapState.missingTenant()
      : this._(
    tenantId: null,
    role: null,
    isSignedOut: false,
    isMissingTenant: true,
    isNotAllowed: false,
    message: null,
  );

  const _ManageUsersFoldersBootstrapState.notAllowed()
      : this._(
    tenantId: null,
    role: null,
    isSignedOut: false,
    isMissingTenant: false,
    isNotAllowed: true,
    message: null,
  );

  const _ManageUsersFoldersBootstrapState.error({
    required String message,
  }) : this._(
    tenantId: null,
    role: null,
    isSignedOut: false,
    isMissingTenant: false,
    isNotAllowed: false,
    message: message,
  );

  bool get isReady =>
      tenantId != null &&
          tenantId!.trim().isNotEmpty &&
          role != null &&
          role == "admin";
}