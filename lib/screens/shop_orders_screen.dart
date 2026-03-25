//view orders of a specific shop
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/tenant_context_service.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/top_toast.dart';
import 'order_details_screen.dart';

class ShopOrdersScreen extends StatefulWidget {
  final String? shopId;
  final String shopName;

  const ShopOrdersScreen({
    super.key,
    required this.shopId,
    required this.shopName,
  });

  @override
  State<ShopOrdersScreen> createState() => _ShopOrdersScreenState();
}

class _ShopOrdersScreenState extends State<ShopOrdersScreen> {
  final TenantContextService _tenantContext = TenantContextService();

  String searchQuery = "";
  String selectedFilter = "all";

  String _role = "staff";
  bool _roleLoaded = false;
  bool _tenantLoaded = false;
  bool _errorShown = false;

  String? _tenantId;

  //getters
  bool get _isStorageManager => _role == "storage_manager";
  bool get _canSeeAllOrders => _isStorageManager;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  bool _isSignedOut() => FirebaseAuth.instance.currentUser == null;

  Future<void> _bootstrap() async {
    await Future.wait([
      _loadTenantId(),
      _loadRole(),
    ]);
  }

  void _toast(String msg, {bool error = true}) {
    if (!mounted) return;
    if (_isSignedOut()) return;

    if (error) {
      TopToast.error(context, msg);
    } else {
      TopToast.success(context, msg);
    }
  }

  Future<void> _loadTenantId() async {
    try {
      if (_isSignedOut()) {
        if (!mounted) return;
        setState(() {
          _tenantId = null;
          _tenantLoaded = true;
        });
        return;
      }

      String? tenantId = await _tenantContext.tryGetTenantIdCacheOnly();
      tenantId ??= await _tenantContext.tryGetTenantId();

      if (!mounted) return;
      setState(() {
        _tenantId = tenantId;
        _tenantLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _tenantId = null;
        _tenantLoaded = true;
      });
    }
  }

