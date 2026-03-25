import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'offline_media_service.dart';

class ReconnectSyncService {
  ReconnectSyncService._();
  static final ReconnectSyncService instance = ReconnectSyncService._();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _started = false;
  bool _syncInProgress = false;

  void start() {
    if (_started) return;
    _started = true;

    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) async {
          final hasInternet = results.any((r) => r != ConnectivityResult.none);
          if (!hasInternet) return;
          await syncNow();
        });

    unawaited(syncNow());
  }

  Future<void> stop() async {
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _started = false;
  }

  Future<void> syncNow() async {
    if (_syncInProgress) return;

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    _syncInProgress = true;

    try {
      await OfflineMediaService.instance.clearMissingPendingUploads();
      await _syncPendingImageUploads();
    } finally {
      _syncInProgress = false;
    }
  }

  Future<void> _syncPendingImageUploads() async {
    final uploads = await OfflineMediaService.instance.loadPendingUploads();
    if (uploads.isEmpty) return;

    final firestore = FirebaseFirestore.instance;
    final storage = FirebaseStorage.instance;

    for (final item in uploads) {
      try {
        final file = File(item.localPath);
        if (!await file.exists()) {
          await OfflineMediaService.instance.removePendingImageUpload(
            tenantId: item.tenantId,
            productId: item.productId,
          );
          continue;
        }

        final productRef = firestore
            .collection("tenants")
            .doc(item.tenantId)
            .collection("products")
            .doc(item.productId);

        final productSnap = await productRef.get();
        if (!productSnap.exists) {
          await OfflineMediaService.instance.removePendingImageUpload(
            tenantId: item.tenantId,
            productId: item.productId,
          );
          continue;
        }

        final ref = storage.ref().child(item.storagePath);

        final metadata = SettableMetadata(
          contentType: _guessContentTypeFromPath(item.localPath),
        );

        await ref.putFile(file, metadata);
        final downloadUrl = await ref.getDownloadURL();

        await productRef.set({
          "imageUrl": downloadUrl,
          "updatedAt": FieldValue.serverTimestamp(),
          "hasPendingImageUpload": false,
          "localImageSyncedAt": FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        await OfflineMediaService.instance.registerRemoteUrl(
          tenantId: item.tenantId,
          productId: item.productId,
          remoteUrl: downloadUrl,
        );

        await OfflineMediaService.instance.removePendingImageUpload(
          tenantId: item.tenantId,
          productId: item.productId,
        );
      } catch (_) {
        // Keep queued for next reconnect attempt.
      }
    }
  }

  String _guessContentTypeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }
}