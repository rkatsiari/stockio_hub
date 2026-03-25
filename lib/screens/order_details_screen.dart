import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../services/out_of_stock_service.dart';
import '../services/tenant_context_service.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/top_toast.dart';
import 'orders_screen.dart';

class _SilentReturnException implements Exception {
  const _SilentReturnException();
}

class OrderDetailsScreen extends StatefulWidget {
  final String orderId;

  const OrderDetailsScreen({
    super.key,
    required this.orderId,
  });

  @override
  State<OrderDetailsScreen> createState() => _OrderDetailsScreenState();
}

class _OrderDetailsScreenState extends State<OrderDetailsScreen> {
  late final Future<String> _tenantIdFuture;

  static const String kSizeField = "size";
  static const String kSizeStockField = "sizeStock";
  static const String kStockQuantityField = "stockQuantity";
  static const String kSizeIdDelimiter = "__";

  bool _isOffline = false;
  bool _isExportingPdf = false;
  Timer? _connectivityTimer;
  bool _isLeavingScreen = false;

  @override
  void initState() {
    super.initState();
    _tenantIdFuture = _safeGetTenantId();
    _startConnectivityPolling();
  }

  @override
  void dispose() {
    _connectivityTimer?.cancel();
    super.dispose();
  }

  void _startConnectivityPolling() {
    _checkConnectivityNow();
    _connectivityTimer = Timer.periodic(
      const Duration(seconds: 2),
          (_) => _checkConnectivityNow(),
    );
  }

  Future<void> _checkConnectivityNow() async {
    final online = await _hasInternetConnection();
    if (!mounted || _isLeavingScreen) return;

    final newOffline = !online;
    if (_isOffline != newOffline) {
      setState(() {
        _isOffline = newOffline;
      });
    }
  }

