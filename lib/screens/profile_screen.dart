//profile screen
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/tenant_context_service.dart';
import '../widgets/bottom_nav.dart';
import 'admin_users_screen.dart';
import 'login_screen.dart';
import 'manage_users_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  //state variables
  late final StreamSubscription<User?> _authSub;

  final TenantContextService _tenantContextService = TenantContextService();

  User? _currentUser;
  Future<_ProfileBootstrapState>? _bootstrapFuture;
  bool _isLoggingOut = false;

  @override
  void initState() {
    super.initState();
    _currentUser = FirebaseAuth.instance.currentUser;
    _bootstrapFuture = _buildBootstrapForUser(_currentUser);

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

  Future<_ProfileBootstrapState> _buildBootstrapForUser(User? user) async {
    if (user == null) {
      return const _ProfileBootstrapState.signedOut();
    }

    try {
      Map<String, dynamic>? rootProfile =
      await _tenantContextService.tryGetCurrentUserProfileCacheOnly();

      rootProfile ??= await _tenantContextService.tryGetCurrentUserProfile();

      if (rootProfile == null) {
        return const _ProfileBootstrapState.error(
          message: "Unable to load profile.",
        );
      }

      final tenantId = (rootProfile["tenantId"] ?? "").toString().trim();
      if (tenantId.isEmpty) {
        return const _ProfileBootstrapState.missingTenant();
      }

      final tenantUserRef = FirebaseFirestore.instance
          .collection("tenants")
          .doc(tenantId)
          .collection("users")
          .doc(user.uid);

      Map<String, dynamic>? tenantUserData;
      try {
        final cached =
        await tenantUserRef.get(const GetOptions(source: Source.cache));
        if (cached.exists) {
          tenantUserData = cached.data();
        }
      } catch (_) {}

      tenantUserData ??= await () async {
        try {
          final live = await tenantUserRef.get();
          return live.data();
        } catch (_) {
          return null;
        }
      }();

      final merged = <String, dynamic>{
        ...rootProfile,
        ...?tenantUserData,
      };

      final name = (merged["name"] ?? "Unknown").toString().trim();
      final email = (merged["email"] ?? "").toString().trim();
      final role = (merged["role"] ?? "staff").toString().trim();

      return _ProfileBootstrapState.ready(
        tenantId: tenantId,
        name: name.isEmpty ? "Unknown" : name,
        email: email,
        role: role.isEmpty ? "staff" : role,
      );
    } catch (e) {
      if (_isAuthOrPermissionError(e)) {
        return const _ProfileBootstrapState.signedOut();
      }

      final message = e.toString().replaceFirst("Exception: ", "").trim();
      return _ProfileBootstrapState.error(
        message: message.isEmpty ? "Unable to load profile." : message,
      );
    }
  }

  Future<void> logout() async {
    if (_isLoggingOut) return;

    FocusManager.instance.primaryFocus?.unfocus();

    if (mounted) {
      setState(() => _isLoggingOut = true);
    }

    //sign out and navigate
    try {
      await FirebaseAuth.instance.signOut();

      if (!mounted) return;

      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
            (route) => false,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoggingOut = false);
    }
  }

  Widget _actionTile({
    required String title,
    required VoidCallback onTap,
    required double radius,
    required double fontSize,
    required double verticalPadding,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.symmetric(
        horizontal: 14,
        vertical: verticalPadding,
      ),
      title: Text(title, style: TextStyle(fontSize: fontSize)),
      tileColor: Colors.grey.shade200,
      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      onTap: _isLoggingOut //when logging out the tile is disable
          ? null
          : () {
        FocusManager.instance.primaryFocus?.unfocus();
        onTap();
      },
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xff0B1E40),
      centerTitle: false,
      titleSpacing: 16,
      automaticallyImplyLeading: false,
      leadingWidth: 0,
      leading: null,
      title: const Text(
        "Profile",
        style: TextStyle(color: Colors.white),
      ),
    );
  }

  Widget _buildScaffoldShell({
    required Widget body,
    bool showBottomNav = true,
  }) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: body,
      bottomNavigationBar: showBottomNav
          ? const BottomNav(
        currentIndex: 3,
        hasFab: false,
        isRootScreen: true,
      )
          : null,
    );
  }

  Widget _buildLoadingScaffold() {
    return _buildScaffoldShell(
      body: const SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: Center(
                child: CircularProgressIndicator(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  //generic message UI
  Widget _buildMessageScaffold({
    required IconData icon,
    required String title,
    required String message,
    Widget? action,
  }) {
    return _buildScaffoldShell(
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

  Widget _buildProfileBody(_ProfileBootstrapState state) {
    final name = state.name!;
    final email = state.email!;
    final role = state.role!;

    return PopScope(
      canPop: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;

          final isTablet = w >= 600;

          final horizontalPadding = isTablet ? 32.0 : 20.0;
          final topPadding = h < 650 ? 16.0 : 24.0;

          final avatarRadius =
          isTablet ? 52.0 : (h < 650 ? 38.0 : 45.0);
          final avatarFont =
          isTablet ? 40.0 : (h < 650 ? 28.0 : 35.0);

          final emailFont = isTablet ? 20.0 : 18.0;
          final roleFont = isTablet ? 15.0 : 13.0;

          final sectionGap = isTablet ? 20.0 : 14.0;
          final tileRadius = isTablet ? 14.0 : 10.0;
          final tileFont = isTablet ? 17.0 : 16.0;
          final tileVerticalPadding = isTablet ? 6.0 : 2.0;

          final cardRadius = isTablet ? 18.0 : 14.0;

          return SafeArea(
            child: SingleChildScrollView(
              keyboardDismissBehavior:
              ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                topPadding,
                horizontalPadding,
                24,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF6F6FB),
                      borderRadius: BorderRadius.circular(cardRadius),
                    ),
                    padding: EdgeInsets.all(isTablet ? 24 : 18),
                    //profile card
                    child: Column(
                      children: [
                        CircleAvatar(
                          radius: avatarRadius,
                          child: Text(
                            name.isNotEmpty ? name[0].toUpperCase() : "?",
                            style: TextStyle(fontSize: avatarFont),
                          ),
                        ),
                        SizedBox(height: isTablet ? 18 : 14),
                        Text(
                          email.isEmpty ? "No email" : email,
                          style: TextStyle(fontSize: emailFont),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Role: $role",
                          style: TextStyle(
                            color: Colors.grey,
                            fontSize: roleFont,
                          ),
                        ),
                      ],
                    ),
                  ),
                  //admin only buttons
                  SizedBox(height: sectionGap),
                  if (role == "admin") ...[
                    _actionTile(
                      title: "All Past Orders",
                      radius: tileRadius,
                      fontSize: tileFont,
                      verticalPadding: tileVerticalPadding,
                      onTap: () {
                        if (!mounted) return;
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const AdminUsersScreen(),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    _actionTile(
                      title: "Manage Users",
                      radius: tileRadius,
                      fontSize: tileFont,
                      verticalPadding: tileVerticalPadding,
                      onTap: () {
                        if (!mounted) return;
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const ManageUsersScreen(),
                          ),
                        );
                      },
                    ),
                    SizedBox(height: sectionGap),
                  ],
                  //logout button
                  ElevatedButton(
                    onPressed: _isLoggingOut ? null : logout,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      minimumSize: const Size(double.infinity, 50),
                      padding: EdgeInsets.symmetric(
                        vertical: isTablet ? 16 : 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          isTablet ? 14 : 12,
                        ),
                      ),
                    ),
                    child: _isLoggingOut
                        ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                        : const Text("LOG OUT"),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final future = _bootstrapFuture ?? _buildBootstrapForUser(_currentUser);

    return FutureBuilder<_ProfileBootstrapState>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done && !_isLoggingOut) {
          return _buildLoadingScaffold();
        }

        //default fall back state
        final state = snapshot.data ?? const _ProfileBootstrapState.error(
          message: "Unable to load profile.",
        );

        if (_isLoggingOut) {
          return _buildMessageScaffold(
            icon: Icons.logout,
            title: "Signing out",
            message: "Please wait...",
          );
        }

        if (state.isSignedOut) {
          return _buildMessageScaffold(
            icon: Icons.lock_outline,
            title: "Not signed in",
            message: "Please sign in to access your profile.",
          );
        }

        if (state.isMissingTenant) {
          return _buildMessageScaffold(
            icon: Icons.apartment_outlined,
            title: "Tenant not found",
            message: "Your account is not assigned to a tenant yet.",
          );
        }

        if (!state.isReady) {
          return _buildMessageScaffold(
            icon: Icons.error_outline,
            title: "Unable to load profile",
            message: state.message ?? "Something went wrong.",
            action: ElevatedButton(
              onPressed: () {
                if (!mounted) return;
                setState(() {
                  _bootstrapFuture = _buildBootstrapForUser(_currentUser);
                });
              },
              child: const Text("Retry"),
            ),
          );
        }

        return _buildScaffoldShell(
          body: _buildProfileBody(state),
        );
      },
    );
  }
}

class _ProfileBootstrapState {
  final String? tenantId;
  final String? name;
  final String? email;
  final String? role;
  final bool isSignedOut;
  final bool isMissingTenant;
  final String? message;

  const _ProfileBootstrapState._({
    required this.tenantId,
    required this.name,
    required this.email,
    required this.role,
    required this.isSignedOut,
    required this.isMissingTenant,
    required this.message,
  });

  const _ProfileBootstrapState.ready({
    required String tenantId,
    required String name,
    required String email,
    required String role,
  }) : this._(
    tenantId: tenantId,
    name: name,
    email: email,
    role: role,
    isSignedOut: false,
    isMissingTenant: false,
    message: null,
  );

  const _ProfileBootstrapState.signedOut()
      : this._(
    tenantId: null,
    name: null,
    email: null,
    role: null,
    isSignedOut: true,
    isMissingTenant: false,
    message: null,
  );

  const _ProfileBootstrapState.missingTenant()
      : this._(
    tenantId: null,
    name: null,
    email: null,
    role: null,
    isSignedOut: false,
    isMissingTenant: true,
    message: null,
  );

  const _ProfileBootstrapState.error({
    required String message,
  }) : this._(
    tenantId: null,
    name: null,
    email: null,
    role: null,
    isSignedOut: false,
    isMissingTenant: false,
    message: message,
  );

  bool get isReady =>
      tenantId != null &&
          tenantId!.trim().isNotEmpty &&
          name != null &&
          email != null &&
          role != null;
}