//show item data
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/offline_media_service.dart';
import '../services/out_of_stock_service.dart';
import '../services/tenant_context_service.dart';
import '../widgets/folder_picker.dart';
import '../widgets/offline_image_widget.dart';
import '../widgets/top_toast.dart';
import 'stock_history_screen.dart';

class ItemDetailsScreen extends StatefulWidget {
  final String itemId;
  final VoidCallback? onItemMissing;

  const ItemDetailsScreen({
    super.key,
    required this.itemId,
    this.onItemMissing,
  });

  @override
  State<ItemDetailsScreen> createState() => ItemDetailsScreenState();
}

class ItemDetailsScreenState extends State<ItemDetailsScreen> {
  //size list
  static const List<String> _sizes = [
    "XXS", "XS", "S", "M",
    "L", "XL", "2XL", "3XL",
  ];

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TenantContextService _tenantContext = TenantContextService();

  //state variables
  StreamSubscription<User?>? _authSub;
  Future<_BootstrapData?>? _bootstrapFuture;
  String? _currentUid;
  bool _missingHandled = false;
  String? _lastPrefetchedImageUrl;

  @override
  void initState() {
    super.initState();
    _syncWithCurrentAuth();
    _listenToAuthChanges();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  void _listenToAuthChanges() {
    _authSub?.cancel();
    _authSub = _auth.authStateChanges().listen((_) {
      _syncWithCurrentAuth();
    });
  }

  void _syncWithCurrentAuth() {
    //gets current user ID
    final uid = _auth.currentUser?.uid.trim();

    //user is signed out - reset the state and screen shows nothing
    if (uid == null || uid.isEmpty) {
      _currentUid = null;
      _bootstrapFuture = Future<_BootstrapData?>.value(null);
      if (mounted) {
        setState(() {});
      }
      return;
    }

    //avoid rebuilding unnecessary
    if (_currentUid == uid && _bootstrapFuture != null) return;

    _currentUid = uid;
    _bootstrapFuture = _bootstrapForUid(uid);

    if (mounted) {
      setState(() {});
    }
  }

  Future<_BootstrapData?> _bootstrapForUid(String uid) async {
    try {
      //cache first then fetch
      Map<String, dynamic>? profile =
      await _tenantContext.tryGetCurrentUserProfileCacheOnly();

      profile ??= await _tenantContext.getCurrentUserProfile();

      //extract values
      final tenantId = (profile["tenantId"] ?? "").toString().trim();
      final role = (profile["role"] ?? "staff").toString().trim();
      final userName = (profile["name"] ?? "").toString().trim();

      //validate tenant
      if (tenantId.isEmpty) {
        throw Exception("User is not assigned to a tenant.");
      }

      return _BootstrapData(
        uid: uid,
        tenantId: tenantId,
        role: role.isEmpty ? "staff" : role,
        userName: userName.isEmpty ? "Unknown" : userName,
      );
    } catch (e) {
      if (_isSignedOutError(e)) {
        return null;
      }
      rethrow;
    }
  }

  //role helpers
  bool _isAdmin(String role) => role == "admin";
  bool _canSeeRetail(String role) =>
      ["admin", "manager", "accountant", "staff"].contains(role);
  bool _canSeeWholesale(String role) =>
      ["admin", "accountant", "reseller"].contains(role);
  bool _canSeeCost(String role) => role == "admin";

  //error helpers
  bool _isSignedOutError(Object error) {
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
        msg.contains("unknownhostexception");
  }

  //make errors clean for the user to read
  String _cleanErr(Object e) =>
      e.toString().replaceFirst("Exception: ", "").trim();

  //number conversion helpers
  int _numToInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? "") ?? 0;
  }

  double _numToDouble(dynamic v) {
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? "") ?? 0;
  }

  //toast helpers
  void _toastSuccess(String msg) {
    if (!mounted) return;
    TopToast.success(context, msg);
  }

  void _toastError(String msg) {
    if (!mounted) return;
    TopToast.error(context, msg);
  }

  void _toastInfo(String msg) {
    if (!mounted) return;
    TopToast.info(context, msg);
  }

  //safe pop helpers
  void _safePop(BuildContext ctx, [dynamic result]) {
    if (!ctx.mounted) return;

    FocusManager.instance.primaryFocus?.unfocus();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ctx.mounted) return;
      final navigator = Navigator.of(ctx);
      if (navigator.canPop()) {
        navigator.pop(result);
      }
    });
  }

  //cache and server document fetch
  Future<DocumentSnapshot<Map<String, dynamic>>?> _tryGetDocCacheThenServer(
      DocumentReference<Map<String, dynamic>> ref, {
        Duration cacheTimeout = const Duration(milliseconds: 500),
        Duration serverTimeout = const Duration(milliseconds: 1200),
      }) async {
    try {
      //cache first
      return await ref
          .get(const GetOptions(source: Source.cache))
          .timeout(cacheTimeout);
    } catch (_) {}

    try {
      //server if cache fail
      return await ref.get().timeout(serverTimeout);
    } catch (_) {}

    return null; //both fail
  }

  CollectionReference<Map<String, dynamic>> _tenantProductsCol(String tenantId) {
    return _firestore.collection("tenants").doc(tenantId).collection("products");
  }

  CollectionReference<Map<String, dynamic>> _tenantMovementHistoryCol(
      String tenantId,
      ) {
    return _firestore
        .collection("tenants")
        .doc(tenantId)
        .collection("movement_history");
  }

  //folder path builder
  Future<List<String>> _buildFolderPathNames(
      String tenantId,
      String? folderId,
      ) async {
    if (folderId == null || folderId.trim().isEmpty) return [];

    final names = <String>[];
    String? currentId = folderId;

    while (currentId != null && currentId.trim().isNotEmpty) {
      final snap = await _tryGetDocCacheThenServer(
        _firestore
            .collection("tenants")
            .doc(tenantId)
            .collection("folders")
            .doc(currentId),
      );

      if (snap == null || !snap.exists) break;

      final data = snap.data() ?? <String, dynamic>{};
      final name = (data["name"] ?? "").toString().trim();
      if (name.isNotEmpty) {
        names.add(name);
      }

      final parentIdRaw = data["parentId"];
      final parentId = parentIdRaw?.toString().trim();
      currentId = (parentId == null || parentId.isEmpty) ? null : parentId;
    }

    return names.reversed.toList();
  }

  //gather everything needed for item actions
  Future<_ActionContext> _getActionContext() async {
    final user = _auth.currentUser;
    if (user == null || user.uid.trim().isEmpty) {
      throw Exception("Not signed in.");
    }

    final bootstrap = await _bootstrapFuture;
    if (bootstrap == null) {
      throw Exception("Not signed in.");
    }

    final docRef = _tenantProductsCol(bootstrap.tenantId).doc(widget.itemId);

    return _ActionContext(
      tenantId: bootstrap.tenantId,
      uid: bootstrap.uid,
      userName: bootstrap.userName,
      role: bootstrap.role,
      docRef: docRef,
      retailRef: docRef.collection("prices").doc("retail"),
      wholesaleRef: docRef.collection("prices").doc("wholesale"),
      costRef: docRef.collection("prices").doc("cost"),
    );
  }

  //download product images for offline use
  Future<void> _prefetchImageIfNeeded({
    required String tenantId,
    required String imageUrl,
  }) async {
    final trimmed = imageUrl.trim();
    if (trimmed.isEmpty) return;
    //avoid repeated download
    if (_lastPrefetchedImageUrl == trimmed) return;

    _lastPrefetchedImageUrl = trimmed;

    try {
      await OfflineMediaService.instance.ensureOfflineImage(
        tenantId: tenantId,
        productId: widget.itemId,
        imageUrl: trimmed,
      );
    } catch (_) {}
  }

  //public action entry methods
  Future<void> openAddStockDialog() async {
    try {
      final ctx = await _getActionContext();
      final draft = await _prepareAddStockDialogData(docRef: ctx.docRef);
      if (!mounted) return;
      await _showPreparedAddStockDialog(
        tenantId: ctx.tenantId,
        docRef: ctx.docRef,
        uid: ctx.uid,
        userName: ctx.userName,
        draft: draft,
      );
    } catch (e) {
      _toastError(_cleanErr(e));
    }
  }

  Future<void> openEditDialog() async {
    try {
      final ctx = await _getActionContext();
      final draft = await _prepareEditDialogData(
        docRef: ctx.docRef,
        retailRef: ctx.retailRef,
        wholesaleRef: ctx.wholesaleRef,
        costRef: ctx.costRef,
      );
      if (!mounted) return;
      await _showPreparedEditDialog(
        tenantId: ctx.tenantId,
        docRef: ctx.docRef,
        retailRef: ctx.retailRef,
        wholesaleRef: ctx.wholesaleRef,
        costRef: ctx.costRef,
        uid: ctx.uid,
        userName: ctx.userName,
        draft: draft,
      );
    } catch (e) {
      _toastError(_cleanErr(e));
    }
  }

  Future<void> openMoveDialog() async {
    try {
      final ctx = await _getActionContext();
      final draft = await _prepareMoveDialogData(docRef: ctx.docRef);
      if (!mounted) return;
      await _showPreparedMoveDialog(
        tenantId: ctx.tenantId,
        docRef: ctx.docRef,
        uid: ctx.uid,
        userName: ctx.userName,
        draft: draft,
      );
    } catch (e) {
      _toastError(_cleanErr(e));
    }
  }

  Future<void> confirmDelete() async {
    try {
      final ctx = await _getActionContext();
      if (!mounted) return;

      await _confirmDelete(
        tenantId: ctx.tenantId,
        docRef: ctx.docRef,
        retailRef: ctx.retailRef,
        wholesaleRef: ctx.wholesaleRef,
        costRef: ctx.costRef,
      );
    } catch (e) {
      _toastError(_cleanErr(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bootstrapFuture = _bootstrapFuture;

    if (bootstrapFuture == null) {
      return const SizedBox.shrink();
    }

    return FutureBuilder<_BootstrapData?>(
      future: bootstrapFuture,
      builder: (context, bootstrapSnap) {
        if (bootstrapSnap.connectionState != ConnectionState.done &&
            !bootstrapSnap.hasData &&
            !bootstrapSnap.hasError) {
          return _buildLoadingState();
        }

        if (bootstrapSnap.hasError) {
          final error = bootstrapSnap.error!;
          if (_isSignedOutError(error)) {
            return const SizedBox.shrink();
          }

          if (_isUnavailableError(error)) {
            return _buildStateMessage(
              icon: Icons.cloud_off,
              message: "Firestore is currently unavailable.",
            );
          }

          return _buildStateMessage(
            icon: Icons.error_outline,
            message: _cleanErr(error),
          );
        }

        final bootstrap = bootstrapSnap.data;
        if (bootstrap == null) {
          return const SizedBox.shrink();
        }

        final docRef = _tenantProductsCol(bootstrap.tenantId).doc(widget.itemId);
        final retailRef = docRef.collection("prices").doc("retail");
        final wholesaleRef = docRef.collection("prices").doc("wholesale");
        final costRef = docRef.collection("prices").doc("cost");

        //keeps the item UI live updated as firestore changes
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: docRef.snapshots(includeMetadataChanges: true),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              final error = snapshot.error!;
              if (_isSignedOutError(error)) {
                return const SizedBox.shrink();
              }

              if (_isUnavailableError(error)) {
                return _buildStateMessage(
                  icon: Icons.cloud_off,
                  message: "Unable to load item right now.",
                );
              }

              return _buildStateMessage(
                icon: Icons.error_outline,
                message: _cleanErr(error),
              );
            }

            if (snapshot.connectionState == ConnectionState.waiting &&
                !snapshot.hasData) {
              return _buildLoadingState();
            }

            final doc = snapshot.data;
            if (doc != null && !doc.exists) {
              if (!_missingHandled) {
                _missingHandled = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  widget.onItemMissing?.call();
                });
              }
              return _buildStateMessage(
                icon: Icons.inventory_2_outlined,
                message: "This item no longer exists.",
              );
            }

            if (!snapshot.hasData) {
              return _buildLoadingState();
            }

            final data = doc?.data() ?? <String, dynamic>{};
            final String code = (data["code"] ?? "").toString().trim();
            final String imageUrl = (data["imageUrl"] ?? "").toString().trim();
            final bool isTshirt = (data["isTshirt"] ?? false) == true;
            final int stock = _numToInt(data["stockQuantity"]);

            final Map<String, dynamic> sizeStockRaw =
                (data["sizeStock"] as Map?)?.cast<String, dynamic>() ??
                    <String, dynamic>{};

            final Map<String, int> sizeStock = {
              for (final s in _sizes) s: _numToInt(sizeStockRaw[s]),
            };

            if (imageUrl.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _prefetchImageIfNeeded(
                  tenantId: bootstrap.tenantId,
                  imageUrl: imageUrl,
                );
              });
            }

            return _buildBody(
              tenantId: bootstrap.tenantId,
              role: bootstrap.role,
              code: code,
              imageUrl: imageUrl,
              isTshirt: isTshirt,
              stock: stock,
              sizeStock: sizeStock,
              retailStream: retailRef.snapshots(includeMetadataChanges: true),
              wholesaleStream:
              wholesaleRef.snapshots(includeMetadataChanges: true),
              costStream: costRef.snapshots(includeMetadataChanges: true),
            );
          },
        );
      },
    );
  }

  Widget _buildLoadingState() {
    return const Center(
      child: CircularProgressIndicator(),
    );
  }

  Widget _buildStateMessage({
    required IconData icon,
    required String message,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: Colors.grey.shade800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  //builds the actual item details UI
  Widget _buildBody({
    required String? tenantId,
    required String role,
    required String code,
    required String imageUrl,
    required bool isTshirt,
    required int stock,
    required Map<String, int> sizeStock,
    required Stream<DocumentSnapshot<Map<String, dynamic>>>? retailStream,
    required Stream<DocumentSnapshot<Map<String, dynamic>>>? wholesaleStream,
    required Stream<DocumentSnapshot<Map<String, dynamic>>>? costStream,
  }) {
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        children: [
          //image area
          Container(
            width: double.infinity,
            height: 300,
            color: Colors.grey.shade200,
            child: (tenantId != null && imageUrl.isNotEmpty)
                ? OfflineImageWidget(
              tenantId: tenantId,
              productId: widget.itemId,
              imageUrl: imageUrl,
              fit: BoxFit.contain,
              errorWidget: const Icon(
                Icons.image,
                size: 120,
                color: Colors.grey,
              ),
            )
                : const Icon(
              Icons.image,
              size: 120,
              color: Colors.grey,
            ),
          ),
          //product code
          const SizedBox(height: 20),
          Text(
            code,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          //stock section for normal area
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 25),
            child: Column(
              children: [ //stock section if it is a t-shirt item
                if (!isTshirt)
                  _infoRow("Stock Quantity", stock.toString())
                else ...[
                  const SizedBox(height: 10),
                  _sizeStockTableReadOnly(sizeStock),
                  const SizedBox(height: 10),
                  _infoRow("Total Stock", stock.toString()),
                ],
                //price rows
                if (_canSeeRetail(role))
                  _priceRow(
                    label: "Retail Price",
                    stream: retailStream,
                    fieldName: "retailPrice",
                  ),
                if (_canSeeWholesale(role))
                  _priceRow(
                    label: "Wholesale Price",
                    stream: wholesaleStream,
                    fieldName: "wholesalePrice",
                  ),
                if (_canSeeCost(role))
                  _priceRow(
                    label: "Cost Price",
                    stream: costStream,
                    fieldName: "costPrice",
                  ),
                //stock history button only for admins
                if (_isAdmin(role)) ...[
                  const SizedBox(height: 18),
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: code.isEmpty
                        ? null
                        : () {
                      if (!mounted) return;
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => StockHistoryScreen(
                            productId: widget.itemId,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.history, color: Colors.grey.shade700),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              "Stock History",
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade800,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            color: Colors.grey.shade600,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _priceRow({
    required String label,
    required Stream<DocumentSnapshot<Map<String, dynamic>>>? stream,
    required String fieldName,
  }) {
    if (stream == null) {
      return _infoRowLoading(label);
    }

    //watch the price document live
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return _infoRowLoading(label);
        }

        double? val;

        if (snap.hasData && snap.data!.exists) {
          final d = snap.data!.data() ?? <String, dynamic>{};
          val = _numToDouble(d[fieldName]);
        }

        if (val == null) {
          return _infoRowLoading(label);
        }

        return _infoRow(label, "€${val.toStringAsFixed(2)}");
      },
    );
  }

  Future<_AddStockDialogData> _prepareAddStockDialogData({
    required DocumentReference<Map<String, dynamic>> docRef,
  }) async {
    final snap = await _tryGetDocCacheThenServer(docRef);
    if (snap == null || !snap.exists) {
      throw Exception("Item not found.");
    }

    final data = snap.data() ?? <String, dynamic>{};
    final bool isTshirt = (data["isTshirt"] ?? false) == true;

    return _AddStockDialogData(isTshirt: isTshirt);
  }

  //add stock logic
  Future<void> _showPreparedAddStockDialog({
    required String tenantId,
    required DocumentReference<Map<String, dynamic>> docRef,
    required String uid,
    required String userName,
    required _AddStockDialogData draft,
  }) async {
    //create controllers
    final noteCtrl = TextEditingController();
    final addCtrl = TextEditingController(text: "0");
    final Map<String, TextEditingController> sizeAddCtrls = {
      for (final s in _sizes) s: TextEditingController(text: "0"),
    };

    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dCtx) => AlertDialog(
          title: const Text("Add Stock"),
          content: SingleChildScrollView(
            child: Column(
              children: [
                if (!draft.isTshirt)
                  TextField(
                    controller: addCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: "Quantity to add",
                    ),
                  )
                else
                  _sizeAddTableEditor(sizeAddCtrls),
                const SizedBox(height: 10),
                TextField(
                  controller: noteCtrl,
                  decoration: const InputDecoration(
                    labelText: "Note (optional)",
                    hintText: "e.g. Supplier delivery / Restock",
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => _safePop(dCtx, false),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () => _safePop(dCtx, true),
              child: const Text("Add"),
            ),
          ],
        ),
      );

      if (ok != true || !mounted) return;

      final now = DateTime.now();
      final yearStr = now.year.toString();

      final productSnap = await _tryGetDocCacheThenServer(docRef);
      if (productSnap == null || !productSnap.exists) {
        _toastError("Item not found.");
        return;
      }

      final p = productSnap.data() ?? <String, dynamic>{};
      final bool tshirt = (p["isTshirt"] ?? false) == true;
      final currentStock = _numToInt(p["stockQuantity"]);

      final yearsDoc = docRef.collection("stock_years").doc(yearStr);
      final movesCol = docRef.collection("stock_movements");

      final batch = _firestore.batch();

      final ySnap = await _tryGetDocCacheThenServer(yearsDoc);
      if (ySnap == null || !ySnap.exists) {
        batch.set(yearsDoc, {
          "year": now.year,
          "initialStock": currentStock,
          "currentStock": currentStock,
          "createdAt": FieldValue.serverTimestamp(),
          "createdBy": uid,
          "createdByName": userName,
        });
      }

      int deltaTotal = 0;
      Map<String, int>? sizeDelta;

      if (!tshirt) {
        final addQty = int.tryParse(addCtrl.text.trim()) ?? 0;
        if (addQty <= 0) {
          _toastInfo("Enter a quantity greater than 0.");
          return;
        }

        deltaTotal = addQty;
        final newStock = currentStock + addQty;

        batch.update(docRef, {
          "stockQuantity": newStock,
          "updatedAt": FieldValue.serverTimestamp(),
        });

        batch.set(
          yearsDoc,
          {
            "currentStock": newStock,
            "updatedAt": FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      } else {
        final Map<String, dynamic> raw =
            (p["sizeStock"] as Map?)?.cast<String, dynamic>() ??
                <String, dynamic>{};

        final Map<String, int> currentSizeStock = {
          for (final s in _sizes) s: _numToInt(raw[s]),
        };

        final Map<String, int> addMap = {
          for (final s in _sizes)
            s: int.tryParse(sizeAddCtrls[s]!.text.trim()) ?? 0,
        };

        deltaTotal = addMap.values.fold<int>(0, (a, b) => a + b);
        if (deltaTotal <= 0) {
          _toastInfo("Enter at least one size quantity greater than 0.");
          return;
        }

        final nz = <String, int>{};
        addMap.forEach((k, v) {
          if (v != 0) nz[k] = v;
        });
        if (nz.isNotEmpty) sizeDelta = nz;

        final Map<String, int> newSizeStock = {
          for (final s in _sizes)
            s: (currentSizeStock[s] ?? 0) + (addMap[s] ?? 0),
        };

        final newTotal = newSizeStock.values.fold<int>(0, (a, b) => a + b);

        batch.update(docRef, {
          "sizeStock": newSizeStock,
          "stockQuantity": newTotal,
          "updatedAt": FieldValue.serverTimestamp(),
        });

        batch.set(
          yearsDoc,
          {
            "currentStock": newTotal,
            "currentSizeStock": newSizeStock,
            "updatedAt": FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      }

      batch.set(movesCol.doc(), {
        "type": "add",
        "delta": deltaTotal,
        if (sizeDelta != null) "sizeDelta": sizeDelta,
        "note": noteCtrl.text.trim(),
        "at": FieldValue.serverTimestamp(),
        "by": uid,
        "byName": userName,
        "year": now.year,
        "tenantId": tenantId,
      });

      await batch.commit();

      await OutOfStockService().syncProductFolderWithStock(
        tenantId: tenantId,
        productId: docRef.id,
      );

      _toastSuccess("Stock added");
    } catch (e) {
      _toastError(_cleanErr(e));
    } finally {
      noteCtrl.dispose();
      addCtrl.dispose();
      for (final c in sizeAddCtrls.values) {
        c.dispose();
      }
    }
  }

  Future<_MoveDialogData> _prepareMoveDialogData({
    required DocumentReference<Map<String, dynamic>> docRef,
  }) async {
    final snap = await _tryGetDocCacheThenServer(docRef);
    if (snap == null || !snap.exists) {
      throw Exception("Item not found.");
    }

    final data = snap.data() ?? <String, dynamic>{};
    final String? currentFolderId = data["folderId"] as String?;
    final String code = (data["code"] ?? "").toString().trim();

    return _MoveDialogData(
      currentFolderId: currentFolderId,
      code: code,
    );
  }

  Future<void> _showPreparedMoveDialog({
    required String tenantId,
    required DocumentReference<Map<String, dynamic>> docRef,
    required String uid,
    required String userName,
    required _MoveDialogData draft,
  }) async {
    String? selectedFolderId;
    bool hasPicked = false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => StatefulBuilder(
        builder: (dCtx, setLocal) {
          final bool canMove = hasPicked &&
              selectedFolderId != null &&
              selectedFolderId != draft.currentFolderId;

          return AlertDialog(
            title: const Text("Move Item"),
            content: SizedBox(
              width: double.maxFinite,
              child: FolderPicker(
                tenantId: tenantId,
                placeholder: "Select folder",
                allowTopLevel: false,
                currentFolderId: draft.currentFolderId,
                preselectedFolder: null,
                onFolderSelected: (folderId) {
                  setLocal(() {
                    hasPicked = true;
                    selectedFolderId = folderId;
                  });
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => _safePop(dCtx, false),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                onPressed: canMove ? () => _safePop(dCtx, true) : null,
                child: const Text("Move"),
              ),
            ],
          );
        },
      ),
    );

    if (ok != true || !mounted) return;
    if (selectedFolderId == null || selectedFolderId == draft.currentFolderId) {
      _toastInfo("Select a different folder.");
      return;
    }

    try {
      final oldPathNames =
      await _buildFolderPathNames(tenantId, draft.currentFolderId);
      final newPathNames =
      await _buildFolderPathNames(tenantId, selectedFolderId);

      final batch = _firestore.batch();

      final selectedFolderSnap = await _tryGetDocCacheThenServer(
        _firestore
            .collection("tenants")
            .doc(tenantId)
            .collection("folders")
            .doc(selectedFolderId),
      );

      final selectedFolderData =
          selectedFolderSnap?.data() ?? <String, dynamic>{};

      final bool selectedIsSystemFolder =
          selectedFolderData["isSystemFolder"] == true ||
              (selectedFolderData["systemType"] ?? "").toString().trim() ==
                  "out_of_stock";

      final updateData = <String, dynamic>{
        "folderId": selectedFolderId,
        "updatedAt": FieldValue.serverTimestamp(),
      };

      if (!selectedIsSystemFolder) {
        updateData["originalFolderId"] = selectedFolderId;
      }

      batch.update(docRef, updateData);

      batch.set(_tenantMovementHistoryCol(tenantId).doc(), {
        "type": "product",
        "entityId": docRef.id,
        "name": draft.code,
        "oldPathNames": [...oldPathNames, draft.code],
        "newPathNames": [...newPathNames, draft.code],
        "movedAt": FieldValue.serverTimestamp(),
        "movedBy": uid,
        "movedByName": userName,
      });

      await batch.commit();

      await OutOfStockService().syncProductFolderWithStock(
        tenantId: tenantId,
        productId: docRef.id,
      );

      _toastSuccess("Item moved");
    } catch (e) {
      _toastError(_cleanErr(e));
    }
  }

  Future<_EditDialogData> _prepareEditDialogData({
    required DocumentReference<Map<String, dynamic>> docRef,
    required DocumentReference<Map<String, dynamic>> retailRef,
    required DocumentReference<Map<String, dynamic>> wholesaleRef,
    required DocumentReference<Map<String, dynamic>> costRef,
  }) async {
    final snapshot = await _tryGetDocCacheThenServer(docRef);
    if (snapshot == null || !snapshot.exists) {
      throw Exception("Item not found.");
    }

    final data = snapshot.data() ?? <String, dynamic>{};
    final bool isTshirt = (data["isTshirt"] ?? false) == true;

    final int oldTotalStock = _numToInt(data["stockQuantity"]);

    final Map<String, dynamic> oldSizeRaw =
        (data["sizeStock"] as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{};

    final Map<String, int> oldSizeStock = {
      for (final s in _sizes) s: _numToInt(oldSizeRaw[s]),
    };

    final retailSnap = await _tryGetDocCacheThenServer(retailRef);
    final wholesaleSnap = await _tryGetDocCacheThenServer(wholesaleRef);
    final costSnap = await _tryGetDocCacheThenServer(costRef);

    double retail = 0;
    double wholesale = 0;
    double cost = 0;

    if (retailSnap != null && retailSnap.exists) {
      final d = retailSnap.data() ?? <String, dynamic>{};
      retail = _numToDouble(d["retailPrice"]);
    }
    if (wholesaleSnap != null && wholesaleSnap.exists) {
      final d = wholesaleSnap.data() ?? <String, dynamic>{};
      wholesale = _numToDouble(d["wholesalePrice"]);
    }
    if (costSnap != null && costSnap.exists) {
      final d = costSnap.data() ?? <String, dynamic>{};
      cost = _numToDouble(d["costPrice"]);
    }

    return _EditDialogData(
      isTshirt: isTshirt,
      code: (data["code"] ?? "").toString(),
      oldTotalStock: oldTotalStock,
      oldSizeStock: oldSizeStock,
      retail: retail,
      wholesale: wholesale,
      cost: cost,
    );
  }

  Future<void> _showPreparedEditDialog({
    required String tenantId,
    required DocumentReference<Map<String, dynamic>> docRef,
    required DocumentReference<Map<String, dynamic>> retailRef,
    required DocumentReference<Map<String, dynamic>> wholesaleRef,
    required DocumentReference<Map<String, dynamic>> costRef,
    required String uid,
    required String userName,
    required _EditDialogData draft,
  }) async {
    final codeCtrl = TextEditingController(text: draft.code);
    final stockCtrl =
    TextEditingController(text: draft.oldTotalStock.toString());
    final retailCtrl =
    TextEditingController(text: draft.retail.toStringAsFixed(2));
    final wholesaleCtrl =
    TextEditingController(text: draft.wholesale.toStringAsFixed(2));
    final costCtrl = TextEditingController(text: draft.cost.toStringAsFixed(2));

    final Map<String, TextEditingController> sizeCtrls = {
      for (final s in _sizes)
        s: TextEditingController(text: (draft.oldSizeStock[s] ?? 0).toString()),
    };

    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dCtx) => AlertDialog(
          title: const Text("Edit Item"),
          content: SingleChildScrollView(
            child: Column(
              children: [
                TextField(
                  controller: codeCtrl,
                  decoration: const InputDecoration(labelText: "Code"),
                ),
                const SizedBox(height: 10),
                if (!draft.isTshirt)
                  TextField(
                    controller: stockCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: "Stock Quantity",
                    ),
                  )
                else
                  _sizeStockTableEditor(sizeCtrls),
                const SizedBox(height: 10),
                TextField(
                  controller: retailCtrl,
                  keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: "Retail Price"),
                ),
                TextField(
                  controller: wholesaleCtrl,
                  keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
                  decoration:
                  const InputDecoration(labelText: "Wholesale Price"),
                ),
                TextField(
                  controller: costCtrl,
                  keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: "Cost Price"),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => _safePop(dCtx, false),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () => _safePop(dCtx, true),
              child: const Text("Save"),
            ),
          ],
        ),
      );

      if (ok != true || !mounted) return;

      final newCode = codeCtrl.text.trim();
      if (newCode.isEmpty) {
        _toastInfo("Code cannot be empty.");
        return;
      }

      final batch = _firestore.batch();

      int newTotalStock = draft.oldTotalStock;
      Map<String, int>? newSizeStockMap;

      final Map<String, dynamic> updateData = {
        "code": newCode,
        "updatedAt": FieldValue.serverTimestamp(),
      };

      if (!draft.isTshirt) {
        newTotalStock = int.tryParse(stockCtrl.text.trim()) ?? 0;
        if (newTotalStock < 0) {
          _toastInfo("Stock cannot be negative.");
          return;
        }
        updateData["stockQuantity"] = newTotalStock;
      } else {
        newSizeStockMap = {
          for (final s in _sizes)
            s: int.tryParse(sizeCtrls[s]!.text.trim()) ?? 0,
        };

        final hasNegative = newSizeStockMap.values.any((v) => v < 0);
        if (hasNegative) {
          _toastInfo("Size quantities cannot be negative.");
          return;
        }

        newTotalStock = newSizeStockMap.values.fold<int>(0, (a, b) => a + b);
        updateData["sizeStock"] = newSizeStockMap;
        updateData["stockQuantity"] = newTotalStock;
      }

      batch.update(docRef, updateData);

      batch.set(
        retailRef,
        {
          "retailPrice": double.tryParse(retailCtrl.text.trim()) ?? 0,
          "updatedAt": FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      batch.set(
        wholesaleRef,
        {
          "wholesalePrice": double.tryParse(wholesaleCtrl.text.trim()) ?? 0,
          "updatedAt": FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      batch.set(
        costRef,
        {
          "costPrice": double.tryParse(costCtrl.text.trim()) ?? 0,
          "updatedAt": FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      final int delta = newTotalStock - draft.oldTotalStock;

      Map<String, int>? sizeDelta;
      if (draft.isTshirt && newSizeStockMap != null) {
        final Map<String, int> d = {
          for (final s in _sizes)
            s: (newSizeStockMap[s] ?? 0) - (draft.oldSizeStock[s] ?? 0),
        };
        final nonZero = <String, int>{};
        d.forEach((k, v) {
          if (v != 0) nonZero[k] = v;
        });
        if (nonZero.isNotEmpty) sizeDelta = nonZero;
      }

      if (delta != 0 || (sizeDelta != null && sizeDelta.isNotEmpty)) {
        final movesCol = docRef.collection("stock_movements");
        batch.set(movesCol.doc(), {
          "type": "adjust",
          "delta": delta,
          if (sizeDelta != null) "sizeDelta": sizeDelta,
          "note": "Edited stock: ${draft.oldTotalStock} → $newTotalStock",
          "at": FieldValue.serverTimestamp(),
          "by": uid,
          "byName": userName,
        });
      }

      await batch.commit();

      await OutOfStockService().syncProductFolderWithStock(
        tenantId: tenantId,
        productId: docRef.id,
      );

      _toastSuccess("Saved");
    } catch (e) {
      _toastError(_cleanErr(e));
    } finally {
      codeCtrl.dispose();
      stockCtrl.dispose();
      retailCtrl.dispose();
      wholesaleCtrl.dispose();
      costCtrl.dispose();
      for (final c in sizeCtrls.values) {
        c.dispose();
      }
    }
  }

  Future<void> _confirmDelete({
    required String tenantId,
    required DocumentReference<Map<String, dynamic>> docRef,
    required DocumentReference<Map<String, dynamic>> retailRef,
    required DocumentReference<Map<String, dynamic>> wholesaleRef,
    required DocumentReference<Map<String, dynamic>> costRef,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text("Delete Item"),
        content: const Text("Are you sure you want to delete this item?"),
        actions: [
          TextButton(
            onPressed: () => _safePop(dCtx, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => _safePop(dCtx, true),
            child: const Text(
              "Delete",
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;

    try {
      final batch = _firestore.batch();
      batch.delete(retailRef);
      batch.delete(wholesaleRef);
      batch.delete(costRef);
      batch.delete(docRef);
      await batch.commit();

      await OfflineMediaService.instance.deleteOfflineImage(
        tenantId: tenantId,
        productId: docRef.id,
      );

      _toastSuccess("Deleted");

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onItemMissing?.call();
      });
    } catch (e) {
      _toastError(_cleanErr(e));
    }
  }

  //size stock UI helpers
  Widget _sizeStockTableReadOnly(Map<String, int> sizeStock) {
    const double gap = 12;
    final row1 = _sizes.sublist(0, 4);
    final row2 = _sizes.sublist(4, 8);

    Widget cell(String s, double w) {
      return SizedBox(
        width: w,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(10),
            color: Colors.grey.shade50,
          ),
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
              Text(
                "${sizeStock[s] ?? 0}",
                style: const TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final cellW = ((maxW - (gap * 3)) / 4).clamp(60.0, 110.0);

        Row buildRow(List<String> row) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final s in row) ...[
                cell(s, cellW),
                if (s != row.last) const SizedBox(width: gap),
              ],
            ],
          );
        }

        return Column(
          children: [
            buildRow(row1),
            const SizedBox(height: 14),
            buildRow(row2),
          ],
        );
      },
    );
  }

  Widget _sizeStockTableEditor(Map<String, TextEditingController> ctrls) {
    const double cellW = 64;
    const double gap = 8;

    Widget cell(String s) {
      return SizedBox(
        width: cellW,
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
              controller: ctrls[s],
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
            ),
          ],
        ),
      );
    }

    final row1 = _sizes.sublist(0, 4);
    final row2 = _sizes.sublist(4, 8);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              "Size Quantities",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final s in row1) ...[
                cell(s),
                if (s != row1.last) const SizedBox(width: gap),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final s in row2) ...[
                cell(s),
                if (s != row2.last) const SizedBox(width: gap),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _sizeAddTableEditor(Map<String, TextEditingController> ctrls) {
    const double cellW = 64;
    const double gap = 8;

    Widget cell(String s) {
      return SizedBox(
        width: cellW,
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
              controller: ctrls[s],
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
            ),
          ],
        ),
      );
    }

    final row1 = _sizes.sublist(0, 4);
    final row2 = _sizes.sublist(4, 8);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              "Add per size",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final s in row1) ...[
                cell(s),
                if (s != row1.last) const SizedBox(width: gap),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final s in row2) ...[
                cell(s),
                if (s != row2.last) const SizedBox(width: gap),
              ],
            ],
          ),
        ],
      ),
    );
  }

  //info row widgets
  Widget _infoRow(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade300),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 16)),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRowLoading(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade300),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 16)),
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      ),
    );
  }
}

