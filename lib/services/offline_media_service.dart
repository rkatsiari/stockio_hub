import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OfflineImageRecord {
  final String tenantId;
  final String productId;
  final String localPath;
  final String? remoteUrl;
  final int updatedAtMillis;

  const OfflineImageRecord({
    required this.tenantId,
    required this.productId,
    required this.localPath,
    required this.updatedAtMillis,
    this.remoteUrl,
  });

  String get key => '${tenantId}_$productId';

  Map<String, dynamic> toJson() {
    return {
      'tenantId': tenantId,
      'productId': productId,
      'localPath': localPath,
      'remoteUrl': remoteUrl,
      'updatedAtMillis': updatedAtMillis,
    };
  }

  factory OfflineImageRecord.fromJson(Map<String, dynamic> json) {
    return OfflineImageRecord(
      tenantId: (json['tenantId'] ?? '').toString(),
      productId: (json['productId'] ?? '').toString(),
      localPath: (json['localPath'] ?? '').toString(),
      remoteUrl: json['remoteUrl']?.toString(),
      updatedAtMillis: (json['updatedAtMillis'] ?? 0) as int,
    );
  }
}

class PendingImageUpload {
  final String tenantId;
  final String productId;
  final String localPath;
  final String storagePath;
  final String? previousRemoteUrl;
  final int createdAtMillis;

  const PendingImageUpload({
    required this.tenantId,
    required this.productId,
    required this.localPath,
    required this.storagePath,
    required this.createdAtMillis,
    this.previousRemoteUrl,
  });

  String get queueKey => '${tenantId}_$productId';

  Map<String, dynamic> toJson() {
    return {
      'tenantId': tenantId,
      'productId': productId,
      'localPath': localPath,
      'storagePath': storagePath,
      'previousRemoteUrl': previousRemoteUrl,
      'createdAtMillis': createdAtMillis,
    };
  }

  factory PendingImageUpload.fromJson(Map<String, dynamic> json) {
    return PendingImageUpload(
      tenantId: (json['tenantId'] ?? '').toString(),
      productId: (json['productId'] ?? '').toString(),
      localPath: (json['localPath'] ?? '').toString(),
      storagePath: (json['storagePath'] ?? '').toString(),
      previousRemoteUrl: json['previousRemoteUrl']?.toString(),
      createdAtMillis: (json['createdAtMillis'] ?? 0) as int,
    );
  }
}

class OfflineMediaService {
  OfflineMediaService._();
  static final OfflineMediaService instance = OfflineMediaService._();

  static const String _imageRegistryKey = 'offline_image_registry_v1';
  static const String _pendingUploadQueueKey = 'pending_image_upload_queue_v1';

  Future<Directory> _baseDir() async {
    if (kIsWeb) {
      throw UnsupportedError(
        'Offline file storage using path_provider is not supported on Flutter web.',
      );
    }

    final dir = await getApplicationDocumentsDirectory();
    final mediaDir = Directory('${dir.path}/offline_media');
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    return mediaDir;
  }

  String _sanitize(String value) {
    return value.replaceAll(RegExp(r'[^\w\-.]+'), '_');
  }

