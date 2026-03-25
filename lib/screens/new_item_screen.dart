//add new
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

class _NewItemScreenState extends State<NewItemScreen> {
  static const List<String> _sizes = [
    "XXS", "XS", "S", "M",
    "L", "XL", "2XL", "3XL",
  ];

  final TextEditingController codeCtrl = TextEditingController();
  final TextEditingController costCtrl = TextEditingController();
  final TextEditingController wholesaleCtrl = TextEditingController();
  final TextEditingController retailCtrl = TextEditingController();
  final TextEditingController qtyCtrl = TextEditingController();

  late final Map<String, TextEditingController> _sizeCtrls;

  StreamSubscription<User?>? _authSub;
  Future<_NewItemBootstrapState>? _bootstrapFuture;

  bool _isTshirt = false; //switches UI logic
  bool _saving = false; //disable UI while saving
  bool _closedAfterSave = false; //prevents duplicate saves
  bool _handledSignedOut = false; //prevent UI errors after logout

  //image and folder
  String? selectedFolderId;
  XFile? _pickedImage;

  @override
  void initState() {
    super.initState();

    selectedFolderId = widget.folderId;
    _pickedImage = widget.initialImage;

    _sizeCtrls = {
      for (final s in _sizes) s: TextEditingController(text: '0'),
    };

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

    super.dispose();
  }

  bool _isSignedOut() => FirebaseAuth.instance.currentUser == null;