  Future<bool> _hasInternetConnection() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<String> _safeGetTenantId() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception("USER_SIGNED_OUT");
    }

    try {
      return await TenantContextService().getTenantIdOrThrow();
    } catch (e) {
      if (_isPermissionDenied(e) || _isSignedOutError(e)) {
        throw Exception("USER_SIGNED_OUT");
      }
      rethrow;
    }
  }

  bool _isSignedOutError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains("user_signed_out") ||
        s.contains("user signed out") ||
        s.contains("unauthenticated") ||
        s.contains("requires authentication");
  }

  bool _isUnavailableError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains("cloud_firestore/unavailable") ||
        msg.contains("service is currently unavailable") ||
        msg.contains("unable to resolve host") ||
        msg.contains("firestore.googleapis.com") ||
        msg.contains("status{code=unavailable") ||
        msg.contains("unknownhostexception") ||
        msg.contains("client is offline");
  }

  bool _isNetworkRequiredError(Object error) {
    final msg = error.toString().toLowerCase();
    return _isUnavailableError(error) ||
        msg.contains("failed-precondition") ||
        msg.contains("network-request-failed") ||
        msg.contains("source.server");
  }

  bool _isPermissionDenied(Object e) {
    if (e is FirebaseException) {
      return e.code == "permission-denied";
    }
    final s = e.toString().toLowerCase();
    return s.contains("permission-denied") ||
        s.contains("permission denied") ||
        s.contains("insufficient permissions");
  }

  String _cleanErr(Object e) =>
      e.toString().replaceFirst("Exception: ", "").trim();

  void _toastGreen(String msg) {
    if (!mounted || _isLeavingScreen) return;
    TopToast.success(context, msg);
  }

  void _toastRed(String msg) {
    if (!mounted || _isLeavingScreen) return;
    TopToast.error(context, msg);
  }

  void _unfocusSafely() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<bool?> _showFinishOrderDialog() {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Finish Order"),
        content: const Text("Are you sure you want to finish this order?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text("Finish"),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showCancelOrderDialog() {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Cancel Order"),
        content: const Text(
          "Are you sure you want to cancel this order?\n\nThis will delete the order and all its items.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("No"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text("Yes, delete"),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showUndoExportDialog() {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Undo Export"),
        content: const Text(
          "This will restore stock quantities back to inventory and mark this order as NOT exported. Continue?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("No"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text("Yes"),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showConfirmExportDialog() {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Confirm export"),
        content: const Text("Did you successfully share/save the PDF?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("No"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text("Yes"),
          ),
        ],
      ),
    );
  }

  Future<void> _safePopBack() async {
    if (!mounted || _isLeavingScreen) return;

    final navigator = Navigator.of(context);

    _isLeavingScreen = true;
    _unfocusSafely();
    TopToast.hide();

    await Future<void>.delayed(Duration.zero);

    if (!mounted) return;

    if (navigator.canPop()) {
      navigator.pop();
      return;
    }

    navigator.pushReplacement(
      MaterialPageRoute(builder: (_) => const OrdersScreen()),
    );
  }

  Future<void> _safeReplaceToOrders() async {
    if (!mounted || _isLeavingScreen) return;

    final navigator = Navigator.of(context);

    _isLeavingScreen = true;
    _unfocusSafely();
    TopToast.hide();

    await Future<void>.delayed(Duration.zero);

    if (!mounted) return;

    navigator.pushReplacement(
      MaterialPageRoute(builder: (_) => const OrdersScreen()),
    );
  }

  int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? "") ?? 0;
  }

  String _formatDateDdMmYyyy(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yyyy = d.year.toString();
    return "$dd/$mm/$yyyy";
  }

  CollectionReference<Map<String, dynamic>> _ordersCol(String tenantId) {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(tenantId)
        .collection("orders");
  }

  CollectionReference<Map<String, dynamic>> _productsCol(String tenantId) {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(tenantId)
        .collection("products");
  }

  DocumentReference<Map<String, dynamic>> _userRef(String uid) {
    return FirebaseFirestore.instance.collection("users").doc(uid);
  }

  DocumentReference<Map<String, dynamic>> _wholesalePriceRef({
    required String tenantId,
    required String productId,
  }) {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(tenantId)
        .collection("products")
        .doc(productId)
        .collection("prices")
        .doc("wholesale");
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _tryGetDocServerThenCache(
      DocumentReference<Map<String, dynamic>> ref,
      ) async {
    try {
      return await ref.get();
    } catch (_) {}

    try {
      return await ref.get(const GetOptions(source: Source.cache));
    } catch (_) {}

    return null;
  }

  Future<QuerySnapshot<Map<String, dynamic>>?> _tryGetQueryServerThenCache(
      Query<Map<String, dynamic>> query,
      ) async {
    try {
      return await query.get();
    } catch (_) {}

    try {
      return await query.get(const GetOptions(source: Source.cache));
    } catch (_) {}

    return null;
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> _getDocServerOnly(
      DocumentReference<Map<String, dynamic>> ref,
      ) {
    return ref.get(const GetOptions(source: Source.server));
  }

  Future<QuerySnapshot<Map<String, dynamic>>> _getQueryServerOnly(
      Query<Map<String, dynamic>> query,
      ) {
    return query.get(const GetOptions(source: Source.server));
  }

  Future<void> _requireFreshServerOrderAccess(
      DocumentReference<Map<String, dynamic>> orderRef,
      ) async {
    try {
      await orderRef.get(const GetOptions(source: Source.server));
    } catch (e) {
      if (_isPermissionDenied(e) || _isSignedOutError(e)) {
        rethrow;
      }

      if (_isUnavailableError(e) || _isNetworkRequiredError(e)) {
        throw Exception(
          "This action requires internet connection. Please reconnect and try again.",
        );
      }

      rethrow;
    }
  }

  int _getStockForItem({
    required Map<String, dynamic> productData,
    required String size,
  }) {
    final s = size.trim();
    if (s.isEmpty) {
      return _toInt(productData[kStockQuantityField] ?? 0);
    }

    final map = productData[kSizeStockField];
    if (map is Map) {
      return _toInt(map[s] ?? 0);
    }
    return 0;
  }

  String _inferSizeIfMissing({
    required String orderItemId,
    required Map<String, dynamic> itemData,
  }) {
    final stored = (itemData[kSizeField] ?? "").toString().trim();
    if (stored.isNotEmpty) return stored;

    final id = orderItemId.trim();
    final idx = id.lastIndexOf(kSizeIdDelimiter);
    if (idx > 0 && idx + kSizeIdDelimiter.length < id.length) {
      return id.substring(idx + kSizeIdDelimiter.length).trim();
    }
    return "";
  }

  bool _isStorageManagerRole(String role) => role == "storage_manager";
  bool _isStaffRole(String role) => role == "staff";

  bool _canAccessOrder({
    required String uid,
    required String role,
    required Map<String, dynamic> orderData,
  }) {
    if (role == "admin") return true;
    if (_isStorageManagerRole(role)) return true;
    return (orderData["userId"] ?? "") == uid;
  }

  bool _canEditOrder({
    required String uid,
    required String role,
    required Map<String, dynamic> orderData,
  }) {
    if (_isStorageManagerRole(role)) return false;
    if (role == "admin") return true;
    return (orderData["userId"] ?? "") == uid;
  }

  bool _canExportOrder({
    required String uid,
    required String role,
    required Map<String, dynamic> orderData,
  }) {
    if (!_canEditOrder(uid: uid, role: role, orderData: orderData)) {
      return false;
    }
    return !(_isStaffRole(role) || role == "reseller");
  }

  bool _canUndoExport({
    required String uid,
    required String role,
    required Map<String, dynamic> orderData,
  }) {
    if (!_canEditOrder(uid: uid, role: role, orderData: orderData)) {
      return false;
    }
    return !(_isStaffRole(role) || role == "reseller");
  }

  bool _canDeleteOrder({
    required String uid,
    required String role,
    required Map<String, dynamic> orderData,
  }) {
    return _canEditOrder(uid: uid, role: role, orderData: orderData);
  }

  static FolderNode _buildTree(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
      ) {
    final root = FolderNode("(root)");

    for (final d in docs) {
      final data = d.data();
      final List<String> path = (data["folderPathNames"] as List?)
          ?.map((e) => e.toString())
          .toList() ??
          [];

      final cleanPath = path.where((p) => p.trim().isNotEmpty).toList();

      FolderNode current = root;
      for (final part in cleanPath) {
        current = current.children.putIfAbsent(part, () => FolderNode(part));
      }

      current.items.add({
        "orderItemId": d.id,
        "productId": (data["productId"] ?? "").toString(),
        "code": (data["code"] ?? "").toString(),
        "size": (data["size"] ?? "").toString(),
        "qty": (data["qty"] ?? 0),
        "wholesalePrice":
        data["wholesalePrice"] ?? data["wholesale"] ?? data["priceWholesale"],
        "folderPathNames": (data["folderPathNames"] ?? []),
      });
    }

    return root;
  }

  static FolderNode _buildTreeFromMaps(List<Map<String, dynamic>> docs) {
    final root = FolderNode("(root)");

    for (final data in docs) {
      final List<String> path = (data["folderPathNames"] as List?)
          ?.map((e) => e.toString())
          .toList() ??
          [];

      final cleanPath = path.where((p) => p.trim().isNotEmpty).toList();

      FolderNode current = root;
      for (final part in cleanPath) {
        current = current.children.putIfAbsent(part, () => FolderNode(part));
      }

      current.items.add({
        "orderItemId": (data["orderItemId"] ?? "").toString(),
        "productId": (data["productId"] ?? "").toString(),
        "code": (data["code"] ?? "").toString(),
        "size": (data["size"] ?? "").toString(),
        "qty": (data["qty"] ?? 0),
        "wholesalePrice": data["wholesalePrice"],
        "folderPathNames": (data["folderPathNames"] ?? []),
      });
    }

    return root;
  }

  List<_ScreenSection> _buildScreenSections(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> itemDocs,
      ) {
    final tree = _buildTree(itemDocs);
    final List<_ScreenSection> sections = [];

    void collectSections(FolderNode node, {required int depth}) {
      final children = node.children.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      for (final c in children) {
        if (c.items.isNotEmpty) {
          final rows = <Map<String, dynamic>>[];
          String previousCode = "";

          for (int i = 0; i < c.items.length; i++) {
            final it = c.items[i];
            final code = (it["code"] ?? "").toString();

            rows.add({
              ...it,
              "showFolder": i == 0,
              "showCode": i == 0 || code != previousCode,
              "folder": c.name,
              "isMainFolder": depth == 0,
            });

            previousCode = code;
          }

          sections.add(
            _ScreenSection(
              title: c.name,
              depth: depth,
              rows: rows,
            ),
          );
        }

        collectSections(c, depth: depth + 1);
      }
    }

    collectSections(tree, depth: 0);
    return sections;
  }

  Future<void> _validateStockBeforeExport({
    required String tenantId,
    required String uid,
    required String role,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> itemDocs,
  }) async {
    final orderSnap =
    await _getDocServerOnly(_ordersCol(tenantId).doc(widget.orderId));
    final orderData = orderSnap.data() ?? <String, dynamic>{};

    if (!_canExportOrder(uid: uid, role: role, orderData: orderData)) {
      throw const _SilentReturnException();
    }

    if (orderData["isExported"] == true) {
      throw Exception("This order is already exported.");
    }

    for (final doc in itemDocs) {
      final data = doc.data();
      final productId = (data["productId"] ?? "").toString().trim();
      final qty = _toInt(data["qty"] ?? 0);

      if (productId.isEmpty || qty <= 0) continue;

      final orderItemId = doc.id;
      final size =
      _inferSizeIfMissing(orderItemId: orderItemId, itemData: data);

      final productSnap =
      await _getDocServerOnly(_productsCol(tenantId).doc(productId));

      if (!productSnap.exists) {
        throw Exception('Product missing: ${data["code"] ?? productId}');
      }

      final productData = productSnap.data() ?? <String, dynamic>{};
      final stock = _getStockForItem(productData: productData, size: size);

      if (stock < qty) {
        final code = (data["code"] ?? productId).toString();
        final sizeLabel = size.isEmpty ? "" : " ($size)";
        throw Exception(
          'Not enough stock for "$code"$sizeLabel. Available: $stock',
        );
      }
    }
  }

  Future<void> _continueOrder(String tenantId, String uid, String role) async {
    try {
      final thisRef = _ordersCol(tenantId).doc(widget.orderId);
      final thisSnap = await _tryGetDocServerThenCache(thisRef);

      if (thisSnap == null || !thisSnap.exists) {
        throw Exception("Order not found.");
      }

      final data = thisSnap.data() ?? <String, dynamic>{};

      if (!_canEditOrder(uid: uid, role: role, orderData: data)) {
        throw const _SilentReturnException();
      }

      final isExported = data["isExported"] == true;
      final isActive = data["isActive"] == true;
      final orderOwnerId = (data["userId"] ?? "").toString().trim();

      if (isExported) {
        throw Exception("Exported orders cannot be continued.");
      }

      if (isActive) return;

      if (orderOwnerId.isNotEmpty) {
        final activeSnap = await _tryGetQueryServerThenCache(
          _ordersCol(tenantId)
              .where("userId", isEqualTo: orderOwnerId)
              .where("isActive", isEqualTo: true),
        );

        final batch = FirebaseFirestore.instance.batch();

        for (final doc in activeSnap?.docs ?? []) {
          if (doc.id != widget.orderId) {
            batch.update(doc.reference, {"isActive": false});
          }
        }

        batch.update(thisRef, {
          "isActive": true,
          "reactivatedAt": FieldValue.serverTimestamp(),
          "closedAt": FieldValue.delete(),
        });

        await batch.commit();
      } else {
        await thisRef.update({
          "isActive": true,
          "reactivatedAt": FieldValue.serverTimestamp(),
          "closedAt": FieldValue.delete(),
        });
      }

      _toastGreen("Order continued.");
    } catch (e) {
      if (e is _SilentReturnException) return;
      if (_isPermissionDenied(e)) return;
      _toastRed(_cleanErr(e));
    }
  }

  Future<void> _finalizeOrder(String tenantId, String uid, String role) async {
    if (!mounted || _isLeavingScreen) return;

    _unfocusSafely();

    final confirm = await _showFinishOrderDialog();
    if (confirm != true) return;

    try {
      final orderRef = _ordersCol(tenantId).doc(widget.orderId);
      final itemsRef = orderRef.collection("items");

      final orderSnap = await _tryGetDocServerThenCache(orderRef);
      final data = orderSnap?.data() ?? <String, dynamic>{};

      if (!_canEditOrder(uid: uid, role: role, orderData: data)) return;
      if (data["isExported"] == true) return;
      if (data["isActive"] != true) return;

      final itemsSnap = await _tryGetQueryServerThenCache(itemsRef);

      if ((itemsSnap?.docs ?? []).isEmpty) {
        await orderRef.delete();

        _toastGreen("Empty order deleted.");

        if (!mounted) return;
        await _safeReplaceToOrders();
        return;
      }

      await orderRef.update({
        "isActive": false,
        "closedAt": FieldValue.serverTimestamp(),
      });

      _toastGreen("Order finished.");
    } catch (e) {
      if (_isPermissionDenied(e)) return;
      _toastRed("Failed to finish: ${_cleanErr(e)}");
    }
  }

  Future<void> _cancelAndDeleteOrder(
      String tenantId,
      String uid,
      String role,
      ) async {
    try {
      final orderSnap =
      await _tryGetDocServerThenCache(_ordersCol(tenantId).doc(widget.orderId));
      final orderData = orderSnap?.data() ?? <String, dynamic>{};

      if (!_canDeleteOrder(uid: uid, role: role, orderData: orderData)) return;

      if (orderData["isExported"] == true) {
        _toastRed("Cannot cancel an exported order.");
        return;
      }

      if (orderData["isActive"] != true) {
        _toastRed("Continue the order before deleting it.");
        return;
      }

      if (!mounted || _isLeavingScreen) return;

      _unfocusSafely();

      final confirm = await _showCancelOrderDialog();
      if (confirm != true) return;

      final fs = FirebaseFirestore.instance;
      final itemsSnap = await _tryGetQueryServerThenCache(
        _ordersCol(tenantId).doc(widget.orderId).collection("items"),
      );

      final batch = fs.batch();
      for (final doc in itemsSnap?.docs ?? []) {
        batch.delete(doc.reference);
      }
      batch.delete(_ordersCol(tenantId).doc(widget.orderId));

      await batch.commit();

      _toastGreen("Order deleted.");

      if (!mounted) return;
      await _safeReplaceToOrders();
    } catch (e) {
      if (_isPermissionDenied(e)) return;
      _toastRed("Failed to delete: ${_cleanErr(e)}");
    }
  }

  Future<void> _undoExport(String tenantId, String uid, String role) async {
    final preSnap =
    await _tryGetDocServerThenCache(_ordersCol(tenantId).doc(widget.orderId));
    final preData = preSnap?.data() ?? <String, dynamic>{};

    if (!_canUndoExport(uid: uid, role: role, orderData: preData)) {
      return;
    }

    if (!mounted || _isLeavingScreen) return;

    _unfocusSafely();

    final confirm = await _showUndoExportDialog();
    if (confirm != true) return;

    try {
      final orderRef = _ordersCol(tenantId).doc(widget.orderId);
      await _requireFreshServerOrderAccess(orderRef);

      final fs = FirebaseFirestore.instance;
      final itemsSnap = await _getQueryServerOnly(orderRef.collection("items"));

      if (itemsSnap.docs.isEmpty) {
        _toastRed("No items found for this order.");
        return;
      }

      final orderSnap = await _getDocServerOnly(orderRef);

      if (!orderSnap.exists) {
        throw Exception("Order not found.");
      }

      final orderData = orderSnap.data() ?? <String, dynamic>{};

      if (!_canUndoExport(uid: uid, role: role, orderData: orderData)) {
        throw const _SilentReturnException();
      }

      if (orderData["isExported"] != true) {
        throw Exception("This order is not exported.");
      }

      final batch = fs.batch();
      final year = DateTime.now().year;

      for (final doc in itemsSnap.docs) {
        final data = doc.data();
        final productId = (data["productId"] ?? "").toString().trim();
        final qty = _toInt(data["qty"] ?? 0);

        if (productId.isEmpty || qty <= 0) continue;

        final orderItemId = doc.id;
        final size =
        _inferSizeIfMissing(orderItemId: orderItemId, itemData: data);

        final productRef = _productsCol(tenantId).doc(productId);

        if (size.isNotEmpty) {
          batch.update(productRef, {
            "$kSizeStockField.$size": FieldValue.increment(qty),
            kStockQuantityField: FieldValue.increment(qty),
          });
        } else {
          batch.update(productRef, {
            kStockQuantityField: FieldValue.increment(qty),
          });
        }

        final moveRef = productRef.collection("stock_movements").doc();
        batch.set(moveRef, {
          "type": "Undo sale",
          "delta": qty,
          if (size.isNotEmpty) "sizeDelta": {size: qty},
          "at": FieldValue.serverTimestamp(),
          "by": uid,
          "year": year,
          "orderId": widget.orderId,
        });
      }

      batch.update(orderRef, {
        "isExported": false,
        "undoExportedAt": FieldValue.serverTimestamp(),
        "exportedAt": FieldValue.delete(),
        "exportedFilePath": FieldValue.delete(),
        "exportMethod": FieldValue.delete(),
        "isActive": false,
      });

      await batch.commit();

      final productIds = <String>{};
      for (final doc in itemsSnap.docs) {
        final data = doc.data();
        final productId = (data["productId"] ?? "").toString().trim();
        if (productId.isNotEmpty) {
          productIds.add(productId);
        }
      }

      final outOfStockService = OutOfStockService();
      for (final productId in productIds) {
        await outOfStockService.syncProductFolderWithStock(
          tenantId: tenantId,
          productId: productId,
        );
      }

      _toastGreen("Export undone. Stock restored.");
    } catch (e) {
      if (e is _SilentReturnException) return;
      if (_isPermissionDenied(e)) return;

      if (_isNetworkRequiredError(e) || _isUnavailableError(e)) {
        _toastRed(
          "Undo export requires internet so inventory is restored safely on the server.",
        );
        return;
      }

      _toastRed(_cleanErr(e));
    }
  }

  Future<void> _exportPdf({
    required String tenantId,
    required String uid,
    required String role,
    required bool share,
  }) async {
    if (_isExportingPdf) return;

    setState(() {
      _isExportingPdf = true;
    });

    try {
      final orderRef = _ordersCol(tenantId).doc(widget.orderId);
      await _requireFreshServerOrderAccess(orderRef);

      final fs = FirebaseFirestore.instance;
      final orderSnap = await _getDocServerOnly(orderRef);
      final orderData = orderSnap.data() ?? <String, dynamic>{};

      if (!_canExportOrder(uid: uid, role: role, orderData: orderData)) return;

      if (orderData["isExported"] == true) {
        _toastRed("This order is already exported.");
        return;
      }

      final regularFontData =
      await rootBundle.load("assets/fonts/NotoSans-Regular.ttf");
      final boldFontData =
      await rootBundle.load("assets/fonts/NotoSans-Bold.ttf");

      final fontRegular = pw.Font.ttf(regularFontData);
      final fontBold = pw.Font.ttf(boldFontData);

      final baseText = pw.TextStyle(
        font: fontRegular,
        fontSize: 10,
        lineSpacing: 0,
      );

      final boldText = pw.TextStyle(
        font: fontBold,
        fontSize: 10,
        lineSpacing: 0,
      );

      final orderName = (orderData["name"] ?? "Order").toString();

      final itemsSnap = await _getQueryServerOnly(
        orderRef.collection("items").orderBy("addedAt", descending: false),
      );

      if (itemsSnap.docs.isEmpty) {
        _toastRed("No items to export.");
        return;
      }

      await _validateStockBeforeExport(
        tenantId: tenantId,
        uid: uid,
        role: role,
        itemDocs: itemsSnap.docs,
      );

      final enrichedItems = <Map<String, dynamic>>[];
      final wholesaleCache = <String, dynamic>{};

      for (final doc in itemsSnap.docs) {
        final data = Map<String, dynamic>.from(doc.data());
        data["orderItemId"] = doc.id;

        final productId = (data["productId"] ?? "").toString().trim();

        if (productId.isNotEmpty) {
          if (!wholesaleCache.containsKey(productId)) {
            try {
              final wholesaleSnap = await _getDocServerOnly(
                _wholesalePriceRef(tenantId: tenantId, productId: productId),
              );
              final wholesaleData = wholesaleSnap.data() ?? <String, dynamic>{};
              wholesaleCache[productId] = wholesaleData["wholesalePrice"];
            } catch (_) {
              wholesaleCache[productId] = null;
            }
          }

          data["wholesalePrice"] = wholesaleCache[productId];
        }

        enrichedItems.add(data);
      }

      final tree = _buildTreeFromMaps(enrichedItems);
      final List<_PdfSection> sections = [];

      void collectSections(FolderNode node, {required int depth}) {
        final children = node.children.values.toList()
          ..sort((a, b) => a.name.compareTo(b.name));

        for (final c in children) {
          if (c.items.isNotEmpty) {
            final rows = <_PdfRow>[];
            String previousCode = "";

            for (int i = 0; i < c.items.length; i++) {
              final it = c.items[i];
              final code = (it["code"] ?? "").toString();

              rows.add(
                _PdfRow(
                  folder: c.name,
                  code: code,
                  qtyWithSize: _formatQtyWithSize(
                    (it["qty"] ?? 0),
                    (it["size"] ?? "").toString(),
                  ),
                  wholesalePrice: _formatWholesalePrice(it["wholesalePrice"]),
                  showFolder: i == 0,
                  showCode: i == 0 || code != previousCode,
                  isMainFolder: depth == 0,
                ),
              );

              previousCode = code;
            }

            sections.add(
              _PdfSection(
                title: c.name,
                items: rows,
                depth: depth,
              ),
            );
          }

          collectSections(c, depth: depth + 1);
        }
      }

      collectSections(tree, depth: 0);

      pw.Widget sectionBlock(_PdfSectionPart part) {
        final indent = part.depth * 10.0;

        return pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 8),
          padding: pw.EdgeInsets.only(left: indent),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              ...part.rows.map(
                    (r) => pw.Container(
                  padding: const pw.EdgeInsets.symmetric(vertical: 4),
                  decoration: const pw.BoxDecoration(
                    border: pw.Border(
                      bottom: pw.BorderSide(
                        color: PdfColors.blueGrey100,
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.center,
                    children: [
                      pw.Expanded(
                        flex: 4,
                        child: pw.Text(
                          r.showFolder ? r.folder : "",
                          style: r.showFolder
                              ? (r.isMainFolder ? boldText : baseText)
                              : baseText,
                        ),
                      ),
                      pw.SizedBox(width: 8),
                      pw.Expanded(
                        flex: 3,
                        child: pw.Text(
                          r.showCode ? r.code : "",
                          style: baseText,
                        ),
                      ),
                      pw.SizedBox(width: 8),
                      pw.Expanded(
                        flex: 2,
                        child: pw.Text(
                          r.qtyWithSize,
                          style: baseText,
                        ),
                      ),
                      pw.SizedBox(width: 8),
                      pw.Expanded(
                        flex: 3,
                        child: pw.Text(
                          r.wholesalePrice,
                          style: baseText,
                          textAlign: pw.TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }

      const pageMargin = 24.0;
      const headerBlockH = 32.0;
      const cardBaseH = 4.0;
      const rowH = 14.0;
      const cardGapH = 8.0;

      const pageFormat = PdfPageFormat.a4;
      final usablePageH = pageFormat.height - (pageMargin * 2) - headerBlockH;
      final usableColumnH = usablePageH;

      int maxRowsPerFreshCard() {
        final free = usableColumnH - cardBaseH;
        final rowsFit = (free / rowH).floor();
        return rowsFit < 1 ? 1 : rowsFit;
      }

      double estimatePartH(_PdfSectionPart p) {
        return cardBaseH + (p.rows.length * rowH) + cardGapH;
      }

      final List<_PdfSectionPart> parts = [];
      final maxRows = maxRowsPerFreshCard();

      for (final s in sections) {
        final totalParts = (s.items.length / maxRows).ceil().clamp(1, 999999);
        int partIndex = 1;
        int i = 0;

        while (i < s.items.length) {
          final remaining = s.items.length - i;
          final take = remaining > maxRows ? maxRows : remaining;
          final originalChunk = s.items.sublist(i, i + take);

          final chunk = <_PdfRow>[];
          String previousCodeInChunk = "";

          for (int j = 0; j < originalChunk.length; j++) {
            final row = originalChunk[j];
            chunk.add(
              _PdfRow(
                folder: row.folder,
                code: row.code,
                qtyWithSize: row.qtyWithSize,
                wholesalePrice: row.wholesalePrice,
                showFolder: j == 0,
                showCode: j == 0 || row.code != previousCodeInChunk,
                isMainFolder: row.isMainFolder,
              ),
            );
            previousCodeInChunk = row.code;
          }

          parts.add(
            _PdfSectionPart(
              title: s.title,
              rows: chunk,
              partIndex: partIndex,
              totalParts: totalParts,
              depth: s.depth,
            ),
          );

          i += take;
          partIndex++;
        }
      }

      final List<_PdfPage> pages = [];
      _PdfPage current = _PdfPage();
      double leftH = 0;
      double rightH = 0;

      for (final part in parts) {
        final h = estimatePartH(part);

        if (leftH + h <= usableColumnH || current.left.isEmpty) {
          current.left.add(part);
          leftH += h;
          continue;
        }

        if (rightH + h <= usableColumnH || current.right.isEmpty) {
          current.right.add(part);
          rightH += h;
          continue;
        }

        pages.add(current);
        current = _PdfPage();
        leftH = 0;
        rightH = 0;
        current.left.add(part);
        leftH += h;
      }

      if (current.left.isNotEmpty || current.right.isNotEmpty) {
        pages.add(current);
      }

      final pdf = pw.Document();
      final formattedDate = _formatDateDdMmYyyy(DateTime.now());

      pw.Widget columnHeader() {
        return pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 8),
          child: pw.Column(
            children: [
              pw.Row(
                children: [
                  pw.Expanded(
                    flex: 4,
                    child: pw.Text("Folder", style: boldText),
                  ),
                  pw.SizedBox(width: 8),
                  pw.Expanded(
                    flex: 3,
                    child: pw.Text("Code", style: boldText),
                  ),
                  pw.SizedBox(width: 8),
                  pw.Expanded(
                    flex: 2,
                    child: pw.Text("Qty", style: boldText),
                  ),
                  pw.SizedBox(width: 8),
                  pw.Expanded(
                    flex: 3,
                    child: pw.Text(
                      "Wholesale",
                      style: boldText,
                      textAlign: pw.TextAlign.right,
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 4),
              pw.Divider(thickness: 1),
            ],
          ),
        );
      }

      for (final page in pages) {
        pdf.addPage(
          pw.Page(
            pageFormat: pageFormat,
            margin: const pw.EdgeInsets.all(pageMargin),
            build: (_) {
              return pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        orderName,
                        style: pw.TextStyle(font: fontBold, fontSize: 18),
                      ),
                      pw.Text(
                        formattedDate,
                        style: pw.TextStyle(font: fontRegular, fontSize: 10),
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 12),
                  pw.Expanded(
                    child: pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Expanded(
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              columnHeader(),
                              ...page.left.map(sectionBlock),
                            ],
                          ),
                        ),
                        pw.SizedBox(width: 16),
                        pw.Expanded(
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              columnHeader(),
                              ...page.right.map(sectionBlock),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      }

      final docsDir = await getApplicationDocumentsDirectory();
      final safeName = orderName.replaceAll(RegExp(r"[^\w\s-]"), "").trim();
      final fileName =
      (safeName.isEmpty ? "order" : safeName).replaceAll(" ", "_");
      final file = File("${docsDir.path}/$fileName.pdf");
      await file.writeAsBytes(await pdf.save());

      bool shouldMarkExported = true;

      if (share) {
        await Share.shareXFiles([XFile(file.path)], text: "Order: $orderName");

        if (!mounted || _isLeavingScreen) return;
        _unfocusSafely();

        final confirmed = await _showConfirmExportDialog();
        shouldMarkExported = confirmed == true;
      }

      if (!shouldMarkExported) {
        _toastRed("Export canceled. Order not sent.");
        return;
      }

      final freshOrderSnap = await _getDocServerOnly(orderRef);
      final freshOrderData = freshOrderSnap.data() ?? <String, dynamic>{};

      if (!_canExportOrder(uid: uid, role: role, orderData: freshOrderData)) {
        throw const _SilentReturnException();
      }

      if (freshOrderData["isExported"] == true) {
        throw Exception("This order is already exported.");
      }

      final batch = fs.batch();
      final year = DateTime.now().year;
      final productIds = <String>{};

      for (final doc in itemsSnap.docs) {
        final data = doc.data();
        final productId = (data["productId"] ?? "").toString().trim();
        final qty = _toInt(data["qty"] ?? 0);

        if (productId.isEmpty || qty <= 0) continue;

        final orderItemId = doc.id;
        final size =
        _inferSizeIfMissing(orderItemId: orderItemId, itemData: data);

        final productRef = _productsCol(tenantId).doc(productId);
        productIds.add(productId);

        if (size.isNotEmpty) {
          batch.update(productRef, {
            "$kSizeStockField.$size": FieldValue.increment(-qty),
            kStockQuantityField: FieldValue.increment(-qty),
          });
        } else {
          batch.update(productRef, {
            kStockQuantityField: FieldValue.increment(-qty),
          });
        }

        final moveRef = productRef.collection("stock_movements").doc();
        batch.set(moveRef, {
          "type": "sale",
          "delta": -qty,
          if (size.isNotEmpty) "sizeDelta": {size: -qty},
          "at": FieldValue.serverTimestamp(),
          "by": uid,
          "year": year,
          "orderId": widget.orderId,
        });
      }

      batch.update(orderRef, {
        "isExported": true,
        "exportedAt": FieldValue.serverTimestamp(),
        "isActive": false,
        "exportedFilePath": file.path,
        "exportMethod": share ? "share_confirmed" : "saved_to_documents",
      });

      await batch.commit();

      final outOfStockService = OutOfStockService();
      for (final productId in productIds) {
        await outOfStockService.syncProductFolderWithStock(
          tenantId: tenantId,
          productId: productId,
        );
      }

      _toastGreen("Exported successfully.");
    } catch (e) {
      if (e is _SilentReturnException) return;
      if (_isPermissionDenied(e)) return;

      if (_isNetworkRequiredError(e) || _isUnavailableError(e)) {
        _toastRed(
          "Export requires internet so stock can be verified against the latest server data.",
        );
        return;
      }

      _toastRed(_cleanErr(e));
    } finally {
      if (mounted) {
        setState(() {
          _isExportingPdf = false;
        });
      } else {
        _isExportingPdf = false;
      }
    }
  }

  Future<void> _changeQty({
    required String tenantId,
    required String uid,
    required String role,
    required String orderItemId,
    required String productId,
    required String size,
    required int currentQty,
    required int delta,
  }) async {
    if (delta == 0) return;

    final orderRef = _ordersCol(tenantId).doc(widget.orderId);
    final orderItemRef = orderRef.collection("items").doc(orderItemId);

    try {
      final orderSnap = await _tryGetDocServerThenCache(orderRef);
      if (orderSnap == null || !orderSnap.exists) {
        throw Exception("Order not found.");
      }

      final orderData = orderSnap.data() ?? <String, dynamic>{};
      if (!_canEditOrder(uid: uid, role: role, orderData: orderData)) {
        throw const _SilentReturnException();
      }

      final isExported = orderData["isExported"] == true;
      final isActive = orderData["isActive"] == true;

      if (isExported || !isActive) {
        throw const _SilentReturnException();
      }

      final orderItemSnap = await _tryGetDocServerThenCache(orderItemRef);
      final existingQty = (orderItemSnap?.exists ?? false)
          ? _toInt((orderItemSnap!.data() ?? <String, dynamic>{})["qty"] ?? 0)
          : currentQty;

      final newQty = existingQty + delta;
      if (newQty < 0) throw Exception("Quantity can't be negative.");

      if (delta > 0) {
        final productSnap =
        await _tryGetDocServerThenCache(_productsCol(tenantId).doc(productId));
        if (productSnap == null || !productSnap.exists) {
          throw Exception("Product not found.");
        }

        final prodData = productSnap.data() ?? <String, dynamic>{};
        final availableStock =
        _getStockForItem(productData: prodData, size: size);

        if (newQty > availableStock) {
          throw Exception("Not enough stock. Available: $availableStock");
        }
      }

      if (newQty == 0) {
        await orderItemRef.delete();
      } else {
        await orderItemRef.set({"qty": newQty}, SetOptions(merge: true));
      }
    } catch (e) {
      if (e is _SilentReturnException) return;
      if (_isPermissionDenied(e)) return;
      _toastRed(_cleanErr(e));
    }
  }

  Future<void> _removeItem({
    required String tenantId,
    required String uid,
    required String role,
    required String orderItemId,
  }) async {
    final orderRef = _ordersCol(tenantId).doc(widget.orderId);
    final orderItemRef = orderRef.collection("items").doc(orderItemId);

    try {
      final orderSnap = await _tryGetDocServerThenCache(orderRef);
      final orderData = orderSnap?.data() ?? <String, dynamic>{};

      if (!_canEditOrder(uid: uid, role: role, orderData: orderData)) return;
      if (orderData["isExported"] == true || orderData["isActive"] != true) {
        return;
      }

      await orderItemRef.delete();
    } catch (e) {
      if (_isPermissionDenied(e)) return;
      _toastRed(_cleanErr(e));
    }
  }

  static String _formatQtyWithSize(dynamic qty, String size) {
    final q = (qty is num) ? qty.toInt() : int.tryParse(qty.toString()) ?? 0;
    final s = size.trim();
    return s.isEmpty ? q.toString() : "$s $q";
  }

  static String _formatWholesalePrice(dynamic value) {
    if (value == null) return "-";

    final num? n = value is num ? value : num.tryParse(value.toString());
    if (n == null) return "-";

    return n.toStringAsFixed(2);
  }

  Widget _buildSignedOutScaffold() {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xff0B1E40),
        title: const Text("Order", style: TextStyle(color: Colors.white)),
      ),
      body: const Center(child: Text("Not signed in.")),
      bottomNavigationBar: const BottomNav(
        currentIndex: 2,
        hasFab: false,
        isRootScreen: false,
      ),
    );
  }

  Widget _buildLoadingScaffold() {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
      bottomNavigationBar: BottomNav(
        currentIndex: 2,
        hasFab: false,
        isRootScreen: false,
      ),
    );
  }

  Widget _buildErrorScaffold(String message) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xff0B1E40),
        title: const Text("Order", style: TextStyle(color: Colors.white)),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(message, textAlign: TextAlign.center),
        ),
      ),
      bottomNavigationBar: const BottomNav(
        currentIndex: 2,
        hasFab: false,
        isRootScreen: false,
      ),
    );
  }

  Widget _buildOfflineBanner({
    required bool isOffline,
    required bool fromCache,
    required bool hasPendingWrites,
  }) {
    if (!isOffline) {
      return const SizedBox.shrink();
    }

    if (!fromCache && !hasPendingWrites) {
      return const SizedBox.shrink();
    }

    final text = hasPendingWrites
        ? "Offline changes pending sync. Export and undo export are temporarily disabled."
        : "Showing cached data. Export and undo export require internet and fresh server data.";

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        border: Border.all(color: Colors.amber.shade200),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.orange.shade900,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _screenTableHeader({required bool canEdit}) {
    return Column(
      children: [
        Row(
          children: [
            const Expanded(
              flex: 4,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Folder",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              flex: 3,
              child: Center(
                child: Text(
                  "Code",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              flex: 4,
              child: Center(
                child: Text(
                  "Qty",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            if (canEdit) const SizedBox(width: 40),
          ],
        ),
        const SizedBox(height: 6),
        Divider(
          height: 1,
          thickness: 0.8,
          color: Colors.blueGrey.shade300,
        ),
      ],
    );
  }

  Widget _qtyEditor({
    required String tenantId,
    required String uid,
    required String role,
    required String orderItemId,
    required String productId,
    required String size,
    required int currentQty,
    required bool canEdit,
  }) {
    final cleanSize = size.trim();

    if (!canEdit) {
      return Center(
        child: Text(
          cleanSize.isEmpty ? "$currentQty" : "$cleanSize $currentQty",
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    final minusDisabled = currentQty <= 0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 24,
          height: 24,
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            iconSize: 16,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: minusDisabled
                ? null
                : () => _changeQty(
              tenantId: tenantId,
              uid: uid,
              role: role,
              orderItemId: orderItemId,
              productId: productId,
              size: size,
              currentQty: currentQty,
              delta: -1,
            ),
          ),
        ),
        const SizedBox(width: 6),
        if (cleanSize.isNotEmpty) ...[
          Text(
            cleanSize,
            style: const TextStyle(fontSize: 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(width: 6),
        ],
        SizedBox(
          width: 18,
          child: Text(
            currentQty.toString(),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 24,
          height: 24,
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            iconSize: 16,
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => _changeQty(
              tenantId: tenantId,
              uid: uid,
              role: role,
              orderItemId: orderItemId,
              productId: productId,
              size: size,
              currentQty: currentQty,
              delta: 1,
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionRow({
    required Map<String, dynamic> row,
    required int depth,
    required String tenantId,
    required String uid,
    required String role,
    required bool canEdit,
  }) {
    final code = (row["code"] ?? "").toString();
    final folder = (row["folder"] ?? "").toString();
    final orderItemId = (row["orderItemId"] ?? "").toString();
    final productId = (row["productId"] ?? "").toString();
    final currentQty = _toInt(row["qty"] ?? 0);
    final size = _inferSizeIfMissing(orderItemId: orderItemId, itemData: row);
    final showFolder = row["showFolder"] == true;
    final showCode = row["showCode"] == true;
    final isMainFolder = row["isMainFolder"] == true;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Colors.blueGrey.shade100,
            width: 0.8,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Padding(
              padding: EdgeInsets.only(left: depth * 14.0),
              child: Text(
                showFolder ? folder : "",
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: showFolder && isMainFolder
                      ? FontWeight.bold
                      : FontWeight.w500,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: Text(
              showCode ? code : "",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 4,
            child: Align(
              alignment: Alignment.center,
              child: _qtyEditor(
                tenantId: tenantId,
                uid: uid,
                role: role,
                orderItemId: orderItemId,
                productId: productId,
                size: size,
                currentQty: currentQty,
                canEdit: canEdit,
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: canEdit
                ? IconButton(
              padding: EdgeInsets.zero,
              iconSize: 18,
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () => _removeItem(
                tenantId: tenantId,
                uid: uid,
                role: role,
                orderItemId: orderItemId,
              ),
            )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required _ScreenSection section,
    required String tenantId,
    required String uid,
    required String role,
    required bool canEdit,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: section.rows
            .map(
              (row) => _sectionRow(
            row: row,
            depth: section.depth,
            tenantId: tenantId,
            uid: uid,
            role: role,
            canEdit: canEdit,
          ),
        )
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return _buildSignedOutScaffold();
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (_, __) async {
        await _safePopBack();
      },
      child: FutureBuilder<String>(
        future: _tenantIdFuture,
        builder: (context, tenantSnap) {
          if (tenantSnap.connectionState == ConnectionState.waiting) {
            return _buildLoadingScaffold();
          }

          if (tenantSnap.hasError || !tenantSnap.hasData) {
            final err = tenantSnap.error;
            if (err != null &&
                (_isPermissionDenied(err) || _isSignedOutError(err))) {
              return _buildSignedOutScaffold();
            }
            return _buildErrorScaffold(
              err == null ? "Failed to load tenant." : _cleanErr(err),
            );
          }

          final tenantId = tenantSnap.data!;
          final orderRef = _ordersCol(tenantId).doc(widget.orderId);

          return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: _userRef(uid).snapshots(),
            builder: (context, userSnap) {
              if (userSnap.hasError) {
                final err = userSnap.error!;
                if (_isPermissionDenied(err) || _isSignedOutError(err)) {
                  return _buildSignedOutScaffold();
                }
                return _buildErrorScaffold(_cleanErr(err));
              }

              if (!userSnap.hasData) {
                return _buildLoadingScaffold();
              }

              final userData = userSnap.data!.data() ?? <String, dynamic>{};
              final role = (userData["role"] ?? "staff").toString();

              return Scaffold(
                extendBody: true,
                appBar: PreferredSize(
                  preferredSize: const Size.fromHeight(kToolbarHeight),
                  child: _OrderAppBar(
                    orderStream: orderRef.snapshots(includeMetadataChanges: true),
                    uid: uid,
                    role: role,
                    canAccessOrder: _canAccessOrder,
                    canEditOrder: _canEditOrder,
                    canExportOrder: _canExportOrder,
                    canUndoExport: _canUndoExport,
                    isStorageManagerRole: _isStorageManagerRole,
                    isOffline: _isOffline,
                    isExportingPdf: _isExportingPdf,
                    onBack: _safePopBack,
                    onContinue: () => _continueOrder(tenantId, uid, role),
                    onDelete: () => _cancelAndDeleteOrder(tenantId, uid, role),
                    onFinish: () => _finalizeOrder(tenantId, uid, role),
                    onExport: () => _exportPdf(
                      tenantId: tenantId,
                      uid: uid,
                      role: role,
                      share: true,
                    ),
                    onUndoExport: () => _undoExport(tenantId, uid, role),
                    onReconnectExportBlocked: () => _toastRed(
                      "Reconnect to export with fresh server data.",
                    ),
                    onReconnectUndoBlocked: () => _toastRed(
                      "Reconnect to undo export safely.",
                    ),
                    cleanErr: _cleanErr,
                    isPermissionDenied: _isPermissionDenied,
                    isSignedOutError: _isSignedOutError,
                  ),
                ),
                body: Column(
                  children: [
                    _OrderOfflineBanner(
                      orderStream:
                      orderRef.snapshots(includeMetadataChanges: true),
                      isOffline: _isOffline,
                      buildOfflineBanner: _buildOfflineBanner,
                    ),
                    Expanded(
                      child: _OrderItemsBody(
                        itemsStream: orderRef
                            .collection("items")
                            .orderBy("addedAt", descending: false)
                            .snapshots(),
                        orderStream:
                        orderRef.snapshots(includeMetadataChanges: true),
                        tenantId: tenantId,
                        uid: uid,
                        role: role,
                        cleanErr: _cleanErr,
                        canAccessOrder: _canAccessOrder,
                        canEditOrder: _canEditOrder,
                        isStorageManagerRole: _isStorageManagerRole,
                        buildScreenSections: _buildScreenSections,
                        screenTableHeader: _screenTableHeader,
                        sectionCardBuilder: ({
                          required _ScreenSection section,
                          required String tenantId,
                          required String uid,
                          required String role,
                          required bool canEdit,
                        }) =>
                            _sectionCard(
                              section: section,
                              tenantId: tenantId,
                              uid: uid,
                              role: role,
                              canEdit: canEdit,
                            ),
                      ),
                    ),
                  ],
                ),
                bottomNavigationBar: const BottomNav(
                  currentIndex: 2,
                  hasFab: false,
                  isRootScreen: false,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _OrderAppBar extends StatelessWidget {
  final Stream<DocumentSnapshot<Map<String, dynamic>>> orderStream;
  final String uid;
  final String role;
  final bool isOffline;
  final bool isExportingPdf;
  final bool Function({
  required String uid,
  required String role,
  required Map<String, dynamic> orderData,
  }) canAccessOrder;
  final bool Function({
  required String uid,
  required String role,
  required Map<String, dynamic> orderData,
  }) canEditOrder;
  final bool Function({
  required String uid,
  required String role,
  required Map<String, dynamic> orderData,
  }) canExportOrder;
  final bool Function({
  required String uid,
  required String role,
  required Map<String, dynamic> orderData,
  }) canUndoExport;
  final bool Function(String role) isStorageManagerRole;
  final Future<void> Function() onBack;
  final VoidCallback onContinue;
  final VoidCallback onDelete;
  final VoidCallback onFinish;
  final VoidCallback onExport;
  final VoidCallback onUndoExport;
  final VoidCallback onReconnectExportBlocked;
  final VoidCallback onReconnectUndoBlocked;
  final String Function(Object e) cleanErr;
  final bool Function(Object e) isPermissionDenied;
  final bool Function(Object e) isSignedOutError;

  const _OrderAppBar({
    required this.orderStream,
    required this.uid,
    required this.role,
    required this.isOffline,
    required this.isExportingPdf,
    required this.canAccessOrder,
    required this.canEditOrder,
    required this.canExportOrder,
    required this.canUndoExport,
    required this.isStorageManagerRole,
    required this.onBack,
    required this.onContinue,
    required this.onDelete,
    required this.onFinish,
    required this.onExport,
    required this.onUndoExport,
    required this.onReconnectExportBlocked,
    required this.onReconnectUndoBlocked,
    required this.cleanErr,
    required this.isPermissionDenied,
    required this.isSignedOutError,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: orderStream,
      builder: (context, snap) {
        String title = "Order";
        List<Widget> actions = [];

        if (snap.hasData && snap.data!.exists && snap.data!.data() != null) {
          final orderDoc = snap.data!;
          final orderData = orderDoc.data()!;
          title = (orderData["name"] ?? "Order").toString();

          if (canAccessOrder(uid: uid, role: role, orderData: orderData)) {
            final isActive = orderData["isActive"] == true;
            final isExported = orderData["isExported"] == true;
            final canEditBase =
            canEditOrder(uid: uid, role: role, orderData: orderData);

            final criticalActionsBlocked = isOffline || isExportingPdf;

            final canExport = !isActive &&
                !isExported &&
                canExportOrder(uid: uid, role: role, orderData: orderData);

            final canUndo = isExported &&
                canUndoExport(uid: uid, role: role, orderData: orderData);

            if (!canEditBase) {
              actions.add(
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: Center(
                    child: Text(
                      "VIEW ONLY",
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              );
            } else {
              if (isActive && !isExported) {
                actions.add(
                  TextButton(
                    onPressed: onDelete,
                    child: const Text(
                      "DELETE",
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                );
                actions.add(
                  TextButton(
                    onPressed: onFinish,
                    child: const Text(
                      "FINISH",
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                );
              }

              if (!isActive && !isExported) {
                actions.add(
                  TextButton(
                    onPressed: onContinue,
                    child: const Text(
                      "CONTINUE",
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                );
              }

              if (canExport) {
                actions.add(
                  TextButton(
                    onPressed: criticalActionsBlocked
                        ? onReconnectExportBlocked
                        : onExport,
                    child: Text(
                      isExportingPdf ? "EXPORTING..." : "EXPORT",
                      style: TextStyle(
                        color: criticalActionsBlocked
                            ? Colors.white54
                            : Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                );
              }

              if (canUndo) {
                actions.add(
                  TextButton(
                    onPressed: criticalActionsBlocked
                        ? onReconnectUndoBlocked
                        : onUndoExport,
                    child: Text(
                      "CANCEL ORDER",
                      style: TextStyle(
                        color: criticalActionsBlocked
                            ? Colors.white54
                            : Colors.white,
                      ),
                    ),
                  ),
                );
              }

              if (isExported) {
                actions.add(
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: Center(
                      child: Text(
                        "EXPORTED",
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                );
              }
            }
          }
        }

        return AppBar(
          backgroundColor: const Color(0xff0B1E40),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () async {
              await onBack();
            },
          ),
          title: Text(
            title,
            style: const TextStyle(color: Colors.white),
          ),
          actions: actions,
        );
      },
    );
  }
}

class _OrderOfflineBanner extends StatelessWidget {
  final Stream<DocumentSnapshot<Map<String, dynamic>>> orderStream;
  final bool isOffline;
  final Widget Function({
  required bool isOffline,
  required bool fromCache,
  required bool hasPendingWrites,
  }) buildOfflineBanner;

  const _OrderOfflineBanner({
    required this.orderStream,
    required this.isOffline,
    required this.buildOfflineBanner,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: orderStream,
      builder: (context, snap) {
        if (!snap.hasData || !snap.data!.exists) {
          return const SizedBox.shrink();
        }

        final doc = snap.data!;
        return buildOfflineBanner(
          isOffline: isOffline,
          fromCache: doc.metadata.isFromCache,
          hasPendingWrites: doc.metadata.hasPendingWrites,
        );
      },
    );
  }
}

class _OrderItemsBody extends StatelessWidget {
  final Stream<QuerySnapshot<Map<String, dynamic>>> itemsStream;
  final Stream<DocumentSnapshot<Map<String, dynamic>>> orderStream;
  final String tenantId;
  final String uid;
  final String role;
  final String Function(Object e) cleanErr;
  final bool Function({
  required String uid,
  required String role,
  required Map<String, dynamic> orderData,
  }) canAccessOrder;
  final bool Function({
  required String uid,
  required String role,
  required Map<String, dynamic> orderData,
  }) canEditOrder;
  final bool Function(String role) isStorageManagerRole;
  final List<_ScreenSection> Function(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
      ) buildScreenSections;
  final Widget Function({required bool canEdit}) screenTableHeader;
  final Widget Function({
  required _ScreenSection section,
  required String tenantId,
  required String uid,
  required String role,
  required bool canEdit,
  }) sectionCardBuilder;

  const _OrderItemsBody({
    required this.itemsStream,
    required this.orderStream,
    required this.tenantId,
    required this.uid,
    required this.role,
    required this.cleanErr,
    required this.canAccessOrder,
    required this.canEditOrder,
    required this.isStorageManagerRole,
    required this.buildScreenSections,
    required this.screenTableHeader,
    required this.sectionCardBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: orderStream,
      builder: (context, orderSnap) {
        if (orderSnap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                cleanErr(orderSnap.error!),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        if (!orderSnap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final orderDoc = orderSnap.data!;
        final orderData = orderDoc.data();

        if (!orderDoc.exists || orderData == null) {
          return const Center(child: Text("Order not found."));
        }

        if (!canAccessOrder(uid: uid, role: role, orderData: orderData)) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                "You don't have access to this order.",
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final isActive = orderData["isActive"] == true;
        final isExported = orderData["isExported"] == true;
        final canEdit =
            canEditOrder(uid: uid, role: role, orderData: orderData) &&
                isActive &&
                !isExported;

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: itemsStream,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    cleanErr(snap.error!),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }

            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final docs = snap.data!.docs;
            if (docs.isEmpty) {
              return const Center(
                child: Text("No items yet. Add from Items screen."),
              );
            }

            final sections = buildScreenSections(docs);

            return ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (isStorageManagerRole(role))
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blueGrey.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.blueGrey.shade100,
                      ),
                    ),
                    child: const Text(
                      "View only mode. Storage Manager can view all orders but cannot edit them.",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                screenTableHeader(canEdit: canEdit),
                const SizedBox(height: 12),
                ...sections.map(
                      (section) => sectionCardBuilder(
                    section: section,
                    tenantId: tenantId,
                    uid: uid,
                    role: role,
                    canEdit: canEdit,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class FolderNode {
  final String name;
  final Map<String, FolderNode> children = {};
  final List<Map<String, dynamic>> items = [];

  FolderNode(this.name);
}

class _ScreenSection {
  final String title;
  final int depth;
  final List<Map<String, dynamic>> rows;

  _ScreenSection({
    required this.title,
    required this.depth,
    required this.rows,
  });
}

class _PdfRow {
  final String folder;
  final String code;
  final String qtyWithSize;
  final String wholesalePrice;
  final bool showFolder;
  final bool showCode;
  final bool isMainFolder;

  _PdfRow({
    required this.folder,
    required this.code,
    required this.qtyWithSize,
    required this.wholesalePrice,
    required this.showFolder,
    required this.showCode,
    required this.isMainFolder,
  });
}

class _PdfSection {
  final String title;
  final List<_PdfRow> items;
  final int depth;

  _PdfSection({
    required this.title,
    required this.items,
    required this.depth,
  });
}

class _PdfSectionPart {
  final String title;
  final List<_PdfRow> rows;
  final int partIndex;
  final int totalParts;
  final int depth;

  _PdfSectionPart({
    required this.title,
    required this.rows,
    required this.partIndex,
    required this.totalParts,
    required this.depth,
  });
}

class _PdfPage {
  final List<_PdfSectionPart> left = [];
  final List<_PdfSectionPart> right = [];
}