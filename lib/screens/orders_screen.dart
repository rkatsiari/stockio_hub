import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/tenant_context_service.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/top_toast.dart';
import 'manage_shops_screen.dart';
import 'order_details_screen.dart';
import 'shop_orders_screen.dart';

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  late final StreamSubscription<User?> _authSub;

  User? _currentUser;
  Future<_OrdersBootstrapState>? _bootstrapFuture;

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
        msg.contains("user_signed_out");
  }

  Future<_OrdersBootstrapState> _buildBootstrapForUser(User? user) async {
    if (user == null) {
      return const _OrdersBootstrapState.signedOut();
    }

    final tenantContext = TenantContextService();

    try {
      String? tenantId = await tenantContext.tryGetTenantIdCacheOnly();
      tenantId ??= await tenantContext.tryGetTenantId();

      String? role = await tenantContext.tryGetRoleCacheOnly();
      role ??= await tenantContext.tryGetRole();

      final resolvedTenantId = (tenantId ?? "").trim();
      final resolvedRole = (role == null || role.trim().isEmpty)
          ? "staff"
          : role.trim();

      if (resolvedTenantId.isEmpty) {
        return const _OrdersBootstrapState.missingTenant();
      }

      return _OrdersBootstrapState.ready(
        tenantId: resolvedTenantId,
        role: resolvedRole,
      );
    } catch (e) {
      if (_isAuthOrPermissionError(e)) {
        return const _OrdersBootstrapState.signedOut();
      }

      return _OrdersBootstrapState.error(
        message: e.toString().replaceFirst("Exception: ", "").trim().isEmpty
            ? "Failed to load tenant."
            : e.toString().replaceFirst("Exception: ", "").trim(),
      );
    }
  }

  Widget _buildCenteredState({
    required String title,
    required String subtitle,
    IconData icon = Icons.info_outline,
    Widget? action,
  }) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Orders",
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xff0B1E40),
        automaticallyImplyLeading: false,
      ),
      bottomNavigationBar: const BottomNav(
        currentIndex: 2,
        hasFab: false,
        isRootScreen: true,
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
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
                    subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
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

  Widget _buildLoadingScaffold() {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Orders",
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xff0B1E40),
        automaticallyImplyLeading: false,
      ),
      bottomNavigationBar: const BottomNav(
        currentIndex: 2,
        hasFab: false,
        isRootScreen: true,
      ),
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

  @override
  Widget build(BuildContext context) {
    final future = _bootstrapFuture ?? _buildBootstrapForUser(_currentUser);

    return FutureBuilder<_OrdersBootstrapState>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildLoadingScaffold();
        }

        final state = snapshot.data ??
            const _OrdersBootstrapState.error(
              message: "Failed to load Orders screen.",
            );

        if (state.isSignedOut) {
          return _buildCenteredState(
            title: "Not signed in",
            subtitle: "Please sign in to access your orders.",
            icon: Icons.lock_outline,
          );
        }

        if (state.isMissingTenant) {
          return _buildCenteredState(
            title: "Tenant not found",
            subtitle: "Your account is not assigned to a tenant yet.",
            icon: Icons.apartment_outlined,
          );
        }

        if (!state.isReady) {
          return _buildCenteredState(
            title: "Could not load Orders",
            subtitle: state.message ?? "Something went wrong.",
            icon: Icons.error_outline,
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

        return _OrdersContent(
          key: ValueKey<String>('orders-${state.tenantId}-${state.role}'),
          tenantId: state.tenantId!,
          role: state.role!,
        );
      },
    );
  }
}

class _OrdersBootstrapState {
  final String? tenantId;
  final String? role;
  final bool isSignedOut;
  final bool isMissingTenant;
  final String? message;

  const _OrdersBootstrapState._({
    required this.tenantId,
    required this.role,
    required this.isSignedOut,
    required this.isMissingTenant,
    required this.message,
  });

  const _OrdersBootstrapState.ready({
    required String tenantId,
    required String role,
  }) : this._(
    tenantId: tenantId,
    role: role,
    isSignedOut: false,
    isMissingTenant: false,
    message: null,
  );

  const _OrdersBootstrapState.signedOut()
      : this._(
    tenantId: null,
    role: null,
    isSignedOut: true,
    isMissingTenant: false,
    message: null,
  );

