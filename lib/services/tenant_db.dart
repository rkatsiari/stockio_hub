import 'package:cloud_firestore/cloud_firestore.dart';

class TenantDb {
  final FirebaseFirestore _db;
  final String tenantId;

  TenantDb({
    FirebaseFirestore? firestore,
    required this.tenantId,
  }) : _db = firestore ?? FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> get tenantDoc =>
      _db.collection('tenants').doc(tenantId);

  CollectionReference<Map<String, dynamic>> get users =>
      tenantDoc.collection('users');

  CollectionReference<Map<String, dynamic>> get items =>
      tenantDoc.collection('items');

  CollectionReference<Map<String, dynamic>> get orders =>
      tenantDoc.collection('orders');

  CollectionReference<Map<String, dynamic>> get folders =>
      tenantDoc.collection('folders');

  CollectionReference<Map<String, dynamic>> get movementHistory =>
      tenantDoc.collection('movement_history');
}