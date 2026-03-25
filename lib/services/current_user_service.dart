//helper class for getting the currently signed-in user’s app data from Firestore
// and checking if that user still belongs to a valid tenant
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_user.dart';

class CurrentUserService {
  CurrentUserService({
    FirebaseAuth? auth,
    FirebaseFirestore? db,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _db = db ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _db;

  bool _isAuthErrorCode(String? code) {
    return code == "permission-denied" || code == "unauthenticated";
  }

  Exception _normalizeError(Object error) {
    if (error is FirebaseException && _isAuthErrorCode(error.code)) {
      return Exception("USER_SIGNED_OUT");
    }

    final msg = error.toString().toLowerCase();
    if (msg.contains("permission-denied") ||
        msg.contains("permission denied") ||
        msg.contains("unauthenticated") ||
        msg.contains("user is not signed in") ||
        msg.contains("requires authentication") ||
        msg.contains("user_signed_out")) {
      return Exception("USER_SIGNED_OUT");
    }

    return Exception(error.toString().replaceFirst("Exception: ", "").trim());
  }

  //offline friendly document fetch method
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

  //user loading
  Future<AppUser?> load() async {
    try {
      final firebaseUser = _auth.currentUser;
      if (firebaseUser == null) return null;

      final doc = await _tryGetDocServerThenCache(
        _db.collection('users').doc(firebaseUser.uid),
      );

      if (doc == null || !doc.exists || doc.data() == null) {
        return null;
      }

      final data = doc.data()!;
      return AppUser.fromMap(firebaseUser.uid, data);
    } catch (e) {
      throw _normalizeError(e);
    }
  }

  //tenant validation
  Future<bool> hasValidTenant(AppUser user) async {
    try {
      if (!user.hasValidTenantId) return false;

      final tenantId = user.tenantId.trim();
      if (tenantId.isEmpty) return false;

      final tenantDoc = await _tryGetDocServerThenCache(
        _db.collection('tenants').doc(tenantId),
      );

      if (tenantDoc == null || !tenantDoc.exists) return false;

      final tenantData = tenantDoc.data() ?? <String, dynamic>{};
      final isActive = tenantData['isActive'];

      if (isActive is bool && isActive == false) {
        return false;
      }

      return true;
    } catch (e) {
      throw _normalizeError(e);
    }
  }

  //checks whether the user is actually listed inside the tenant’s users sub collection
  Future<bool> existsInTenantUsers(AppUser user) async {
    try {
      if (!user.hasValidTenantId) return false;

      final tenantUserDoc = await _tryGetDocServerThenCache(
        _db
            .collection('tenants')
            .doc(user.tenantId.trim())
            .collection('users')
            .doc(user.uid),
      );

      return tenantUserDoc?.exists == true;
    } catch (e) {
      throw _normalizeError(e);
    }
  }

  Future<bool> hasValidTenantAndMembership(AppUser user) async {
    final tenantOk = await hasValidTenant(user);
    if (!tenantOk) return false;

    final membershipOk = await existsInTenantUsers(user);
    return membershipOk;
  }
}