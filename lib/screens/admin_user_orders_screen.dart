//admin can view orders for each user
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/tenant_context_service.dart';
import '../widgets/top_toast.dart';
import 'order_details_screen.dart';

class AdminUserOrdersScreen extends StatefulWidget {
  final String? userId;
  final String userName;

  //constructor
  const AdminUserOrdersScreen({
    super.key,
    required this.userId,
    required this.userName,
  });

  @override
  State<AdminUserOrdersScreen> createState() => _AdminUserOrdersScreenState();
}

//logic and UI
class _AdminUserOrdersScreenState extends State<AdminUserOrdersScreen> {
  static const Duration _searchDebounce = Duration(milliseconds: 350); //wait a bit before updating filtering

  //controllers
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(); //search field stay focused
  final ValueNotifier<String> _debouncedSearchQuery = ValueNotifier<String>(""); //store final search query
  final ValueNotifier<String> _selectedFilter = ValueNotifier<String>("all"); //selected filter (all)

  late final Future<String> _tenantIdFuture;

  StreamSubscription<User?>? _authSub; //used to store auth listening subscription
  Timer? _searchTimer; //used for search debouncing

  bool _handledSignedOut = false; //prevent multiple sign-out logic
  bool _streamErrorShown = false; //prevent same error show in every build

  @override
  void initState() {
    super.initState(); //run once when the screen is build
    _tenantIdFuture = TenantContextService().getTenantIdOrThrow(); //load tenantId
    _listenToAuthChanges(); //listen for auth change
    _searchController.addListener(_onSearchChanged); //listener to text change in search
  }

  //auth listener
  void _listenToAuthChanges() {
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted || _handledSignedOut) return;

