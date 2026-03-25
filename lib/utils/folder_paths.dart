import 'package:cloud_firestore/cloud_firestore.dart';

class FolderPaths {
  static CollectionReference<Map<String, dynamic>> _foldersRef(
      FirebaseFirestore fs,
      String tenantId,
      ) {
    return fs.collection("tenants").doc(tenantId).collection("folders");
  }

  static Future<DocumentSnapshot<Map<String, dynamic>>?> _getFolderDoc(
      FirebaseFirestore fs,
      String tenantId,
      String folderId, {
        Duration serverTimeout = const Duration(milliseconds: 1200),
        Duration cacheTimeout = const Duration(milliseconds: 500),
      }) async {
    final ref = _foldersRef(fs, tenantId).doc(folderId);

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

  static String? _parentIdOf(Map<String, dynamic> data) {
    final raw = data["parentId"];
    if (raw == null) return null;

    final value = raw.toString().trim();
    return value.isEmpty ? null : value;
  }

  static Future<List<String>> buildParentPathNamesNoRoot(
      FirebaseFirestore fs,
      String tenantId,
      String? folderId,
      ) async {
    final startId = folderId?.trim();
    if (startId == null || startId.isEmpty) return [];

    final List<String> names = [];
    String? currentId = startId;

    while (currentId != null) {
      final doc = await _getFolderDoc(fs, tenantId, currentId);
      if (doc == null || !doc.exists) break;

      final data = doc.data() ?? <String, dynamic>{};
      final name = (data["name"] ?? "").toString().trim();
      if (name.isNotEmpty) {
        names.add(name);
      }

      currentId = _parentIdOf(data);
    }

    return names.reversed.toList();
  }

  static Future<List<String>> getFolderBreadcrumbFromFolderId(
      FirebaseFirestore fs,
      String tenantId,
      String folderId,
      ) async {
    final startId = folderId.trim();
    if (startId.isEmpty) return [];

    final List<String> names = [];
    String? currentId = startId;

    while (currentId != null) {
      final doc = await _getFolderDoc(fs, tenantId, currentId);
      if (doc == null || !doc.exists) break;

      final data = doc.data() ?? <String, dynamic>{};
      final name = (data["name"] ?? "").toString().trim();
      if (name.isNotEmpty) {
        names.add(name);
      }

      currentId = _parentIdOf(data);
    }

    return names.reversed.toList();
  }

  static Future<List<String>> getFolderBreadcrumbForFolderDoc(
      FirebaseFirestore fs,
      String tenantId,
      QueryDocumentSnapshot<Map<String, dynamic>> folderDoc,
      ) async {
    final data = folderDoc.data();
    final name = (data["name"] ?? "").toString().trim();
    final parentId = _parentIdOf(data);

    final parentPath =
    await buildParentPathNamesNoRoot(fs, tenantId, parentId);
    final safeName = name.isEmpty ? "(folder)" : name;

    return [...parentPath, safeName];
  }

  static Future<List<String>> getFolderPathNamesForOrders(
      FirebaseFirestore fs,
      String tenantId,
      String folderId,
      ) async {
    final names =
    await getFolderBreadcrumbFromFolderId(fs, tenantId, folderId);
    return names.where((e) => e.trim().isNotEmpty).toList();
  }

  static Future<Map<String, List<String>>> buildMovePathsNoRoot({
    required FirebaseFirestore fs,
    required String tenantId,
    required String? oldParentId,
    required String? newParentId,
    required String entityName,
  }) async {
    final oldParentPath =
    await buildParentPathNamesNoRoot(fs, tenantId, oldParentId);
    final newParentPath =
    await buildParentPathNamesNoRoot(fs, tenantId, newParentId);

    final safeName = entityName.trim().isEmpty ? "(item)" : entityName.trim();

    return {
      "old": [...oldParentPath, safeName],
      "new": [...newParentPath, safeName],
    };
  }
}