  const _OrdersBootstrapState.missingTenant()
      : this._(
    tenantId: null,
    role: null,
    isSignedOut: false,
    isMissingTenant: true,
    message: null,
  );

  const _OrdersBootstrapState.error({
    required String message,
  }) : this._(
    tenantId: null,
    role: null,
    isSignedOut: false,
    isMissingTenant: false,
    message: message,
  );

  bool get isReady => tenantId != null && tenantId!.trim().isNotEmpty;
}

class _OrdersContent extends StatefulWidget {
  final String tenantId;
  final String role;

  const _OrdersContent({
    super.key,
    required this.tenantId,
    required this.role,
  });

  @override
  State<_OrdersContent> createState() => _OrdersContentState();
}

class _OrdersContentState extends State<_OrdersContent> {
  StreamSubscription<User?>? _authSub;

  String searchQuery = "";
  bool _handledSignedOut = false;

  bool get _isAdmin => widget.role == "admin";
  bool get _isStorageManager => widget.role == "storage_manager";
  bool get _canViewAllOrders => _isStorageManager;
  bool get _canCreateOrders => !_isStorageManager;

  @override
  void initState() {
    super.initState();
    _listenToAuthChanges();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  void _listenToAuthChanges() {
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted || _handledSignedOut) return;
      if (user == null) {
        _handledSignedOut = true;
      }
    });
  }

  bool _isSignedOut() => FirebaseAuth.instance.currentUser == null;

  void _toast(String msg, {bool error = true}) {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    if (error) {
      TopToast.error(context, msg);
    } else {
      TopToast.success(context, msg);
    }
  }

  void _safePopDialogWithResult<T>(NavigatorState navigator, T result) {
    FocusManager.instance.primaryFocus?.unfocus();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted && navigator.canPop()) {
        navigator.pop(result);
      }
    });
  }

  Future<QuerySnapshot<Map<String, dynamic>>?> _tryGetQueryServerThenCache(
      Query<Map<String, dynamic>> query,
      ) async {
    try {
      return await query.get().timeout(const Duration(milliseconds: 1200));
    } catch (_) {}

    try {
      return await query
          .get(const GetOptions(source: Source.cache))
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {}

    return null;
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _tryGetDocServerThenCache(
      DocumentReference<Map<String, dynamic>> ref,
      ) async {
    try {
      return await ref.get().timeout(const Duration(milliseconds: 1200));
    } catch (_) {}

    try {
      return await ref
          .get(const GetOptions(source: Source.cache))
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {}

    return null;
  }

  Future<Map<String, String>> _getCurrentUserInfo(String uid) async {
    final ref = FirebaseFirestore.instance.collection("users").doc(uid);
    final snap = await _tryGetDocServerThenCache(ref);
    final data = snap?.data() ?? <String, dynamic>{};

    return {
      "name": (data["name"] ?? "").toString().trim(),
      "email": (data["email"] ?? "").toString().trim(),
    };
  }

  CollectionReference<Map<String, dynamic>> _ordersCol(String tenantId) {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(tenantId)
        .collection("orders");
  }

  CollectionReference<Map<String, dynamic>> _shopsCol(String tenantId) {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(tenantId)
        .collection("shops");
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: TextField(
        onChanged: (v) => setState(() => searchQuery = v.trim().toLowerCase()),
        decoration: InputDecoration(
          hintText: "Search shops by name...",
          prefixIcon: const Icon(Icons.search),
          filled: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Future<void> _createOrderAndOpen() async {
    if (!_canCreateOrders) {
      _toast("Storage Manager cannot create orders.", error: true);
      return;
    }

    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    final navigator = Navigator.of(context);
    final tenantId = widget.tenantId;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) {
      _toast("You must be logged in.", error: true);
      return;
    }

    try {
      final activeQuery = _ordersCol(tenantId)
          .where("userId", isEqualTo: uid)
          .where("isActive", isEqualTo: true)
          .limit(1);

      final activeSnap = await _tryGetQueryServerThenCache(activeQuery);

      if (!mounted || _isSignedOut() || _handledSignedOut) return;

      if ((activeSnap?.docs ?? []).isNotEmpty) {
        _toast("You already have an active order.", error: true);
        return;
      }

      final shopsQuery =
      _shopsCol(tenantId).orderBy("createdAt", descending: false);
      final shopsSnap = await _tryGetQueryServerThenCache(shopsQuery);

      if (!mounted || _isSignedOut() || _handledSignedOut) return;

      final shops =
          shopsSnap?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[];

      String orderName = "";
      String? selectedShopId;
      String selectedShopName = "";

      if (shops.isEmpty) {
        final nameCtrl = TextEditingController();

        try {
          final ok = await showDialog<bool>(
            context: context,
            builder: (dialogContext) {
              final dialogNavigator = Navigator.of(dialogContext);

              return AlertDialog(
                title: const Text("New Order"),
                content: TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: "Order name"),
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    final v = nameCtrl.text.trim();
                    if (v.isEmpty) return;
                    _safePopDialogWithResult(dialogNavigator, true);
                  },
                ),
                actions: [
                  TextButton(
                    onPressed: () => _safePopDialogWithResult(
                      dialogNavigator,
                      false,
                    ),
                    child: const Text("Cancel"),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      final v = nameCtrl.text.trim();
                      if (v.isEmpty) return;
                      _safePopDialogWithResult(dialogNavigator, true);
                    },
                    child: const Text("Create"),
                  ),
                ],
              );
            },
          );

          if (ok != true) return;

          orderName = nameCtrl.text.trim();
          if (orderName.isEmpty) return;

          selectedShopId = null;
          selectedShopName = "";
        } finally {
          nameCtrl.dispose();
        }
      } else {
        selectedShopId = shops.first.id;
        selectedShopName = (shops.first.data()["name"] ?? "Untitled").toString();

        final ok = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            final dialogNavigator = Navigator.of(dialogContext);

            return StatefulBuilder(
              builder: (dialogContext, setLocal) {
                return AlertDialog(
                  title: const Text("New Order"),
                  content: DropdownButtonFormField<String>(
                    value: selectedShopId,
                    decoration: const InputDecoration(
                      labelText: "Shop",
                      border: OutlineInputBorder(),
                    ),
                    items: shops.map((d) {
                      final data = d.data();
                      final shopName = (data["name"] ?? "Untitled").toString();
                      return DropdownMenuItem<String>(
                        value: d.id,
                        child: Text(shopName),
                      );
                    }).toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      final doc = shops.firstWhere((x) => x.id == v);
                      final data = doc.data();
                      setLocal(() {
                        selectedShopId = v;
                        selectedShopName =
                            (data["name"] ?? "Untitled").toString();
                      });
                    },
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => _safePopDialogWithResult(
                        dialogNavigator,
                        false,
                      ),
                      child: const Text("Cancel"),
                    ),
                    ElevatedButton(
                      onPressed: () => _safePopDialogWithResult(
                        dialogNavigator,
                        true,
                      ),
                      child: const Text("Create"),
                    ),
                  ],
                );
              },
            );
          },
        );

        if (ok != true) return;

        orderName = selectedShopName.trim().isEmpty
            ? "Untitled"
            : selectedShopName.trim();
      }

      final userInfo = await _getCurrentUserInfo(uid);

      if (!mounted || _isSignedOut() || _handledSignedOut) return;

      final userName =
      userInfo["name"]!.isEmpty ? "Unknown" : userInfo["name"]!;
      final userEmail = userInfo["email"] ?? "";

      final newOrderRef = await _ordersCol(tenantId).add({
        "name": orderName,
        "userId": uid,
        "userName": userName,
        "userEmail": userEmail,
        "shopId": selectedShopId,
        "shopName": selectedShopName,
        "createdAt": FieldValue.serverTimestamp(),
        "isActive": true,
        "isExported": false,
        "exportedAt": null,
        "closedAt": null,
      });

      if (!mounted || _isSignedOut() || _handledSignedOut) return;

      await navigator.push(
        MaterialPageRoute(
          builder: (_) => OrderDetailsScreen(orderId: newOrderRef.id),
        ),
      );
    } catch (_) {
      if (!mounted || _isSignedOut() || _handledSignedOut) return;
      _toast("Failed to create order.", error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final tenantId = widget.tenantId;

    if (uid == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            "Orders",
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: const Color(0xff0B1E40),
          automaticallyImplyLeading: false,
        ),
        body: const Center(child: Text("You must be logged in.")),
        bottomNavigationBar: const BottomNav(
          currentIndex: 2,
          hasFab: false,
          isRootScreen: true,
        ),
      );
    }

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _ordersCol(tenantId)
          .where("userId", isEqualTo: uid)
          .where("isActive", isEqualTo: true)
          .limit(1)
          .snapshots(),
      builder: (context, activeSnap) {
        final hasActive =
            activeSnap.hasData && activeSnap.data!.docs.isNotEmpty;

        return PopScope(
          canPop: false,
          child: Scaffold(
            appBar: AppBar(
              title: const Text(
                "All Past Orders",
                style: TextStyle(color: Colors.white),
              ),
              backgroundColor: const Color(0xff0B1E40),
              automaticallyImplyLeading: false,
              actions: [
                if (_isAdmin)
                  IconButton(
                    icon: const Icon(
                      Icons.store,
                      color: Colors.white,
                    ),
                    tooltip: "Manage shops",
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ManageShopsScreen(),
                        ),
                      );
                    },
                  ),
              ],
            ),
            floatingActionButtonLocation:
            FloatingActionButtonLocation.centerDocked,
            floatingActionButton: _canCreateOrders
                ? FloatingActionButton(
              backgroundColor: hasActive
                  ? Colors.grey.shade500
                  : const Color(0xff0B1E40),
              onPressed: hasActive ? null : _createOrderAndOpen,
              child: const Icon(
                Icons.add,
                size: 32,
                color: Colors.white,
              ),
            )
                : null,
            body: Column(
              children: [
                _buildSearchBar(),
                ListTile(
                  leading: const Icon(Icons.receipt_long),
                  title: Text(
                    _canViewAllOrders
                        ? "All Orders (Everyone)"
                        : "All Orders (Mine)",
                  ),
                  subtitle: Text(
                    _canViewAllOrders
                        ? "View orders from all users"
                        : "View your orders across all shops",
                  ),
                  trailing: const Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ShopOrdersScreen(
                          shopId: null,
                          shopName: "All Orders",
                        ),
                      ),
                    );
                  },
                ),
                const Divider(height: 1),
                Expanded(
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _shopsCol(tenantId)
                        .orderBy("createdAt", descending: false)
                        .snapshots(),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return const Center(
                          child: Text("Error loading shops"),
                        );
                      }

                      if (!snap.hasData) {
                        return const Center(
                          child: CircularProgressIndicator(),
                        );
                      }

                      final docs = snap.data!.docs;

                      final filtered = docs.where((d) {
                        final data = d.data();
                        final name =
                        (data["name"] ?? "").toString().toLowerCase();

                        if (searchQuery.isEmpty) return true;
                        return name.contains(searchQuery);
                      }).toList();

                      if (filtered.isEmpty) {
                        return Center(
                          child: Text(
                            docs.isEmpty
                                ? (_isAdmin
                                ? "No shops yet. Add one from the top-right store icon."
                                : "No shops yet. Ask an admin to add shops.")
                                : "No matching shops",
                          ),
                        );
                      }

                      return ListView(
                        padding: EdgeInsets.only(
                          bottom: _canCreateOrders ? 120 : 24,
                        ),
                        children: filtered.map((d) {
                          final data = d.data();
                          final shopName =
                          (data["name"] ?? "Untitled").toString();

                          return ListTile(
                            leading: const Icon(Icons.store),
                            title: Text(shopName),
                            subtitle: const Text(
                              "View orders for this shop",
                            ),
                            trailing: const Icon(
                              Icons.arrow_forward_ios,
                              size: 16,
                            ),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ShopOrdersScreen(
                                    shopId: d.id,
                                    shopName: shopName,
                                  ),
                                ),
                              );
                            },
                          );
                        }).toList(),
                      );
                    },
                  ),
                ),
              ],
            ),
            bottomNavigationBar: BottomNav(
              currentIndex: 2,
              hasFab: _canCreateOrders,
              isRootScreen: true,
            ),
          ),
        );
      },
    );
  }
}