//lightweight containers
class _BootstrapData {
  final String uid;
  final String tenantId;
  final String role;
  final String userName;

  const _BootstrapData({
    required this.uid,
    required this.tenantId,
    required this.role,
    required this.userName,
  });
}

class _ActionContext {
  final String tenantId;
  final String uid;
  final String userName;
  final String role;
  final DocumentReference<Map<String, dynamic>> docRef;
  final DocumentReference<Map<String, dynamic>> retailRef;
  final DocumentReference<Map<String, dynamic>> wholesaleRef;
  final DocumentReference<Map<String, dynamic>> costRef;

  const _ActionContext({
    required this.tenantId,
    required this.uid,
    required this.userName,
    required this.role,
    required this.docRef,
    required this.retailRef,
    required this.wholesaleRef,
    required this.costRef,
  });
}

class _AddStockDialogData {
  final bool isTshirt;

  const _AddStockDialogData({
    required this.isTshirt,
  });
}

class _MoveDialogData {
  final String? currentFolderId;
  final String code;

  const _MoveDialogData({
    required this.currentFolderId,
    required this.code,
  });
}

class _EditDialogData {
  final bool isTshirt;
  final String code;
  final int oldTotalStock;
  final Map<String, int> oldSizeStock;
  final double retail;
  final double wholesale;
  final double cost;

  const _EditDialogData({
    required this.isTshirt,
    required this.code,
    required this.oldTotalStock,
    required this.oldSizeStock,
    required this.retail,
    required this.wholesale,
    required this.cost,
  });
}