  Future<void> _loadRole() async {
    try {
      if (_isSignedOut()) {
        if (!mounted) return;
        setState(() {
          _role = "staff";
          _roleLoaded = true;
        });
        return;
      }

      String? role = await _tenantContext.tryGetRoleCacheOnly();
      role ??= await _tenantContext.tryGetRole();

      if (!mounted) return;
      setState(() {
        _role = (role == null || role.trim().isEmpty) ? "staff" : role.trim();
        _roleLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _role = "staff";
        _roleLoaded = true;
      });
    }
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: TextField(
        onChanged: (v) => setState(() => searchQuery = v.trim().toLowerCase()),
        decoration: InputDecoration(
          hintText: "Search orders by name...",
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

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _filterChip("all", "All"),
            const SizedBox(width: 8),
            _filterChip("active", "Active"),
            const SizedBox(width: 8),
            _filterChip("finished", "Finished"),
            const SizedBox(width: 8),
            _filterChip("exported", "Exported"),
          ],
        ),
      ),
    );
  }

  //filters build
  Widget _filterChip(String value, String label) {
    final isSelected = selectedFilter == value;

    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) {
        setState(() {
          selectedFilter = value;
        });
      },
    );
  }

  //query builders
  Query<Map<String, dynamic>> _ordersQuery(
      FirebaseFirestore fs,
      String tenantId,
      String uid,
      ) {
    Query<Map<String, dynamic>> query =
    fs.collection("tenants").doc(tenantId).collection("orders");

    //shop filtering
    if (widget.shopId != null) {
      query = query.where("shopId", isEqualTo: widget.shopId);
    }

    //role base filtering
    if (_isStorageManager) {
      query = query.where("isExported", isEqualTo: true);
    } else {
      query = query.where("userId", isEqualTo: uid);
    }

    //newest order appear on the top
    return query.orderBy("createdAt", descending: true);
  }

  String _screenTitle() {
    if (widget.shopId != null) return widget.shopName;
    if (!_roleLoaded) return "Orders";
    return _canSeeAllOrders ? "All Orders" : "All My Orders";
  }

  String _emptyMessage() {
    if (widget.shopId == null) {
      return "No orders found";
    }

    return _canSeeAllOrders
        ? "No orders for this shop"
        : "No orders found for this shop";
  }

  Widget _buildSignedOutScaffold(String title) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xff0B1E40),
      ),
      bottomNavigationBar: const BottomNav(currentIndex: 2, hasFab: false, isRootScreen: false),
      body: const Center(
        child: Text("You must be logged in."),
      ),
    );
  }

  Widget _buildTenantErrorScaffold(String title) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xff0B1E40),
      ),
      bottomNavigationBar: const BottomNav(currentIndex: 2, hasFab: false, isRootScreen: false),
      body: const Center(
        child: Text("Failed to load tenant."),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fs = FirebaseFirestore.instance;

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        final user = authSnap.data;
        final uid = user?.uid;
        final title = _screenTitle();

        if (authSnap.connectionState == ConnectionState.waiting &&
            !_tenantLoaded) {
          return Scaffold(
            appBar: AppBar(
              title: Text(title, style: const TextStyle(color: Colors.white)),
              backgroundColor: const Color(0xff0B1E40),
            ),
            bottomNavigationBar:
            const BottomNav(currentIndex: 2, hasFab: false, isRootScreen: false),
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        if (uid == null) {
          return _buildSignedOutScaffold(title);
        }

        if (!_tenantLoaded || !_roleLoaded) {
          return Scaffold(
            appBar: AppBar(
              title: Text(title, style: const TextStyle(color: Colors.white)),
              backgroundColor: const Color(0xff0B1E40),
            ),
            bottomNavigationBar:
            const BottomNav(currentIndex: 2, hasFab: false, isRootScreen: false),
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        if (_tenantId == null || _tenantId!.isEmpty) {
          return _buildTenantErrorScaffold(title);
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(
              _screenTitle(),
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: const Color(0xff0B1E40),
          ),
          bottomNavigationBar:
          const BottomNav(currentIndex: 2, hasFab: false, isRootScreen: false),
          body: Column(
            children: [
              _buildSearchBar(),
              if (!_isStorageManager) _buildFilterBar(),
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _ordersQuery(fs, _tenantId!, uid).snapshots(),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      if (!_errorShown) {
                        _errorShown = true;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted || _isSignedOut()) return;
                          _toast("Failed to load orders.", error: true);
                        });
                      }

                      return const Center(
                        child: Text("Failed to load orders."),
                      );
                    }

                    if (!snap.hasData) {
                      return const Center(
                        child: CircularProgressIndicator(),
                      );
                    }

                    _errorShown = false;

                    final allOrders = snap.data!.docs;

                    //client-side filtering
                    final filtered = allOrders.where((d) {
                      final data = d.data();
                      final name =
                      (data["name"] ?? "").toString().toLowerCase();

                      final isActive = data["isActive"] == true;
                      final isExported = data["isExported"] == true;
                      final isFinished = !isActive && !isExported;

                      //search match
                      final matchesSearch = searchQuery.isEmpty
                          ? true
                          : name.contains(searchQuery);

                      //filter matching
                      final matchesFilter = _isStorageManager
                          ? true
                          : selectedFilter == "all"
                          ? true
                          : selectedFilter == "active"
                          ? isActive
                          : selectedFilter == "finished"
                          ? isFinished
                          : selectedFilter == "exported"
                          ? isExported
                          : true;

                      return matchesSearch && matchesFilter;
                    }).toList();

                    if (filtered.isEmpty) {
                      return Center(
                        child: Text(_emptyMessage()),
                      );
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final d = filtered[index];
                        final data = d.data();

                        final name = (data["name"] ?? "Untitled").toString();
                        final isActive = data["isActive"] == true;
                        final isExported = data["isExported"] == true;

                        //status and icon selection
                        String status;
                        IconData icon;

                        if (isActive) {
                          status = "Active";
                          icon = Icons.receipt_long;
                        } else if (isExported) {
                          status = "Exported";
                          icon = Icons.lock;
                        } else {
                          status = "Finished";
                          icon = Icons.history;
                        }

                        //owner and shop information
                        final owner =
                        (data["userName"] ?? "").toString().trim();
                        final showOwner =
                            _canSeeAllOrders && owner.isNotEmpty;

                        final shopName =
                        (data["shopName"] ?? "").toString().trim();
                        final showShop =
                            widget.shopId == null && shopName.isNotEmpty;

                        final parts = <String>[
                          status,
                          if (showShop) shopName,
                          if (showOwner) owner,
                        ];

                        return ListTile(
                          leading: Icon(icon),
                          title: Text(name),
                          subtitle: Text(parts.join(" • ")),
                          trailing: const Icon(
                            Icons.arrow_forward_ios,
                            size: 16,
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    OrderDetailsScreen(orderId: d.id),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}