  Future<Directory> _tenantDir(String tenantId) async {
    final base = await _baseDir();
    final dir = Directory('${base.path}/tenant_${_sanitize(tenantId)}');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> _productImagesDir(String tenantId) async {
    final tenantDir = await _tenantDir(tenantId);
    final dir = Directory('${tenantDir.path}/product_images');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> _defaultImagePath({
    required String tenantId,
    required String productId,
    String extension = 'jpg',
  }) async {
    final dir = await _productImagesDir(tenantId);
    return '${dir.path}/${_sanitize(productId)}.$extension';
  }

  Future<SharedPreferences> _prefs() async {
    return SharedPreferences.getInstance();
  }

  Future<Map<String, OfflineImageRecord>> _loadRegistry() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_imageRegistryKey);
    if (raw == null || raw.trim().isEmpty) return {};

    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
            (key, value) => MapEntry(
          key,
          OfflineImageRecord.fromJson(Map<String, dynamic>.from(value)),
        ),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveRegistry(Map<String, OfflineImageRecord> registry) async {
    final prefs = await _prefs();
    final jsonMap = registry.map((key, value) => MapEntry(key, value.toJson()));
    await prefs.setString(_imageRegistryKey, jsonEncode(jsonMap));
  }

  Future<List<PendingImageUpload>> loadPendingUploads() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_pendingUploadQueueKey);
    if (raw == null || raw.trim().isEmpty) return [];

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => PendingImageUpload.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _savePendingUploads(List<PendingImageUpload> items) async {
    final prefs = await _prefs();
    await prefs.setString(
      _pendingUploadQueueKey,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  Future<File?> getLocalImageFile({
    required String tenantId,
    required String productId,
  }) async {
    if (kIsWeb) return null;

    final registry = await _loadRegistry();
    final key = '${tenantId}_$productId';
    final record = registry[key];

    if (record != null) {
      final file = File(record.localPath);
      if (await file.exists()) return file;
    }

    final fallback = File(
      await _defaultImagePath(tenantId: tenantId, productId: productId),
    );
    if (await fallback.exists()) return fallback;

    return null;
  }

  Future<String?> getLocalImagePath({
    required String tenantId,
    required String productId,
  }) async {
    final file = await getLocalImageFile(
      tenantId: tenantId,
      productId: productId,
    );
    return file?.path;
  }

  Future<File> saveImageBytesForProduct({
    required String tenantId,
    required String productId,
    required Uint8List bytes,
    String extension = 'jpg',
    String? remoteUrl,
  }) async {
    final path = await _defaultImagePath(
      tenantId: tenantId,
      productId: productId,
      extension: extension,
    );

    final file = File(path);
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }

    await file.writeAsBytes(bytes, flush: true);

    final registry = await _loadRegistry();
    final record = OfflineImageRecord(
      tenantId: tenantId,
      productId: productId,
      localPath: file.path,
      remoteUrl: remoteUrl,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    registry[record.key] = record;
    await _saveRegistry(registry);

    return file;
  }

  Future<File> saveImageFileForProduct({
    required String tenantId,
    required String productId,
    required File sourceFile,
    String extension = 'jpg',
    String? remoteUrl,
  }) async {
    final bytes = await sourceFile.readAsBytes();
    return saveImageBytesForProduct(
      tenantId: tenantId,
      productId: productId,
      bytes: bytes,
      extension: extension,
      remoteUrl: remoteUrl,
    );
  }

  Future<File?> downloadAndSaveProductImage({
    required String tenantId,
    required String productId,
    required String imageUrl,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (kIsWeb) return null;
    if (imageUrl.trim().isEmpty) return null;

    try {
      final uri = Uri.parse(imageUrl);
      final response = await http.get(uri).timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      String extension = 'jpg';
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      if (contentType.contains('png')) {
        extension = 'png';
      } else if (contentType.contains('webp')) {
        extension = 'webp';
      } else if (contentType.contains('jpeg') || contentType.contains('jpg')) {
        extension = 'jpg';
      }

      return saveImageBytesForProduct(
        tenantId: tenantId,
        productId: productId,
        bytes: response.bodyBytes,
        extension: extension,
        remoteUrl: imageUrl,
      );
    } catch (_) {
      return null;
    }
  }

  Future<File?> ensureOfflineImage({
    required String tenantId,
    required String productId,
    String? imageUrl,
  }) async {
    final local = await getLocalImageFile(
      tenantId: tenantId,
      productId: productId,
    );
    if (local != null) return local;

    if (imageUrl == null || imageUrl.trim().isEmpty) return null;

    return downloadAndSaveProductImage(
      tenantId: tenantId,
      productId: productId,
      imageUrl: imageUrl,
    );
  }

  Future<void> registerRemoteUrl({
    required String tenantId,
    required String productId,
    required String remoteUrl,
  }) async {
    final registry = await _loadRegistry();
    final key = '${tenantId}_$productId';
    final existing = registry[key];

    if (existing != null) {
      registry[key] = OfflineImageRecord(
        tenantId: existing.tenantId,
        productId: existing.productId,
        localPath: existing.localPath,
        remoteUrl: remoteUrl,
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      );
      await _saveRegistry(registry);
    }
  }

  Future<void> deleteOfflineImage({
    required String tenantId,
    required String productId,
  }) async {
    final registry = await _loadRegistry();
    final key = '${tenantId}_$productId';
    final record = registry[key];

    if (record != null) {
      final file = File(record.localPath);
      if (await file.exists()) {
        await file.delete();
      }
      registry.remove(key);
      await _saveRegistry(registry);
      return;
    }

    final fallback = File(
      await _defaultImagePath(tenantId: tenantId, productId: productId),
    );
    if (await fallback.exists()) {
      await fallback.delete();
    }
  }

  Future<void> enqueuePendingImageUpload({
    required String tenantId,
    required String productId,
    required String localPath,
    required String storagePath,
    String? previousRemoteUrl,
  }) async {
    final items = await loadPendingUploads();

    items.removeWhere(
          (e) => e.tenantId == tenantId && e.productId == productId,
    );

    items.add(
      PendingImageUpload(
        tenantId: tenantId,
        productId: productId,
        localPath: localPath,
        storagePath: storagePath,
        previousRemoteUrl: previousRemoteUrl,
        createdAtMillis: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    await _savePendingUploads(items);
  }

  Future<void> removePendingImageUpload({
    required String tenantId,
    required String productId,
  }) async {
    final items = await loadPendingUploads();
    items.removeWhere(
          (e) => e.tenantId == tenantId && e.productId == productId,
    );
    await _savePendingUploads(items);
  }

  Future<bool> hasPendingImageUpload({
    required String tenantId,
    required String productId,
  }) async {
    final items = await loadPendingUploads();
    return items.any(
          (e) => e.tenantId == tenantId && e.productId == productId,
    );
  }

  Future<void> clearMissingPendingUploads() async {
    final items = await loadPendingUploads();
    final kept = <PendingImageUpload>[];

    for (final item in items) {
      final file = File(item.localPath);
      if (await file.exists()) {
        kept.add(item);
      }
    }

    await _savePendingUploads(kept);
  }

  Future<List<OfflineImageRecord>> getAllOfflineImages() async {
    final registry = await _loadRegistry();
    return registry.values.toList()
      ..sort((a, b) => b.updatedAtMillis.compareTo(a.updatedAtMillis));
  }

  Future<void> prefetchProductImages({
    required String tenantId,
    required Iterable<Map<String, dynamic>> products,
  }) async {
    for (final product in products) {
      final productId = (product['id'] ?? '').toString();
      final imageUrl = product['imageUrl']?.toString();

      if (productId.isEmpty) continue;

      await ensureOfflineImage(
        tenantId: tenantId,
        productId: productId,
        imageUrl: imageUrl,
      );
    }
  }
}