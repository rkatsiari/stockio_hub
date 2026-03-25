//manage shops by adding remove or rename
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/tenant_context_service.dart';
import '../widgets/top_toast.dart';

class ManageShopsScreen extends StatefulWidget {
  const ManageShopsScreen({super.key});

  @override
  State<ManageShopsScreen> createState() => _ManageShopsScreenState();
}

class _ManageShopsScreenState extends State<ManageShopsScreen> {
  late final Future<String> _tenantIdFuture;

  final FirebaseAuth _auth = FirebaseAuth.instance;
  StreamSubscription<User?>? _authSub;

  bool _handledSignedOut = false;

  @override
  void initState() {
    super.initState();
    _tenantIdFuture = TenantContextService().getTenantIdOrThrow();
    _listenToAuthChanges();
  }

  void _listenToAuthChanges() {
    _authSub = _auth.authStateChanges().listen((user) {
      if (!mounted || _handledSignedOut) return;

      if (user == null) {
        _handledSignedOut = true;
        _unfocusSafely();

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final navigator = Navigator.of(context);
          if (navigator.canPop()) {
            navigator.pop();
          }
        });
      }
    });
  }

  void _unfocusSafely() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  bool _canUseContext() => mounted && !_handledSignedOut;

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  String _cleanErr(Object e) {
    return e.toString().replaceFirst("Exception: ", "").trim();
  }

  void _showSuccess(String message) {
    if (!_canUseContext()) return;
    TopToast.success(context, message);
  }

  void _showErrorToast(String message) {
    if (!_canUseContext()) return;
    TopToast.error(context, message);
  }

  CollectionReference<Map<String, dynamic>> _shopsCol(String tenantId) {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(tenantId)
        .collection("shops");
  }

  //utility function
  String _capitalizeFirst(String text) {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return cleaned;
    return cleaned[0].toUpperCase() + cleaned.substring(1);
  }

  //Prevents “Navigator.pop after dispose” and keyboard issues
  void _safeCloseDialog(BuildContext dialogContext, [dynamic result]) {
    if (!dialogContext.mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!dialogContext.mounted) return;
      final navigator = Navigator.of(dialogContext);
      if (navigator.canPop()) {
        navigator.pop(result);
      }
    });
  }

  Future<String?> _showNameDialog({
    required String title,
    required String actionText,
    String initialValue = "",
  }) async {
    if (!_canUseContext()) return null;

    _unfocusSafely();
    final ctrl = TextEditingController(text: initialValue);

    try {
      final result = await showDialog<String>(
        context: context,
        barrierDismissible: true,
        useRootNavigator: true,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(title),
            content: TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: "Shop name"),
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                final value = ctrl.text.trim();
                if (value.isEmpty) return;
                _safeCloseDialog(dialogContext, value);
              },
            ),
            actions: [
              TextButton(
                onPressed: () => _safeCloseDialog(dialogContext),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                onPressed: () {
                  final value = ctrl.text.trim();
                  if (value.isEmpty) return;
                  _safeCloseDialog(dialogContext, value);
                },
                child: Text(actionText),
              ),
            ],
          );
        },
      );

      return result?.trim();
    } finally {
      ctrl.dispose();
    }
  }

  Future<bool> _showDeleteConfirmDialog(String shopName) async {
    if (!_canUseContext()) return false;

    _unfocusSafely();

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      useRootNavigator: true,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("Delete Shop?"),
          content: Text(
            'Delete "$shopName"?\n\nExisting orders will keep the saved shopName.',
          ),
          actions: [
            TextButton(
              onPressed: () => _safeCloseDialog(dialogContext, false),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () => _safeCloseDialog(dialogContext, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
              ),
              child: const Text("Delete"),
            ),
          ],
        );
      },
    );

    return result == true;
  }

  //create shop logic
  Future<void> _createShop(String tenantId) async {
    try {
      final name = await _showNameDialog(
        title: "New Shop",
        actionText: "Create",
      );

      if (!_canUseContext()) return;
      if (name == null || name.isEmpty) return;

      await _shopsCol(tenantId).add({
        "name": _capitalizeFirst(name),
        "createdAt": FieldValue.serverTimestamp(),
        "updatedAt": FieldValue.serverTimestamp(),
      });

      if (!_canUseContext()) return;
      _showSuccess("Shop created.");
    } catch (e) {
      if (!_canUseContext()) return;
      _showErrorToast(_cleanErr(e));
    }
  }

  //edit shop logic
  Future<void> _editShop({
    required String tenantId,
    required String shopId,
    required String currentName,
  }) async {
    try {
      final newName = await _showNameDialog(
        title: "Edit Shop",
        actionText: "Save",
        initialValue: currentName,
      );

      if (!_canUseContext()) return;
      if (newName == null || newName.isEmpty) return;

      await _shopsCol(tenantId).doc(shopId).update({
        "name": _capitalizeFirst(newName),
        "updatedAt": FieldValue.serverTimestamp(),
      });

      if (!_canUseContext()) return;
      _showSuccess("Shop updated.");
    } catch (e) {
      if (!_canUseContext()) return;
      _showErrorToast(_cleanErr(e));
    }
  }

  //delete shop logic
  Future<void> _deleteShop({
    required String tenantId,
    required String shopId,
    required String shopName,
  }) async {
    try {
      final ok = await _showDeleteConfirmDialog(shopName);

      if (!_canUseContext()) return;
      if (!ok) return;

      await _shopsCol(tenantId).doc(shopId).delete();

      if (!_canUseContext()) return;
      _showSuccess("Shop deleted.");
    } catch (e) {
      if (!_canUseContext()) return;
      _showErrorToast(_cleanErr(e));
    }
  }

  PreferredSizeWidget _buildAppBar(String tenantId) {
    return AppBar(
      title: const Text(
        "Manage Shops",
        style: TextStyle(color: Colors.white),
      ),
      backgroundColor: const Color(0xff0B1E40),
      iconTheme: const IconThemeData(color: Colors.white),
      actions: [
        IconButton(
          icon: const Icon(Icons.add, color: Colors.white),
          tooltip: "Add shop",
          onPressed: () => _createShop(tenantId),
        ),
      ],
    );
  }

  //UI states
  Widget _buildErrorState(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          "No shops yet. Add one with +",
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  //shop list UI
  Widget _buildShopList(String tenantId, List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: docs.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final d = docs[index];
        final data = d.data();
        final name = (data["name"] ?? "Untitled").toString().trim().isEmpty
            ? "Untitled"
            : (data["name"] ?? "Untitled").toString();

        return ListTile(
          leading: const Icon(Icons.store),
          title: Text(name),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.edit),
                tooltip: "Edit shop",
                onPressed: () => _editShop(
                  tenantId: tenantId,
                  shopId: d.id,
                  currentName: name,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                tooltip: "Delete shop",
                onPressed: () => _deleteShop(
                  tenantId: tenantId,
                  shopId: d.id,
                  shopName: name,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      //load tenant id
      future: _tenantIdFuture,
      builder: (context, tenantSnap) {
        if (tenantSnap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (tenantSnap.hasError || !tenantSnap.hasData) {
          return Scaffold(
            appBar: AppBar(
              title: const Text(
                "Manage Shops",
                style: TextStyle(color: Colors.white),
              ),
              backgroundColor: const Color(0xff0B1E40),
              iconTheme: const IconThemeData(color: Colors.white),
            ),
            body: _buildErrorState(
              tenantSnap.hasError
                  ? _cleanErr(tenantSnap.error!)
                  : "Failed to load tenant.",
            ),
          );
        }

        final tenantId = tenantSnap.data!;

        return Scaffold(
          appBar: _buildAppBar(tenantId),
          resizeToAvoidBottomInset: true,
          body: SafeArea(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              //load shops
              stream: _shopsCol(tenantId)
                  .orderBy("createdAt", descending: false)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return _buildErrorState("Error loading shops");
                }

                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snap.data!.docs;

                if (docs.isEmpty) {
                  return _buildEmptyState();
                }

                return _buildShopList(tenantId, docs);
              },
            ),
          ),
        );
      },
    );
  }
}