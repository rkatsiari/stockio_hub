//shows each item inside the page view, so the user can move between items by swiping
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'item_details_screen.dart';

class ItemDetailsPagerScreen extends StatefulWidget {
  final List<String> itemIds; //all item document IDs to show
  final int initialIndex; //which item page should be opened first

  const ItemDetailsPagerScreen({
    super.key,
    required this.itemIds,
    required this.initialIndex,
  });

  @override
  State<ItemDetailsPagerScreen> createState() => _ItemDetailsPagerScreenState();
}

class _ItemDetailsPagerScreenState extends State<ItemDetailsPagerScreen> {
  //state variables
  late final PageController _pageController;
  late List<String> _itemIds;
  late int _currentIndex;

  final Map<String, GlobalKey<ItemDetailsScreenState>> _itemKeys = {};

  @override
  void initState() {
    super.initState();
    //copy the items IDs to avoids modifying the original list
    _itemIds = List<String>.from(widget.itemIds);
    _currentIndex = widget.initialIndex.clamp( //prevent invalid page numbers
      0,
      widget.itemIds.isEmpty ? 0 : widget.itemIds.length - 1,
    );
    //create the page controller
    _pageController = PageController(initialPage: _currentIndex);
  }

  //unique global key for each item ID
  GlobalKey<ItemDetailsScreenState> _keyFor(String itemId) {
    return _itemKeys.putIfAbsent(
      itemId,
          () => GlobalKey<ItemDetailsScreenState>(),
    );
  }

  Future<void> _handleMenuAction(String value) async {
    if (_itemIds.isEmpty) return;
    if (_currentIndex < 0 || _currentIndex >= _itemIds.length) return;

    final currentItemId = _itemIds[_currentIndex];
    final currentState = _itemKeys[currentItemId]?.currentState;
    if (currentState == null) return;

    switch (value) {
      case "add_stock":
        await currentState.openAddStockDialog();
        break;
      case "edit":
        await currentState.openEditDialog();
        break;
      case "move":
        await currentState.openMoveDialog();
        break;
      case "delete":
        await currentState.confirmDelete();
        break;
    }
  }

  //remove any item that no longer exist
  void _removeItem(String itemId) {
    if (!mounted) return;

    //find item in the list
    final removeIndex = _itemIds.indexOf(itemId);
    if (removeIndex == -1) return;

    setState(() {
      _itemIds.removeAt(removeIndex);
      _itemKeys.remove(itemId);

      //if there are no items in the list close the screen
      if (_itemIds.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.of(context).maybePop();
        });
        return;
      }

      //fix index
      if (_currentIndex >= _itemIds.length) {
        _currentIndex = _itemIds.length - 1;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _itemIds.isEmpty) return;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentIndex);
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_itemIds.isEmpty) {
      return const Scaffold(
        body: SizedBox.shrink(),
      );
    }

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        //prevent accessing firestore without auth
        final user = authSnap.data;
        if (user == null) {
          return const Scaffold(
            body: SizedBox.shrink(),
          );
        }

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection("users")
              .doc(user.uid)
              .snapshots(),
          builder: (context, userSnap) {
            final userData = userSnap.data?.data() ?? <String, dynamic>{};
            final role = (userData["role"] ?? "staff").toString();
            final isAdmin = role == "admin";

            return Scaffold(
              appBar: AppBar(
                backgroundColor: const Color(0xff0B1E40),
                title: const Text(
                  "Item Details",
                  style: TextStyle(color: Colors.white),
                ),
                //back button
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                actions: [
                  //only admin view
                  if (isAdmin)
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert, color: Colors.white),
                      onSelected: _handleMenuAction,
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: "add_stock",
                          child: Text("Add Stock"),
                        ),
                        PopupMenuItem(
                          value: "edit",
                          child: Text("Edit"),
                        ),
                        PopupMenuItem(
                          value: "move",
                          child: Text("Move"),
                        ),
                        PopupMenuItem(
                          value: "delete",
                          child: Text(
                            "Delete",
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              body: PageView.builder(
                controller: _pageController,
                itemCount: _itemIds.length,
                onPageChanged: (index) {
                  if (!mounted) return;
                  setState(() {
                    _currentIndex = index;
                  });
                },
                //build each page
                itemBuilder: (context, index) {
                  final itemId = _itemIds[index];

                  return ItemDetailsScreen(
                    key: _keyFor(itemId),
                    itemId: itemId,
                    onItemMissing: () => _removeItem(itemId),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}