  bool _isAuthOrPermissionError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains(TenantContextService.kSignedOutMessage.toLowerCase()) ||
        msg.contains("permission-denied") ||
        msg.contains("permission denied") ||
        msg.contains("unauthenticated") ||
        msg.contains("user is not signed in") ||
        msg.contains("requires authentication") ||
        msg.contains("user_signed_out") ||
        msg.contains("user signed out");
  }

  bool _isUnavailableError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains("cloud_firestore/unavailable") ||
        msg.contains("service is currently unavailable") ||
        msg.contains("unable to resolve host") ||
        msg.contains("firestore.googleapis.com") ||
        msg.contains("status{code=unavailable") ||
        msg.contains("unknownhostexception") ||
        msg.contains("socketexception") ||
        msg.contains("failed host lookup");
  }

  String _cleanError(Object e) {
    return e.toString().replaceFirst('Exception: ', '').trim();
  }

  void _showErrorToast(String message) {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;
    TopToast.error(context, message);
  }

  //startup loader
  Future<_NewItemBootstrapState> _buildBootstrapForCurrentUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const _NewItemBootstrapState.signedOut();
    }

    final tenantContext = TenantContextService();

    //load profile first try cache and then server
    try {
      Map<String, dynamic>? profile =
      await tenantContext.tryGetCurrentUserProfileCacheOnly();

      profile ??= await tenantContext.tryGetCurrentUserProfile();

      if (profile == null) {
        return const _NewItemBootstrapState.error(
          message: "Failed to load your profile.",
        );
      }

      final tenantId = (profile["tenantId"] ?? "").toString().trim();
      if (tenantId.isEmpty) {
        return const _NewItemBootstrapState.missingTenant();
      }

      return _NewItemBootstrapState.ready(tenantId: tenantId);
    } catch (e) {
      if (_isAuthOrPermissionError(e)) {
        return const _NewItemBootstrapState.signedOut();
      }

      return _NewItemBootstrapState.error(
        message: _cleanError(e).isEmpty
            ? "Failed to load tenant."
            : _cleanError(e),
      );
    }
  }

  //web branch
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

    //mobile brunch
    return Image.file(
      File(file.path),
      fit: BoxFit.cover,
      width: double.infinity,
    );
  }

  //build the visual preview box
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

  //uploads image to firebase storage and returns public download URL
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

  int _totalSizeQty() {
    int total = 0;
    for (final s in _sizes) {
      total += int.tryParse(_sizeCtrls[s]!.text.trim()) ?? 0;
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
        FirebaseFirestore.instance.collection("users").doc(uid),
      );
      final data = userSnap?.data() ?? <String, dynamic>{};

      return {
        "name": (data["name"] ?? "").toString().trim(),
        "email": (data["email"] ?? "").toString().trim(),
      };
    } catch (_) {
      return {"name": "", "email": ""};
    }
  }

  //runs after the product batch has been committed to finish image syncing
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

    if (!_isTshirt) {
      final q = int.tryParse(qtyCtrl.text.trim()) ?? 0;
      if (q <= 0) {
        _showErrorToast('Quantity must be greater than 0.');
        return null;
      }
      initialStock = q;
    } else {
      final parsed = <String, int>{};
      bool anyPositive = false;
      bool anyInvalid = false;

      for (final s in _sizes) {
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

      sizeStock = parsed;
      initialStock = parsed.values.fold<int>(0, (a, b) => a + b);
      sizeDelta = {
        for (final s in _sizes) s: parsed[s] ?? 0,
      };
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
      isTshirt: _isTshirt,
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
      final userName = userInfo["name"]!.isEmpty ? "" : userInfo["name"]!;

      //generates a new firestore doc with auto ID
      final productRef = fs
          .collection('tenants')
          .doc(tenantId)
          .collection('products')
          .doc();

      final productId = productRef.id;

      //save image locally
      if (!kIsWeb) {
        await _saveOfflineLocalImage(
          tenantId: tenantId,
          productId: productId,
          image: prepared.image,
        );
      }

      final now = DateTime.now();
      final nowYear = now.year;

      //build product data
      final Map<String, dynamic> productData = {
        'code': prepared.code,
        'minStockLevel': 5,
        'imageUrl': '',
        'folderId': prepared.folderId,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': uid,
        'createdByName': userName,
        'updatedAt': FieldValue.serverTimestamp(),
        'isTshirt': prepared.isTshirt,
        'stockQuantity': prepared.initialStock,
        'hasPendingImageUpload': true,
        if (prepared.isTshirt) 'sizeStock': prepared.sizeStock,
      };

      final batch = fs.batch();

      batch.set(productRef, productData);

      //prices sub collection
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

      //stock year document
      batch.set(
        productRef.collection('stock_years').doc(nowYear.toString()),
        {
          'year': nowYear,
          'initialStock': prepared.initialStock,
          'currentStock': prepared.initialStock,
          if (prepared.isTshirt) 'currentSizeStock': prepared.sizeStock,
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': uid,
          'createdByName': userName,
          'updatedAt': FieldValue.serverTimestamp(),
        },
      );

      //stock movement document
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
          if (prepared.isTshirt) 'sizeDelta': prepared.sizeDelta,
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

      //continue in background the saving
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
            final double cellWidth = (constraints.maxWidth - (8 * 3)) / 4;

            return Wrap(
              spacing: 8,
              runSpacing: 10,
              children: _sizes.map((s) {
                final ctrl = _sizeCtrls[s]!;
                return SizedBox(
                  width: cellWidth.clamp(62.0, 90.0),
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
            'Total: ${_totalSizeQty()}',
            style: TextStyle(color: Colors.grey.shade700),
          ),
        ),
      ],
    );
  }

  //build the radio button for item type
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
        Row(
          children: [
            Expanded(
              child: RadioListTile<bool>(
                value: false,
                groupValue: _isTshirt,
                onChanged: (v) {
                  if (!mounted) return;
                  setState(() => _isTshirt = v ?? false);
                },
                title: const Text('Normal item'),
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            Expanded(
              child: RadioListTile<bool>(
                value: true,
                groupValue: _isTshirt,
                onChanged: (v) {
                  if (!mounted) return;
                  setState(() => _isTshirt = v ?? true);
                },
                title: const Text('T-Shirt'),
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

  AppBar _buildAppBar() {
    return AppBar(
      title: const Text(
        'Add Item',
        style: TextStyle(color: Colors.white),
      ),
      backgroundColor: const Color(0xff0B1E40),
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
          padding: EdgeInsets.fromLTRB( 20, 20, 20,
            20 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: AbsorbPointer( //the form becomes non-interactive
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
                  decoration:
                  const InputDecoration(labelText: 'Wholesale Price'),
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
                if (!_isTshirt)
                  TextField(
                    controller: qtyCtrl,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(labelText: 'Quantity'),
                    onSubmitted: (_) => createItem(tenantId),
                  )
                else
                  _sizeStockTableEditor(),
                const SizedBox(height: 25),
                ElevatedButton(
                  onPressed: _saving ? null : () => createItem(tenantId),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xff0B1E40),
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

//state model for startup and loading status
class _NewItemBootstrapState {
  //fields
  final String? tenantId;
  final bool isSignedOut;
  final bool isMissingTenant;
  final String? message;

  //private constructor
  const _NewItemBootstrapState._({
    required this.tenantId,
    required this.isSignedOut,
    required this.isMissingTenant,
    required this.message,
  });

  //ready state
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

  //getter
  bool get isReady => tenantId != null && tenantId!.trim().isNotEmpty;
}

//hold already validated form data
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
  final bool isTshirt;

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
    required this.isTshirt,
  });
}