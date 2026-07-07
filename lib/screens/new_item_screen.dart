import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/offline_media_service.dart';
import '../services/reconnect_sync_service.dart';
import '../services/tenant_context_service.dart';
import '../widgets/folder_picker.dart';
import '../widgets/top_toast.dart';

class NewItemScreen extends StatefulWidget {
  final String? folderId;
  final String? originalFolderId;
  final XFile? initialImage;

  const NewItemScreen({
    super.key,
    this.folderId,
    this.originalFolderId,
    this.initialImage,
  });

  @override
  State<NewItemScreen> createState() => _NewItemScreenState();
}

enum _NewItemType {
  item,
  tshirt,
  shoes,
}

enum _TshirtSizeGroup {
  adult,
  kids,
}

class _ShoeSizeRow {
  final TextEditingController sizeCtrl;
  final TextEditingController qtyCtrl;

  _ShoeSizeRow()
      : sizeCtrl = TextEditingController(),
        qtyCtrl = TextEditingController(text: '0');

  void dispose() {
    sizeCtrl.dispose();
    qtyCtrl.dispose();
  }
}

class _NewItemScreenState extends State<NewItemScreen> {
  static const List<String> _adultSizes = [
    'XXS',
    'XS',
    'S',
    'M',
    'L',
    'XL',
    '2XL',
    '3XL',
  ];

  static const List<String> _kidsSizes = [
    '1-2',
    '3-4',
    '5-6',
    '7-8',
    '9-10',
    '11-12',
  ];

  static const Color _appColor = Color(0xff0B1E40);

  final TextEditingController codeCtrl = TextEditingController();
  final TextEditingController costCtrl = TextEditingController();
  final TextEditingController wholesaleCtrl = TextEditingController();
  final TextEditingController retailCtrl = TextEditingController();
  final TextEditingController qtyCtrl = TextEditingController();

  late final Map<String, TextEditingController> _sizeCtrls;
  final List<_ShoeSizeRow> _shoeRows = <_ShoeSizeRow>[];

  StreamSubscription<User?>? _authSub;
  Future<_NewItemBootstrapState>? _bootstrapFuture;

  _NewItemType _itemType = _NewItemType.item;
  _TshirtSizeGroup _tshirtSizeGroup = _TshirtSizeGroup.adult;

  bool _saving = false;
  bool _closedAfterSave = false;
  bool _handledSignedOut = false;

  String? selectedFolderId;
  XFile? _pickedImage;

  @override
  void initState() {
    super.initState();

    selectedFolderId = widget.folderId;
    _pickedImage = widget.initialImage;

    _sizeCtrls = {
      for (final s in <String>[..._adultSizes, ..._kidsSizes])
        s: TextEditingController(text: '0'),
    };

    _shoeRows.add(_ShoeSizeRow());

    _bootstrapFuture = _buildBootstrapForCurrentUser();

    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted) return;

      if (user == null) {
        _handledSignedOut = true;
      }

      setState(() {
        _bootstrapFuture = _buildBootstrapForCurrentUser();
      });
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();

    codeCtrl.dispose();
    costCtrl.dispose();
    wholesaleCtrl.dispose();
    retailCtrl.dispose();
    qtyCtrl.dispose();

    for (final c in _sizeCtrls.values) {
      c.dispose();
    }

    for (final row in _shoeRows) {
      row.dispose();
    }

