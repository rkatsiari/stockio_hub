import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class TenantContextService {
  TenantContextService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  static const String kSignedOutMessage = "USER_SIGNED_OUT";

  bool get isSignedIn {
    final uid = _auth.currentUser?.uid;
    return uid != null && uid.trim().isNotEmpty;
  }

  String get _uidOrThrow {
    final uid = _auth.currentUser?.uid.trim();
    if (uid == null || uid.isEmpty) {
      throw Exception(kSignedOutMessage);
    }
    return uid;
  }

  bool _isAuthErrorCode(String? code) {
    return code == "permission-denied" || code == "unauthenticated";
  }

  Exception _normalizeError(Object error) {
    if (error is FirebaseException && _isAuthErrorCode(error.code)) {
      return Exception(kSignedOutMessage);
    }

    final msg = error.toString().toLowerCase();
    if (msg.contains("permission-denied") ||
        msg.contains("permission denied") ||
        msg.contains("unauthenticated") ||
        msg.contains("user is not signed in") ||
        msg.contains("requires authentication") ||
        msg.contains(kSignedOutMessage.toLowerCase())) {
      return Exception(kSignedOutMessage);
    }

    return Exception(error.toString().replaceFirst("Exception: ", "").trim());
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

  Future<DocumentSnapshot<Map<String, dynamic>>> _userProfileDoc() async {
    try {
      final uid = _uidOrThrow;
      final ref = _firestore.collection("users").doc(uid);

      final userDoc = await _tryGetDocServerThenCache(ref);

      if (userDoc == null || !userDoc.exists) {
        throw Exception("User profile not found.");
      }

      return userDoc;
    } catch (e) {
      throw _normalizeError(e);
    }
  }

  Future<Map<String, dynamic>> getCurrentUserProfile() async {
    try {
      final doc = await _userProfileDoc();
      return doc.data() ?? <String, dynamic>{};
    } catch (e) {
      throw _normalizeError(e);
    }
  }

  Future<Map<String, dynamic>?> tryGetCurrentUserProfile() async {
    try {
      return await getCurrentUserProfile();
    } catch (_) {
      return null;
    }
  }

  Future<String> getTenantId() async {
    try {
      final data = await getCurrentUserProfile();
      final tenantId = (data["tenantId"] ?? "").toString().trim();

      if (tenantId.isEmpty) {
        throw Exception("User is not assigned to a tenant.");
      }

      return tenantId;
    } catch (e) {
      throw _normalizeError(e);
    }
  }

  Future<String> getTenantIdOrThrow() async {
    return getTenantId();
  }

  Future<String?> tryGetTenantId() async {
    try {
      return await getTenantId();
    } catch (_) {
      return null;
    }
  }

  Future<String> getRole() async {
    try {
      final data = await getCurrentUserProfile();
      return (data["role"] ?? "").toString().trim();
    } catch (e) {
      throw _normalizeError(e);
    }
  }

  Future<String?> tryGetRole() async {
    try {
      return await getRole();
    } catch (_) {
      return null;
    }
  }

  Future<bool> isAdmin() async {
    final role = await getRole();
    return role == "admin";
  }

  Future<bool> tryIsAdmin() async {
    try {
      return await isAdmin();
    } catch (_) {
      return false;
    }
  }

  Future<DocumentReference<Map<String, dynamic>>> tenantDoc() async {
    final tenantId = await getTenantId();
    return tenantDocById(tenantId);
  }

  DocumentReference<Map<String, dynamic>> tenantDocById(String tenantId) {
    return _firestore.collection("tenants").doc(tenantId);
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> getTenantDoc() async {
    try {
      final ref = await tenantDoc();
      final doc = await _tryGetDocServerThenCache(ref);

      if (doc == null || !doc.exists) {
        throw Exception("Tenant not found.");
      }

      return doc;
    } catch (e) {
      throw _normalizeError(e);
    }
  }

  Future<CollectionReference<Map<String, dynamic>>> tenantUsersCollection() async {
    final tenantId = await getTenantId();
    return tenantUsersCollectionByTenantId(tenantId);
  }

  CollectionReference<Map<String, dynamic>> tenantUsersCollectionByTenantId(
      String tenantId,
      ) {
    return _firestore.collection("tenants").doc(tenantId).collection("users");
  }

  Future<DocumentReference<Map<String, dynamic>>> tenantUserDoc(String uid) async {
    final tenantId = await getTenantId();
    return tenantUserDocByTenantId(tenantId, uid);
  }

  DocumentReference<Map<String, dynamic>> tenantUserDocByTenantId(
      String tenantId,
      String uid,
      ) {
    return _firestore
        .collection("tenants")
        .doc(tenantId)
        .collection("users")
        .doc(uid);
  }

  Future<CollectionReference<Map<String, dynamic>>> productsCollection() async {
    final tenantId = await getTenantId();
    return productsCollectionByTenantId(tenantId);
  }

  CollectionReference<Map<String, dynamic>> productsCollectionByTenantId(
      String tenantId,
      ) {
    return _firestore.collection("tenants").doc(tenantId).collection("products");
  }

  Future<DocumentReference<Map<String, dynamic>>> productDoc(
      String productId,
      ) async {
    final tenantId = await getTenantId();
    return productDocByTenantId(tenantId, productId);
  }

  DocumentReference<Map<String, dynamic>> productDocByTenantId(
      String tenantId,
      String productId,
      ) {
    return _firestore
        .collection("tenants")
        .doc(tenantId)
        .collection("products")
        .doc(productId);
  }

  Future<CollectionReference<Map<String, dynamic>>> foldersCollection() async {
    final tenantId = await getTenantId();
    return foldersCollectionByTenantId(tenantId);
  }

  CollectionReference<Map<String, dynamic>> foldersCollectionByTenantId(
      String tenantId,
      ) {
    return _firestore.collection("tenants").doc(tenantId).collection("folders");
  }

  Future<DocumentReference<Map<String, dynamic>>> folderDoc(
      String folderId,
      ) async {
    final tenantId = await getTenantId();
    return folderDocByTenantId(tenantId, folderId);
  }

  DocumentReference<Map<String, dynamic>> folderDocByTenantId(
      String tenantId,
      String folderId,
      ) {
    return _firestore
        .collection("tenants")
        .doc(tenantId)
        .collection("folders")
        .doc(folderId);
  }

  Future<CollectionReference<Map<String, dynamic>>> movementHistoryCollection() async {
    final tenantId = await getTenantId();
    return movementHistoryCollectionByTenantId(tenantId);
  }

  CollectionReference<Map<String, dynamic>> movementHistoryCollectionByTenantId(
      String tenantId,
      ) {
    return _firestore
        .collection("tenants")
        .doc(tenantId)
        .collection("movement_history");
  }

  Future<CollectionReference<Map<String, dynamic>>> ordersCollection() async {
    final tenantId = await getTenantId();
    return ordersCollectionByTenantId(tenantId);
  }

  CollectionReference<Map<String, dynamic>> ordersCollectionByTenantId(
      String tenantId,
      ) {
    return _firestore.collection("tenants").doc(tenantId).collection("orders");
  }

  Future<DocumentReference<Map<String, dynamic>>> orderDoc(String orderId) async {
    final tenantId = await getTenantId();
    return orderDocByTenantId(tenantId, orderId);
  }

  DocumentReference<Map<String, dynamic>> orderDocByTenantId(
      String tenantId,
      String orderId,
      ) {
    return _firestore
        .collection("tenants")
        .doc(tenantId)
        .collection("orders")
        .doc(orderId);
  }

  Future<CollectionReference<Map<String, dynamic>>> shopsCollection() async {
    final tenantId = await getTenantId();
    return shopsCollectionByTenantId(tenantId);
  }

  CollectionReference<Map<String, dynamic>> shopsCollectionByTenantId(
      String tenantId,
      ) {
    return _firestore.collection("tenants").doc(tenantId).collection("shops");
  }

  Future<DocumentReference<Map<String, dynamic>>> shopDoc(String shopId) async {
    final tenantId = await getTenantId();
    return shopDocByTenantId(tenantId, shopId);
  }

  DocumentReference<Map<String, dynamic>> shopDocByTenantId(
      String tenantId,
      String shopId,
      ) {
    return _firestore
        .collection("tenants")
        .doc(tenantId)
        .collection("shops")
        .doc(shopId);
  }

  Future<bool> hasAnyCachedUserProfile() async {
    try {
      final uid = _uidOrThrow;
      final ref = _firestore.collection("users").doc(uid);
      final snap = await ref.get(const GetOptions(source: Source.cache));
      return snap.exists;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasAnyCachedTenantDoc() async {
    try {
      final tenantId = await tryGetTenantId();
      if (tenantId == null || tenantId.trim().isEmpty) return false;

      final ref = tenantDocById(tenantId);
      final snap = await ref.get(const GetOptions(source: Source.cache));
      return snap.exists;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> tryGetCurrentUserProfileCacheOnly() async {
    try {
      final uid = _uidOrThrow;
      final ref = _firestore.collection("users").doc(uid);
      final snap = await ref.get(const GetOptions(source: Source.cache));
      return snap.data();
    } catch (_) {
      return null;
    }
  }

  Future<String?> tryGetTenantIdCacheOnly() async {
    try {
      final data = await tryGetCurrentUserProfileCacheOnly();
      final tenantId = (data?["tenantId"] ?? "").toString().trim();
      return tenantId.isEmpty ? null : tenantId;
    } catch (_) {
      return null;
    }
  }

  Future<String?> tryGetRoleCacheOnly() async {
    try {
      final data = await tryGetCurrentUserProfileCacheOnly();
      final role = (data?["role"] ?? "").toString().trim();
      return role.isEmpty ? null : role;
    } catch (_) {
      return null;
    }
  }
}