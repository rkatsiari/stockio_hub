//admin can see all users in that tenant
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/tenant_context_service.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/top_toast.dart';
import 'admin_user_orders_screen.dart';

class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key}); //constructor

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  //constant
  static const Duration _searchDebounce = Duration(milliseconds: 350);

  //controllers
  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _liveSearchQuery = ValueNotifier<String>("");
  final ValueNotifier<String> _debouncedSearchQuery = ValueNotifier<String>(""); //avoid heavy rebuilds

  late final Future<String> _tenantIdFuture; //tenantId to be returned only once

  StreamSubscription<User?>? _authSub;
  Timer? _searchTimer;

  //flags
  bool _handledSignedOut = false;
  bool _tenantErrorToastShown = false;
  bool _streamErrorToastShown = false;

  @override
  void initState() {
    super.initState(); //must be called first
    _tenantIdFuture = TenantContextService().getTenantIdOrThrow();
    _listenToAuthChanges();
    _searchController.addListener(_onSearchChanged);
  }

  //auth listener
  void _listenToAuthChanges() {
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted || _handledSignedOut) return;

      if (user == null) {
        _handledSignedOut = true;

        WidgetsBinding.instance.addPostFrameCallback((_) { //avoids navigation errors during build
          if (!mounted) return;
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        });
      }
    });
  }

  //search change handle
  void _onSearchChanged() {
    final value = _searchController.text.trim().toLowerCase();

    if (_liveSearchQuery.value != value) {
      _liveSearchQuery.value = value;
    }

    _searchTimer?.cancel();
    _searchTimer = Timer(_searchDebounce, () {
      if (!mounted || _handledSignedOut) return;
      if (_debouncedSearchQuery.value != value) {
        _debouncedSearchQuery.value = value;
      }
    });
  }

  void _clearSearch() {
    _searchTimer?.cancel();
    _searchController.clear();
    _liveSearchQuery.value = "";
    _debouncedSearchQuery.value = "";
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: const Text(
        "All Users",
        style: TextStyle(color: Colors.white),
      ),
      backgroundColor: const Color(0xff0B1E40),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: ValueListenableBuilder<String>(
        valueListenable: _liveSearchQuery, //current live search text
        builder: (context, liveQuery, _) {
          return TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: "Search users by name or email...",
              prefixIcon: const Icon(Icons.search),
              suffixIcon: liveQuery.isEmpty
                  ? null
                  : IconButton(
                onPressed: _clearSearch,
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

  //search filtering logic
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _applySearch(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> allUsers,
      String searchQuery,
      ) {
    final visibleUsers = allUsers.where((doc) { //filter list of users
      final data = doc.data(); //get map data from firestore
      final role = (data["role"] ?? "").toString().trim().toLowerCase();
      return role != "storage_manager"; //exclude any user of role storage manager (they do not create orders)
    }).toList();

    //return all visible users if no text in search bar
    if (searchQuery.isEmpty) return visibleUsers;

    return visibleUsers.where((doc) {
      final data = doc.data();
      final name = (data["name"] ?? "").toString().toLowerCase(); //read name in lower
      final email = (data["email"] ?? "").toString().toLowerCase(); //read email in lower
      return name.contains(searchQuery) || email.contains(searchQuery);
    }).toList(); //return results in list form
  }

  Widget _buildStaticHeader() {
    return Column(
      children: [
        _buildSearchBar(),
        ListTile(
          leading: const Icon(Icons.receipt_long),
          title: const Text("All Orders (Everyone)"), //main text of tile
          subtitle: const Text("View orders from all users"), //subtitle text
          trailing: const Icon(Icons.arrow_forward_ios, size: 16),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const AdminUserOrdersScreen( //navigate to this screen
                  userId: null,
                  userName: "All Users",
                ),
              ),
            );
          },
        ),
        const Divider(height: 1), //divider line below each tile
      ],
    );
  }

  //loading scaffold
  Widget _buildLoadingScaffold({required bool keyboardOpen}) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildStaticHeader(),
          const Expanded(
            child: Center(
              child: CircularProgressIndicator(),
            ),
          ),
        ],
      ),
      //hide bottom navigation when keyboard is open
      bottomNavigationBar: keyboardOpen
          ? null
          : const BottomNav(
        currentIndex: 4,
        hasFab: false,
        isRootScreen: false,
      ),
    );
  }

  //tenant error scaffold
  Widget _buildTenantErrorScaffold({
    required bool keyboardOpen,
    required Object? error,
  }) {
    if (!_tenantErrorToastShown) { //show error once
      _tenantErrorToastShown = true; //mark as shown
      WidgetsBinding.instance.addPostFrameCallback((_) { //show toast after frame finish
        if (!mounted) return; //safety check
        TopToast.error(
          context,
          "Failed to load tenant.", //red toast message
        );
      });
    }

    return Scaffold(
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildStaticHeader(),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24), //spacing around error
                child: Text(
                  error?.toString() ?? "Failed to load tenant.",
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
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

  //clean up resources
  @override
  void dispose() {
    _searchTimer?.cancel();
    _authSub?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose(); //free memory
    _liveSearchQuery.dispose();
    _debouncedSearchQuery.dispose();
    super.dispose(); //parent clean up
  }

  //main UI method
  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    final fs = FirebaseFirestore.instance;

    return FutureBuilder<String>(
      future: _tenantIdFuture, //wait for _tenantIdFuture to finish loading
      builder: (context, tenantSnap) {
        if (tenantSnap.connectionState == ConnectionState.waiting) {
          return _buildLoadingScaffold(keyboardOpen: keyboardOpen);
        }

        if (tenantSnap.hasError || !tenantSnap.hasData) {
          return _buildTenantErrorScaffold(
            keyboardOpen: keyboardOpen,
            error: tenantSnap.error,
          );
        }

        final tenantId = tenantSnap.data!;

        //main scaffold
        return Scaffold(
          appBar: _buildAppBar(),
          body: Column(
            children: [
              _buildStaticHeader(), //all orders tile
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: fs //read users from tenants/{tenantId}/users
                      .collection("tenants")
                      .doc(tenantId)
                      .collection("users")
                      .orderBy("name") //alphabetical order
                      .snapshots(), //real-time updates
                  builder: (context, snap) { //snap contains the stream build
                    //stream error handling
                    if (snap.hasError) {
                      if (!_streamErrorToastShown) {
                        _streamErrorToastShown = true;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted) return;
                          TopToast.error(context, "Error loading users");
                        });
                      }

                      return const Center(
                        child: Text("Error loading users"),
                      );
                    } else {
                      _streamErrorToastShown = false;
                    }

                    if (!snap.hasData) {
                      return const Center(
                        child: CircularProgressIndicator(),
                      );
                    }

                    final allUsers = snap.data!.docs; //get user documents

                    return ValueListenableBuilder<String>(
                      valueListenable: _debouncedSearchQuery,
                      builder: (context, searchQuery, _) { //searchQuery is the debounce search text
                        final filtered = _applySearch(allUsers, searchQuery); //filter the user list

                        //empty state
                        if (filtered.isEmpty) {
                          return const Center(
                            child: Text("No users found"),
                          );
                        }

                        return ListView.separated( //display users in a scrollable list
                          keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.only(bottom: 16), //add space at the bottom
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const Divider(height: 1), //divider line
                          itemBuilder: (context, index) {
                            final doc = filtered[index];
                            final data = doc.data();
                            final name =
                            (data["name"] ?? "Unnamed").toString().trim();
                            final email =
                            (data["email"] ?? "").toString().trim();

                            return ListTile(
                              leading: const Icon(Icons.person),
                              title: Text(
                                name.isEmpty ? "Unnamed" : name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis, //keep title in one line with ... if too long
                              ),
                              subtitle: email.isEmpty
                                  ? null
                                  : Text(
                                email,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(
                                Icons.arrow_forward_ios, //show navigation
                                size: 16,
                              ),
                              onTap: () {
                                FocusScope.of(context).unfocus(); //hide keyboard before navigation

                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => AdminUserOrdersScreen(
                                      userId: doc.id,
                                      userName: name.isEmpty ? "Unnamed" : name,
                                    ),
                                  ),
                                );
                              },
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
          bottomNavigationBar: keyboardOpen
              ? null
              : const BottomNav(
            currentIndex: 4,
            hasFab: false, //no floating action button
            isRootScreen: false, //not the root page of that tab
          ),
        );
      },
    );
  }
}