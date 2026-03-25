import 'package:cloud_firestore/cloud_firestore.dart';

class OutOfStockService {
  OutOfStockService({FirebaseFirestore? firestore})
      : _fs = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _fs;

  static const String _outOfStockSystemType = "out_of_stock";

  CollectionReference<Map<String, dynamic>> _foldersCol(String tenantId) {
    return _fs.collection("tenants").doc(tenantId).collection("folders");
  }

  CollectionReference<Map<String, dynamic>> _productsCol(String tenantId) {
    return _fs.collection("tenants").doc(tenantId).collection("products");
  }

  CollectionReference<Map<String, dynamic>> _movementHistoryCol(String tenantId) {
    return _fs.collection("tenants").doc(tenantId).collection("movement_history");
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? "") ?? 0;
  }

  String _cleanString(dynamic v) {
    return (v ?? "").toString().trim();
  }

  bool _isOutOfStockFolder(Map<String, dynamic> data) {
    return data["isSystemFolder"] == true &&
        _cleanString(data["systemType"]) == _outOfStockSystemType;
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _tryGetDocServerThenCache(
      DocumentReference<Map<String, dynamic>> ref, {
        Duration serverTimeout = const Duration(milliseconds: 1200),
        Duration cacheTimeout = const Duration(milliseconds: 500),
      }) async {
    try {
      return await ref.get().timeout(serverTimeout);
    } catch (_) {}

    try {
      return await ref
          .get(const GetOptions(source: Source.cache))
          .timeout(cacheTimeout);
    } catch (_) {}

    return null;
  }

  Future<QuerySnapshot<Map<String, dynamic>>?> _tryGetQueryServerThenCache(
      Query<Map<String, dynamic>> query, {
        Duration serverTimeout = const Duration(milliseconds: 1200),
        Duration cacheTimeout = const Duration(milliseconds: 500),
      }) async {
    try {
      return await query.get().timeout(serverTimeout);
    } catch (_) {}

    try {
      return await query
          .get(const GetOptions(source: Source.cache))
          .timeout(cacheTimeout);
    } catch (_) {}

    return null;
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _getFolder(
      String tenantId,
      String? folderId,
      ) async {
    final safeFolderId = _cleanString(folderId);
    if (safeFolderId.isEmpty) return null;

    final snap = await _tryGetDocServerThenCache(
      _foldersCol(tenantId).doc(safeFolderId),
    );

    if (snap == null || !snap.exists) return null;
    return snap;
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _findChildOutOfStockFolder(
      String tenantId,
      String parentFolderId,
      ) async {
    final safeParentFolderId = _cleanString(parentFolderId);
    if (safeParentFolderId.isEmpty) return null;

    final snap = await _tryGetQueryServerThenCache(
      _foldersCol(tenantId)
          .where("parentId", isEqualTo: safeParentFolderId)
          .where("systemType", isEqualTo: _outOfStockSystemType)
          .limit(1),
    );

    if (snap == null || snap.docs.isEmpty) return null;
    return snap.docs.first;
  }

  Future<String?> _getOrCreateChildOutOfStockFolder(
      String tenantId,
      String parentFolderId,
      ) async {
    final safeParentFolderId = _cleanString(parentFolderId);
    if (safeParentFolderId.isEmpty) return null;

    final parentFolderSnap = await _getFolder(tenantId, safeParentFolderId);
    if (parentFolderSnap == null || !parentFolderSnap.exists) return null;

    final parentFolderData = parentFolderSnap.data() ?? <String, dynamic>{};

    if (_isOutOfStockFolder(parentFolderData)) {
      return parentFolderSnap.id;
    }

    final existing = await _findChildOutOfStockFolder(tenantId, safeParentFolderId);
    if (existing != null) return existing.id;

    final newRef = _foldersCol(tenantId).doc();

    await newRef.set({
      "name": "Out of stock",
      "isSystemFolder": true,
      "systemType": _outOfStockSystemType,
      "parentId": safeParentFolderId,
      "createdAt": FieldValue.serverTimestamp(),
      "updatedAt": FieldValue.serverTimestamp(),
    });

    return newRef.id;
  }

  Future<List<String>> _buildFolderPathNames(
      String tenantId,
      String? folderId,
      ) async {
    final safeFolderId = _cleanString(folderId);
    if (safeFolderId.isEmpty) return [];

    final names = <String>[];
    String? currentId = safeFolderId;

    while (currentId != null && currentId.isNotEmpty) {
      final snap = await _tryGetDocServerThenCache(
        _foldersCol(tenantId).doc(currentId),
      );
      if (snap == null || !snap.exists) break;

      final data = snap.data() ?? <String, dynamic>{};
      final name = _cleanString(data["name"]);
      if (name.isNotEmpty) {
        names.add(name);
      }

      final parentId = _cleanString(data["parentId"]);
      currentId = parentId.isEmpty ? null : parentId;
    }

    return names.reversed.toList();
  }

  Future<void> syncProductFolderWithStock({
    required String tenantId,
    required String productId,
  }) async {
    final productRef = _productsCol(tenantId).doc(productId);
    final productSnap = await _tryGetDocServerThenCache(productRef);
    if (productSnap == null || !productSnap.exists) return;

    final product = productSnap.data() ?? <String, dynamic>{};

    final int stockQuantity = _toInt(product["stockQuantity"]);
    final String currentFolderId = _cleanString(product["folderId"]);
    final String originalFolderId = _cleanString(product["originalFolderId"]);
    final String code = _cleanString(product["code"]);
    final String name = _cleanString(product["name"]);

    if (currentFolderId.isEmpty) return;

    final currentFolderSnap = await _getFolder(tenantId, currentFolderId);
    if (currentFolderSnap == null) return;

    final currentFolderData = currentFolderSnap.data() ?? <String, dynamic>{};
    final bool currentlyInOutOfStock = _isOutOfStockFolder(currentFolderData);

    //move into child out_of_stock folder
    if (stockQuantity <= 0) {
      if (currentlyInOutOfStock) return;

      final outOfStockFolderId =
      await _getOrCreateChildOutOfStockFolder(tenantId, currentFolderId);

      if (outOfStockFolderId == null || outOfStockFolderId == currentFolderId) {
        return;
      }

      final restoreFolderId = currentFolderId;

      final oldPathNames = await _buildFolderPathNames(tenantId, currentFolderId);
      final newPathNames = await _buildFolderPathNames(tenantId, outOfStockFolderId);

      final batch = _fs.batch();

      batch.update(productRef, {
        "folderId": outOfStockFolderId,
        "originalFolderId": restoreFolderId,
        "updatedAt": FieldValue.serverTimestamp(),
      });

      batch.set(_movementHistoryCol(tenantId).doc(), {
        "type": "auto_moved_to_out_of_stock",
        "productId": productId,
        "productName": name.isNotEmpty ? name : code,
        "previousStock": stockQuantity,
        "newStock": stockQuantity,
        "quantityChanged": 0,
        "changedBy": "system",
        "oldPathNames": [...oldPathNames, if (code.isNotEmpty) code],
        "newPathNames": [...newPathNames, if (code.isNotEmpty) code],
        "createdAt": FieldValue.serverTimestamp(),
      });

      await batch.commit();
      return;
    }

    //restore from out_of_stock to original folder
    if (stockQuantity > 0 && currentlyInOutOfStock) {
      if (originalFolderId.isEmpty || originalFolderId == currentFolderId) {
        return;
      }

      final originalFolderSnap = await _getFolder(tenantId, originalFolderId);
      if (originalFolderSnap == null) return;

      final oldPathNames = await _buildFolderPathNames(tenantId, currentFolderId);
      final newPathNames = await _buildFolderPathNames(tenantId, originalFolderId);

      final batch = _fs.batch();

      batch.update(productRef, {
        "folderId": originalFolderId,
        "originalFolderId": FieldValue.delete(),
        "updatedAt": FieldValue.serverTimestamp(),
      });

      batch.set(_movementHistoryCol(tenantId).doc(), {
        "type": "auto_restored_from_out_of_stock",
        "productId": productId,
        "productName": name.isNotEmpty ? name : code,
        "previousStock": stockQuantity,
        "newStock": stockQuantity,
        "quantityChanged": 0,
        "changedBy": "system",
        "oldPathNames": [...oldPathNames, if (code.isNotEmpty) code],
        "newPathNames": [...newPathNames, if (code.isNotEmpty) code],
        "createdAt": FieldValue.serverTimestamp(),
      });

      await batch.commit();
    }
  }
}