      //safe lifecycle handling
      if (user == null) {
        _handledSignedOut = true;
        TopToast.hide();

        //when sign out the screen closes
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      }
    });
  }

  //error checker
  bool _isAuthOrPermissionError(Object error) { //any error related to authentication, permission denied, signed out
    final msg = error.toString().toLowerCase(); //error message to lower case for easy check
    return msg.contains(TenantContextService.kSignedOutMessage.toLowerCase()) ||
        msg.contains("permission-denied") ||
        msg.contains("permission denied") ||
        msg.contains("unauthenticated") ||
        msg.contains("user is not signed in") ||
        msg.contains("requires authentication") ||
        msg.contains("user_signed_out") ||
        msg.contains("user signed out");
  }

  //handle search content change
  void _onSearchChanged() {
    _searchTimer?.cancel(); //cancel previous timer

    final raw = _searchController.text.trim().toLowerCase(); //trim spaces and convert to lower case for case-insensitive search

    _searchTimer = Timer(_searchDebounce, () {
      if (!mounted || _handledSignedOut) return; //safety check

      if (_debouncedSearchQuery.value != raw) {
        _debouncedSearchQuery.value = raw;
      }

      _searchFocusNode.requestFocus();
    });
  }

  //clear search
  void _clearSearch() {
    _searchTimer?.cancel();
    _searchController.clear(); //clear text field
    _debouncedSearchQuery.value = ""; //search query to empty, so all orders are shown
    _searchFocusNode.requestFocus(); //keep focus
  }

  //build search bar UI
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6), //spacing around
      child: TextField(
        controller: _searchController, //connect to search controller
        focusNode: _searchFocusNode, //connect to focus
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: "Search orders by name...", //placeholder text
          prefixIcon: const Icon(Icons.search),
          suffixIcon: ValueListenableBuilder<String>(
            valueListenable: _debouncedSearchQuery,
            builder: (context, debouncedValue, _) {
              final hasText = _searchController.text.isNotEmpty; //check for text in search
              if (!hasText) return const SizedBox.shrink();

              return IconButton(
                onPressed: _clearSearch,
                icon: const Icon(Icons.close),
              );
            },
          ),
          filled: true, //have filled background
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12), //round corners
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  //filter bar
  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: SingleChildScrollView( //horizontal scroll
        scrollDirection: Axis.horizontal,
        child: ValueListenableBuilder<String>(
          valueListenable: _selectedFilter,
          builder: (context, selected, _) {
            return Row(
              children: [ //create four chips
                _filterChip("all", "All", selected), //compare with current selection
                const SizedBox(width: 8),
                _filterChip("active", "Active", selected),
                const SizedBox(width: 8),
                _filterChip("finished", "Finished", selected),
                const SizedBox(width: 8),
                _filterChip("exported", "Exported", selected),
              ],
            );
          },
        ),
      ),
    );
  }

  //filter chip
  Widget _filterChip(String value, String label, String selected) {
    final isSelected = selected == value;

    return ChoiceChip(
      label: Text(label), //chip text
      selected: isSelected, //mark selection
      onSelected: (_) { //when a chip is taped
        if (_selectedFilter.value != value) {
          _selectedFilter.value = value;
        }
      },
    );
  }

  //firestore order query
  Query<Map<String, dynamic>> _ordersQuery(
      FirebaseFirestore fs,
      String tenantId,
      ) {
    final base = fs //create base query
        .collection("tenants")
        .doc(tenantId)
        .collection("orders")
        .orderBy("createdAt", descending: true); //newest order on top

    if (widget.userId == null) {
      return base; //all orders
    }

    return base.where("userId", isEqualTo: widget.userId); //only user's orders
  }

  //filter orders locally
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _applyFilters(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> allOrders,
      String searchQuery,
      String selectedFilter,
      ) {
    return allOrders.where((d) { //keep only matching ones
      final data = d.data(); //order data map from firestore
      final name = (data["name"] ?? "").toString().toLowerCase();

      final isActive = data["isActive"] == true; //check order if active
      final isExported = data["isExported"] == true; //check order if exported
      final isFinished = !isActive && !isExported;

      final matchesSearch = searchQuery.isEmpty ? true : name.contains(searchQuery); //

      //determine if order matches the filter
      final matchesFilter = selectedFilter == "all"
          ? true
          : selectedFilter == "active"
          ? isActive
          : selectedFilter == "finished"
          ? isFinished
          : selectedFilter == "exported"
          ? isExported
          : true;

      return matchesSearch && matchesFilter; //matches both filter and search
    }).toList();
  }

  //loading scaffold - used when tenant is loading
  Widget _buildLoadingScaffold(String title) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xff0B1E40),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      body: const Center(child: CircularProgressIndicator()), //center loading spinner
    );
  }

  //error scaffold - used when tenant loading fail
  Widget _buildErrorScaffold(String title, String message) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xff0B1E40),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      body: Center( //center the error text
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            message,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  //dispose when screen is removed
  @override
  void dispose() { //cleaning up resources
    _searchTimer?.cancel();
    _authSub?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debouncedSearchQuery.dispose();
    _selectedFilter.dispose();
    TopToast.hide();
    super.dispose(); //call parent cleanup
  }

  //build UI
  @override
  Widget build(BuildContext context) {
    final fs = FirebaseFirestore.instance;
    final title = widget.userId == null ? "All Orders" : "${widget.userName}’s Orders"; //depending on mode

    return FutureBuilder<String>(
      future: _tenantIdFuture,
      builder: (context, tenantSnap) {
        if (tenantSnap.connectionState == ConnectionState.waiting) {
          return _buildLoadingScaffold(title);
        }

        if (tenantSnap.hasError || !tenantSnap.hasData) {
          return _buildErrorScaffold(
            title,
            tenantSnap.error?.toString() ?? "Failed to load tenant.",
          );
        }

        final tenantId = tenantSnap.data!; //tenant id available

        return Scaffold(
          appBar: AppBar(
            title: Text(title, style: const TextStyle(color: Colors.white)),
            backgroundColor: const Color(0xff0B1E40),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () {
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
            ),
          ),
          body: Column(
            children: [
              _buildSearchBar(), //search bar
              _buildFilterBar(), //filter bar
              Expanded(
                //UI is updated everytime orders change in firestore
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _ordersQuery(fs, tenantId).snapshots(),
                  builder: (context, snap) { // handling stream errors
                    if (snap.hasError) { //auth or permission issue
                      if (_isAuthOrPermissionError(snap.error!)) {
                        return const Center(child: Text("Not signed in"));
                      }

                      if (!_streamErrorShown) {
                        _streamErrorShown = true;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted || _handledSignedOut) return;
                          TopToast.error(context, "Failed to load orders.");
                        });
                      }

                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: Text( //fallback error text in body
                            "Error loading orders.",
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }

                    _streamErrorShown = false; //reset error state

                    //loading spinner if there is data loading
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final allOrders = snap.data!.docs;

                    //rebuild query based on search
                    return ValueListenableBuilder<String>(
                      valueListenable: _debouncedSearchQuery,
                      builder: (context, searchQuery, _) {
                        //rebuild based on filters
                        return ValueListenableBuilder<String>(
                          valueListenable: _selectedFilter,
                          builder: (context, selectedFilter, __) {
                            final filtered = _applyFilters( //apply local filters
                              allOrders,
                              searchQuery, //search text
                              selectedFilter, //filter
                            );

                            //if there are no results
                            if (filtered.isEmpty) {
                              final hasSearch = searchQuery.isNotEmpty;
                              final customEmpty = hasSearch
                                  ? "No matching orders found."
                                  : widget.userId == null
                                  ? "No orders found."
                                  : "No orders for this user.";

                              return Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Text(
                                    customEmpty,
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              );
                            }

                            //scrollable list if there are results
                            return ListView.builder(
                              keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag, //when user scroll then keyboard go away
                              padding: const EdgeInsets.only(bottom: 16),
                              itemCount: filtered.length,
                              itemBuilder: (context, index) { //one row for each order
                                final d = filtered[index];
                                final data = d.data();

                                final name = (data["name"] ?? "Untitled").toString(); //if missing file show untitled
                                //status flags
                                final isActive = data["isActive"] == true;
                                final isExported = data["isExported"] == true;

                                //determine displayed status and icon of order
                                String status;
                                IconData icon;

                                //icons
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

                                final ownerLabel = (data["userName"] ?? "").toString().trim();

                                final subtitle = widget.userId == null
                                    ? (ownerLabel.isEmpty
                                    ? status
                                    : "$status • $ownerLabel")
                                    : status;

                                return ListTile(
                                  leading: Icon(icon),
                                  title: Text(name),
                                  subtitle: Text(subtitle),
                                  trailing: const Icon( //indicate navigation
                                    Icons.arrow_forward_ios,
                                    size: 16,
                                  ),
                                  onTap: () { //when is tapped then it navigates to OrderDetailsScreen to load full order details
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => OrderDetailsScreen(
                                          orderId: d.id,
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