    super.dispose();
  }

  bool _isSignedOut() => FirebaseAuth.instance.currentUser == null;

  bool _isAuthOrPermissionError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains(TenantContextService.kSignedOutMessage.toLowerCase()) ||
        msg.contains('permission-denied') ||
        msg.contains('permission denied') ||
        msg.contains('unauthenticated') ||
        msg.contains('user is not signed in') ||
        msg.contains('requires authentication') ||
        msg.contains('user_signed_out') ||
        msg.contains('user signed out');
  }

  bool _isUnavailableError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('cloud_firestore/unavailable') ||
        msg.contains('service is currently unavailable') ||
        msg.contains('unable to resolve host') ||
        msg.contains('firestore.googleapis.com') ||
        msg.contains('status{code=unavailable') ||
        msg.contains('unknownhostexception') ||
        msg.contains('socketexception') ||
        msg.contains('failed host lookup');
  }

  String _cleanError(Object e) {
    return e.toString().replaceFirst('Exception: ', '').trim();
  }

  void _showErrorToast(String message) {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;
    TopToast.error(context, message);
  }

  Future<_NewItemBootstrapState> _buildBootstrapForCurrentUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const _NewItemBootstrapState.signedOut();
    }

    final tenantContext = TenantContextService();

    try {
      Map<String, dynamic>? profile =
      await tenantContext.tryGetCurrentUserProfileCacheOnly();

      profile ??= await tenantContext.tryGetCurrentUserProfile();

      if (profile == null) {
        return const _NewItemBootstrapState.error(
          message: 'Failed to load your profile.',
        );
      }

      final tenantId = (profile['tenantId'] ?? '').toString().trim();
      if (tenantId.isEmpty) {
        return const _NewItemBootstrapState.missingTenant();
      }

      return _NewItemBootstrapState.ready(tenantId: tenantId);
    } catch (e) {
      if (_isAuthOrPermissionError(e)) {
        return const _NewItemBootstrapState.signedOut();
      }

      return _NewItemBootstrapState.error(
        message:
        _cleanError(e).isEmpty ? 'Failed to load tenant.' : _cleanError(e),
      );
    }
  }

  Widget _imageWidget(XFile file) {
    if (kIsWeb) {
      return FutureBuilder<Uint8List>(
        future: file.readAsBytes(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }

          return Image.memory(
            snap.data!,
            fit: BoxFit.cover,
            width: double.infinity,
          );
        },
      );
    }

    return Image.file(
      File(file.path),
      fit: BoxFit.cover,
      width: double.infinity,
    );
  }

  Widget _imagePreview() {
    return Container(
      height: 180,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(12),
      ),
      child: _pickedImage == null
          ? const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.image, size: 40),
            SizedBox(height: 8),
            Text('No image selected'),
          ],
        ),
      )
          : ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: _imageWidget(_pickedImage!),
      ),
    );
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _tryGetDocCacheThenServer(
      DocumentReference<Map<String, dynamic>> ref,
      ) async {
    try {
      final cached = await ref
          .get(const GetOptions(source: Source.cache))
          .timeout(const Duration(milliseconds: 500));
      if (cached.exists) return cached;
    } catch (_) {}

    try {
      return await ref.get().timeout(const Duration(milliseconds: 1500));
    } catch (_) {}

    return null;
  }

  Future<bool> _hasInternetConnection() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }

  Future<String> _uploadImageAndGetUrl({
    required String tenantId,
    required String productId,
    required XFile image,
  }) async {
    final path = 'tenants/$tenantId/products/$productId/main.jpg';
    final ref = FirebaseStorage.instance.ref().child(path);

    if (kIsWeb) {
      final bytes = await image.readAsBytes();
      await ref.putData(
        bytes,
        SettableMetadata(contentType: 'image/jpeg'),
      );
    } else {
      await ref.putFile(
        File(image.path),
        SettableMetadata(contentType: 'image/jpeg'),
      );
    }

    return ref.getDownloadURL();
  }

  Future<File?> _saveOfflineLocalImage({
    required String tenantId,
    required String productId,
    required XFile image,
  }) async {
    if (kIsWeb) return null;

    return OfflineMediaService.instance.saveImageFileForProduct(
      tenantId: tenantId,
      productId: productId,
      sourceFile: File(image.path),
      extension: 'jpg',
    );
  }

  List<String> get _activeTshirtSizes {
    return _tshirtSizeGroup == _TshirtSizeGroup.adult ? _adultSizes : _kidsSizes;
  }

  int _totalTshirtSizeQty() {
    int total = 0;
    for (final s in _activeTshirtSizes) {
      total += int.tryParse(_sizeCtrls[s]!.text.trim()) ?? 0;
    }
    return total;
  }

  int _totalShoeQty() {
    int total = 0;
    for (final row in _shoeRows) {
      total += int.tryParse(row.qtyCtrl.text.trim()) ?? 0;
    }
    return total;
  }

  double _parseDouble(TextEditingController c) {
    final raw = c.text.trim().replaceAll(',', '.');
    return double.tryParse(raw) ?? 0;
  }

  Future<Map<String, String>> _getCurrentUserInfo(String uid) async {
    try {
      final userSnap = await _tryGetDocCacheThenServer(
        FirebaseFirestore.instance.collection('users').doc(uid),
      );
      final data = userSnap?.data() ?? <String, dynamic>{};

      return {
        'name': (data['name'] ?? '').toString().trim(),
        'email': (data['email'] ?? '').toString().trim(),
      };
    } catch (_) {
      return {'name': '', 'email': ''};
    }
  }

  Future<void> _afterSaveImageSync({
    required String tenantId,
    required String productId,
    required XFile image,
  }) async {
    try {
      final hasInternet = await _hasInternetConnection();

      if (!hasInternet) {
        if (!kIsWeb) {
          final localFile = await OfflineMediaService.instance.getLocalImageFile(
            tenantId: tenantId,
            productId: productId,
          );

          if (localFile != null) {
            await OfflineMediaService.instance.enqueuePendingImageUpload(
              tenantId: tenantId,
              productId: productId,
              localPath: localFile.path,
              storagePath: 'tenants/$tenantId/products/$productId/main.jpg',
            );
          }
        }

        unawaited(ReconnectSyncService.instance.syncNow());
        return;
      }

      final imageUrl = await _uploadImageAndGetUrl(
        tenantId: tenantId,
        productId: productId,
        image: image,
      );

      await FirebaseFirestore.instance
          .collection('tenants')
          .doc(tenantId)
          .collection('products')
          .doc(productId)
          .set({
        'imageUrl': imageUrl,
        'hasPendingImageUpload': false,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Image sync failed for $productId: $e');

      if (!kIsWeb) {
        try {
          final localFile = await OfflineMediaService.instance.getLocalImageFile(
            tenantId: tenantId,
            productId: productId,
          );

          if (localFile != null) {
            await OfflineMediaService.instance.enqueuePendingImageUpload(
              tenantId: tenantId,
              productId: productId,
              localPath: localFile.path,
              storagePath: 'tenants/$tenantId/products/$productId/main.jpg',
            );
          }
        } catch (queueError) {
          debugPrint('Queue pending image upload failed: $queueError');
        }
      }

      try {
        await FirebaseFirestore.instance
            .collection('tenants')
            .doc(tenantId)
            .collection('products')
            .doc(productId)
            .set({
          'hasPendingImageUpload': true,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (firestoreError) {
        debugPrint('Mark pending upload failed: $firestoreError');
      }

      unawaited(ReconnectSyncService.instance.syncNow());
    }
  }

  Future<_CreateItemData?> _validateAndBuildCreateData() async {
    final code = codeCtrl.text.trim();
    final folderId = selectedFolderId?.trim();

    if (code.isEmpty || folderId == null || folderId.isEmpty) {
      _showErrorToast('Enter code and select folder.');
      return null;
    }

    if (_pickedImage == null) {
      _showErrorToast('Please select an image.');
      return null;
    }

    int initialStock = 0;
    Map<String, int>? sizeStock;
    Map<String, int>? sizeDelta;
    String? sizeGroup;

    if (_itemType == _NewItemType.item) {
      final q = int.tryParse(qtyCtrl.text.trim()) ?? 0;
      if (q <= 0) {
        _showErrorToast('Quantity must be greater than 0.');
        return null;
      }
      initialStock = q;
    } else if (_itemType == _NewItemType.tshirt) {
      final parsed = <String, int>{};
      bool anyPositive = false;
      bool anyInvalid = false;

      for (final s in _activeTshirtSizes) {
        final raw = _sizeCtrls[s]!.text.trim();
        final n = raw.isEmpty ? 0 : (int.tryParse(raw) ?? -1);

        if (n < 0) {
          anyInvalid = true;
        }

        final safeValue = n < 0 ? 0 : n;
        parsed[s] = safeValue;

        if (safeValue > 0) {
          anyPositive = true;
        }
      }

      if (anyInvalid) {
        _showErrorToast('Size quantities must be valid whole numbers.');
        return null;
      }

      if (!anyPositive) {
        _showErrorToast('Enter at least one size quantity greater than 0.');
        return null;
      }

      sizeGroup = _tshirtSizeGroup == _TshirtSizeGroup.adult ? 'adult' : 'kids';
      sizeStock = parsed;
      initialStock = parsed.values.fold<int>(0, (a, b) => a + b);
      sizeDelta = {
        for (final s in _activeTshirtSizes) s: parsed[s] ?? 0,
      };
    } else {
      final parsed = <String, int>{};
      bool anyPositive = false;
      bool anyInvalid = false;
      bool anyMissingSize = false;
      bool anyDuplicateSize = false;
      final seenSizes = <String>{};

      for (final row in _shoeRows) {
        final size = row.sizeCtrl.text.trim();
        final rawQty = row.qtyCtrl.text.trim();
        final qty = rawQty.isEmpty ? 0 : (int.tryParse(rawQty) ?? -1);

        if (size.isEmpty && qty <= 0) {
          continue;
        }

        if (size.isEmpty && qty > 0) {
          anyMissingSize = true;
          continue;
        }

        if (qty < 0) {
          anyInvalid = true;
          continue;
        }

        final normalizedSize = size.toLowerCase();
        if (seenSizes.contains(normalizedSize)) {
          anyDuplicateSize = true;
        }
        seenSizes.add(normalizedSize);

        parsed[size] = qty;

        if (qty > 0) {
          anyPositive = true;
        }
      }

      if (anyMissingSize) {
        _showErrorToast('Enter a size for every shoe quantity.');
        return null;
      }

      if (anyInvalid) {
        _showErrorToast('Shoe quantities must be valid whole numbers.');
        return null;
      }

      if (anyDuplicateSize) {
        _showErrorToast('Each shoe size can only be added once.');
        return null;
      }

      if (!anyPositive) {
        _showErrorToast('Enter at least one shoe size quantity greater than 0.');
        return null;
      }

      sizeStock = parsed;
      initialStock = parsed.values.fold<int>(0, (a, b) => a + b);
      sizeDelta = Map<String, int>.from(parsed);
    }

    return _CreateItemData(
      code: code,
      folderId: folderId,
      image: _pickedImage!,
      initialStock: initialStock,
      sizeStock: sizeStock,
      sizeDelta: sizeDelta,
      costPrice: _parseDouble(costCtrl),
      wholesalePrice: _parseDouble(wholesaleCtrl),
      retailPrice: _parseDouble(retailCtrl),
      itemType: _itemType.name,
      isTshirt: _itemType == _NewItemType.tshirt,
      sizeGroup: sizeGroup,
    );
  }

  Future<void> createItem(String tenantId) async {
    if (_saving || _closedAfterSave) return;
    if (_isSignedOut() || _handledSignedOut) return;

    FocusScope.of(context).unfocus();

    final prepared = await _validateAndBuildCreateData();
    if (prepared == null) return;

    if (!mounted) return;
    setState(() => _saving = true);

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
      if (uid.isEmpty) {
        throw Exception('You are signed out. Please sign in again.');
      }

      final fs = FirebaseFirestore.instance;
      final userInfo = await _getCurrentUserInfo(uid);
      final userName = userInfo['name']!.isEmpty ? '' : userInfo['name']!;

      final productRef = fs
          .collection('tenants')
          .doc(tenantId)
          .collection('products')
          .doc();

      final productId = productRef.id;

      if (!kIsWeb) {
        await _saveOfflineLocalImage(
          tenantId: tenantId,
          productId: productId,
          image: prepared.image,
        );
      }

      final now = DateTime.now();
      final nowYear = now.year;

      final Map<String, dynamic> productData = {
        'code': prepared.code,
        'minStockLevel': 5,
        'imageUrl': '',
        'folderId': prepared.folderId,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': uid,
        'createdByName': userName,
        'updatedAt': FieldValue.serverTimestamp(),
        'itemType': prepared.itemType,
        'isTshirt': prepared.isTshirt,
        if (prepared.sizeGroup != null) 'sizeGroup': prepared.sizeGroup,
        'stockQuantity': prepared.initialStock,
        'hasPendingImageUpload': true,
        if (prepared.sizeStock != null) 'sizeStock': prepared.sizeStock,
      };

      final batch = fs.batch();

      batch.set(productRef, productData);

      batch.set(
        productRef.collection('prices').doc('cost'),
        {
          'costPrice': prepared.costPrice,
          'updatedAt': FieldValue.serverTimestamp(),
        },
      );

      batch.set(
        productRef.collection('prices').doc('wholesale'),
        {
          'wholesalePrice': prepared.wholesalePrice,
          'updatedAt': FieldValue.serverTimestamp(),
        },
      );

      batch.set(
        productRef.collection('prices').doc('retail'),
        {
          'retailPrice': prepared.retailPrice,
          'updatedAt': FieldValue.serverTimestamp(),
        },
      );

      batch.set(
        productRef.collection('stock_years').doc(nowYear.toString()),
        {
          'year': nowYear,
          'initialStock': prepared.initialStock,
          'currentStock': prepared.initialStock,
          if (prepared.sizeStock != null) 'currentSizeStock': prepared.sizeStock,
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': uid,
          'createdByName': userName,
          'updatedAt': FieldValue.serverTimestamp(),
        },
      );

      final movementRef = productRef.collection('stock_movements').doc();
      batch.set(
        movementRef,
        {
          'type': 'add',
          'delta': prepared.initialStock,
          'year': nowYear,
          'at': FieldValue.serverTimestamp(),
          'by': uid,
          'byName': userName,
          'note': 'Initial stock on item creation',
          if (prepared.sizeDelta != null) 'sizeDelta': prepared.sizeDelta,
        },
      );

      final tenantIdForSync = tenantId;
      final productIdForSync = productId;
      final pickedImageForSync = prepared.image;

      final batchFuture = batch.commit();

      _closedAfterSave = true;

      if (mounted) {
        Navigator.of(context).pop(true);
      }

      unawaited(
        batchFuture.then((_) {
          return _afterSaveImageSync(
            tenantId: tenantIdForSync,
            productId: productIdForSync,
            image: pickedImageForSync,
          );
        }).catchError((e) {
          debugPrint('Create item failed after pop: $e');
        }),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() => _saving = false);

      if (_isAuthOrPermissionError(e)) {
        _showErrorToast('You are signed out or do not have permission.');
        return;
      }

      if (_isUnavailableError(e)) {
        _showErrorToast(
          'Firestore is currently unavailable. Try again when the connection is restored.',
        );
        return;
      }

      _showErrorToast('Failed to save item: ${_cleanError(e)}');
    }
  }

  Widget _sizeStockTableEditor() {
    final activeSizes = _activeTshirtSizes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Size Quantities',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final int columnCount = activeSizes.length <= 6 ? 4 : 4;
            final double cellWidth =
                (constraints.maxWidth - (8 * (columnCount - 1))) / columnCount;

            return Wrap(
              spacing: 8,
              runSpacing: 10,
              children: activeSizes.map((s) {
                final ctrl = _sizeCtrls[s]!;
                return SizedBox(
                  width: cellWidth.clamp(62.0, 105.0).toDouble(),
                  child: Column(
                    children: [
                      Text(
                        s,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: ctrl,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(),
                        ),
                        style: const TextStyle(fontSize: 13),
                        onTap: () {
                          if (ctrl.text.trim() == '0') {
                            ctrl.clear();
                          }
                        },
                        onChanged: (_) {
                          if (mounted) setState(() {});
                        },
                        onEditingComplete: () {
                          if (ctrl.text.trim().isEmpty) {
                            ctrl.text = '0';
                          }
                          FocusScope.of(context).unfocus();
                          if (mounted) setState(() {});
                        },
                        onTapOutside: (_) {
                          if (ctrl.text.trim().isEmpty) {
                            ctrl.text = '0';
                          }
                          if (mounted) setState(() {});
                        },
                      ),
                    ],
                  ),
                );
              }).toList(),
            );
          },
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Total: ${_totalTshirtSizeQty()}',
            style: TextStyle(color: Colors.grey.shade700),
          ),
        ),
      ],
    );
  }

  Widget _tshirtAdultKidsToggle() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        const Text(
          'Size Type',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        SegmentedButton<_TshirtSizeGroup>(
          segments: const [
            ButtonSegment<_TshirtSizeGroup>(
              value: _TshirtSizeGroup.adult,
              label: Text('Adult'),
            ),
            ButtonSegment<_TshirtSizeGroup>(
              value: _TshirtSizeGroup.kids,
              label: Text('Kids'),
            ),
          ],
          selected: {_tshirtSizeGroup},
          onSelectionChanged: (selection) {
            if (!mounted || selection.isEmpty) return;
            setState(() => _tshirtSizeGroup = selection.first);
          },
        ),
      ],
    );
  }

  Widget _shoeSizeTableEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        const Text(
          'Shoe Sizes',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Row(
          children: const [
            Expanded(
              flex: 2,
              child: Text(
                'Size',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: Text(
                'Qty',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            SizedBox(width: 42),
          ],
        ),
        const SizedBox(height: 6),
        ...List.generate(_shoeRows.length, (index) {
          final row = _shoeRows[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: row.sizeCtrl,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'e.g. 38',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: row.qtyCtrl,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onTap: () {
                      if (row.qtyCtrl.text.trim() == '0') {
                        row.qtyCtrl.clear();
                      }
                    },
                    onChanged: (_) {
                      if (mounted) setState(() {});
                    },
                    onEditingComplete: () {
                      if (row.qtyCtrl.text.trim().isEmpty) {
                        row.qtyCtrl.text = '0';
                      }
                      FocusScope.of(context).unfocus();
                      if (mounted) setState(() {});
                    },
                    onTapOutside: (_) {
                      if (row.qtyCtrl.text.trim().isEmpty) {
                        row.qtyCtrl.text = '0';
                      }
                      if (mounted) setState(() {});
                    },
                  ),
                ),
                SizedBox(
                  width: 42,
                  child: IconButton(
                    tooltip: 'Remove size',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _shoeRows.length == 1
                        ? null
                        : () {
                      final removed = _shoeRows.removeAt(index);
                      removed.dispose();
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ],
            ),
          );
        }),
        TextButton.icon(
          onPressed: () {
            setState(() => _shoeRows.add(_ShoeSizeRow()));
          },
          icon: const Icon(Icons.add),
          label: const Text('Add size'),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Total: ${_totalShoeQty()}',
            style: TextStyle(color: Colors.grey.shade700),
          ),
        ),
      ],
    );
  }

  Widget _itemTypeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Item Type',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade700,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          runSpacing: 0,
          children: [
            SizedBox(
              width: 130,
              child: RadioListTile<_NewItemType>(
                value: _NewItemType.item,
                groupValue: _itemType,
                onChanged: (v) {
                  if (!mounted || v == null) return;
                  setState(() => _itemType = v);
                },
                title: const Text('Item'),
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            SizedBox(
              width: 145,
              child: RadioListTile<_NewItemType>(
                value: _NewItemType.tshirt,
                groupValue: _itemType,
                onChanged: (v) {
                  if (!mounted || v == null) return;
                  setState(() => _itemType = v);
                },
                title: const Text('T-Shirt'),
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            SizedBox(
              width: 130,
              child: RadioListTile<_NewItemType>(
                value: _NewItemType.shoes,
                groupValue: _itemType,
                onChanged: (v) {
                  if (!mounted || v == null) return;
                  setState(() => _itemType = v);
                },
                title: const Text('Shoes'),
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _stockInputSection(String tenantId) {
    if (_itemType == _NewItemType.item) {
      return TextField(
        controller: qtyCtrl,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(labelText: 'Quantity'),
        onSubmitted: (_) => createItem(tenantId),
      );
    }

    if (_itemType == _NewItemType.tshirt) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _tshirtAdultKidsToggle(),
          _sizeStockTableEditor(),
        ],
      );
    }

    return _shoeSizeTableEditor();
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: const Text(
        'Add Item',
        style: TextStyle(color: Colors.white),
      ),
      backgroundColor: _appColor,
      iconTheme: const IconThemeData(color: Colors.white),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
      ),
    );
  }

  Widget _buildCenteredMessage({
    required String message,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[
              const SizedBox(height: 16),
              action,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildForm(String tenantId) {
    return Scaffold(
      appBar: _buildAppBar(),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: AbsorbPointer(
            absorbing: _saving,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _imagePreview(),
                const SizedBox(height: 20),
                const Text(
                  'Select Folder',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                FolderPicker(
                  tenantId: tenantId,
                  preselectedFolder: selectedFolderId,
                  allowTopLevel: false,
                  onFolderSelected: (id) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      setState(() => selectedFolderId = id);
                    });
                  },
                ),
                const SizedBox(height: 25),
                TextField(
                  controller: codeCtrl,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: 'Item Code'),
                ),
                TextField(
                  controller: costCtrl,
                  textInputAction: TextInputAction.next,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Cost Price'),
                ),
                TextField(
                  controller: wholesaleCtrl,
                  textInputAction: TextInputAction.next,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Wholesale Price'),
                ),
                TextField(
                  controller: retailCtrl,
                  textInputAction: TextInputAction.next,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Retail Price'),
                ),
                const SizedBox(height: 10),
                _itemTypeSelector(),
                _stockInputSection(tenantId),
                const SizedBox(height: 25),
                ElevatedButton(
                  onPressed: _saving ? null : () => createItem(tenantId),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _appColor,
                    minimumSize: const Size(double.infinity, 50),
                  ),
                  child: _saving
                      ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                      : const Text('Save Item'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final future = _bootstrapFuture ?? _buildBootstrapForCurrentUser();

    return FutureBuilder<_NewItemBootstrapState>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Scaffold(
            appBar: _buildAppBar(),
            body: const Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        final state = snapshot.data ??
            const _NewItemBootstrapState.error(
              message: 'Failed to load tenant.',
            );

        if (state.isSignedOut) {
          return Scaffold(
            appBar: _buildAppBar(),
            body: _buildCenteredMessage(
              message: 'You are signed out. Please sign in again.',
            ),
          );
        }

        if (state.isMissingTenant) {
          return Scaffold(
            appBar: _buildAppBar(),
            body: _buildCenteredMessage(
              message: 'Your account is not assigned to a tenant yet.',
            ),
          );
        }

        if (!state.isReady) {
          return Scaffold(
            appBar: _buildAppBar(),
            body: _buildCenteredMessage(
              message: state.message ?? 'Failed to load tenant.',
              action: ElevatedButton(
                onPressed: () {
                  if (!mounted) return;
                  setState(() {
                    _bootstrapFuture = _buildBootstrapForCurrentUser();
                  });
                },
                child: const Text('Retry'),
              ),
            ),
          );
        }

        return _buildForm(state.tenantId!);
      },
    );
  }
}

class _NewItemBootstrapState {
  final String? tenantId;
  final bool isSignedOut;
  final bool isMissingTenant;
  final String? message;

  const _NewItemBootstrapState._({
    required this.tenantId,
    required this.isSignedOut,
    required this.isMissingTenant,
    required this.message,
  });

  const _NewItemBootstrapState.ready({
    required String tenantId,
  }) : this._(
    tenantId: tenantId,
    isSignedOut: false,
    isMissingTenant: false,
    message: null,
  );

  const _NewItemBootstrapState.signedOut()
      : this._(
    tenantId: null,
    isSignedOut: true,
    isMissingTenant: false,
    message: null,
  );

  const _NewItemBootstrapState.missingTenant()
      : this._(
    tenantId: null,
    isSignedOut: false,
    isMissingTenant: true,
    message: null,
  );

  const _NewItemBootstrapState.error({
    required String message,
  }) : this._(
    tenantId: null,
    isSignedOut: false,
    isMissingTenant: false,
    message: message,
  );

  bool get isReady => tenantId != null && tenantId!.trim().isNotEmpty;
}

class _CreateItemData {
  final String code;
  final String folderId;
  final XFile image;
  final int initialStock;
  final Map<String, int>? sizeStock;
  final Map<String, int>? sizeDelta;
  final double costPrice;
  final double wholesalePrice;
  final double retailPrice;
  final String itemType;
  final bool isTshirt;
  final String? sizeGroup;

  const _CreateItemData({
    required this.code,
    required this.folderId,
    required this.image,
    required this.initialStock,
    required this.sizeStock,
    required this.sizeDelta,
    required this.costPrice,
    required this.wholesalePrice,
    required this.retailPrice,
    required this.itemType,
    required this.isTshirt,
    required this.sizeGroup,
  });
}