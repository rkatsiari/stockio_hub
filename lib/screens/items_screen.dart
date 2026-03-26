import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../services/offline_media_service.dart';
import '../services/tenant_context_service.dart';
import '../utils/folder_paths.dart';
import '../widgets/app_search_bar.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/folder_grid_tile.dart';
import '../widgets/folder_picker.dart';
import '../widgets/offline_image_widget.dart';
import '../widgets/top_toast.dart';
import 'item_details_pager_screen.dart';
import 'new_folder_screen.dart';
import 'new_item_screen.dart';

class ItemsScreen extends StatefulWidget {
  final String folderId;
  final String folderName;

  const ItemsScreen({
    super.key,
    required this.folderId,
    required this.folderName,
  });

  @override
  State<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends State<ItemsScreen> {
  late final StreamSubscription<User?> _authSub;

  User? _currentUser;
  Future<_ItemsBootstrapState>? _bootstrapFuture;

  @override
  void initState() {
    super.initState();
    _currentUser = FirebaseAuth.instance.currentUser;
    _bootstrapFuture = _buildBootstrapForUser(_currentUser);

    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted) return;

      final previousUid = _currentUser?.uid;
      final nextUid = user?.uid;

      if (previousUid == nextUid) return;

      setState(() {
        _currentUser = user;
        _bootstrapFuture = _buildBootstrapForUser(user);
      });
    });
  }

  @override
  void dispose() {
    _authSub.cancel();
    super.dispose();
  }

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

  Future<_ItemsBootstrapState> _buildBootstrapForUser(User? user) async {
    if (user == null) {
      return const _ItemsBootstrapState.signedOut();
    }

    final tenantContext = TenantContextService();

    try {
      Map<String, dynamic>? profile =
      await tenantContext.tryGetCurrentUserProfileCacheOnly();

      profile ??= await tenantContext.tryGetCurrentUserProfile();

      if (profile == null) {
        return const _ItemsBootstrapState.error(
          message: "Failed to load your profile.",
        );
      }

      final tenantId = (profile["tenantId"] ?? "").toString().trim();
      final role = (profile["role"] ?? "staff").toString().trim();

      if (tenantId.isEmpty) {
        return const _ItemsBootstrapState.missingTenant();
      }

      return _ItemsBootstrapState.ready(
        tenantId: tenantId,
        role: role,
      );
    } catch (e) {
      if (_isAuthOrPermissionError(e)) {
        return const _ItemsBootstrapState.signedOut();
      }

      final message = e.toString().replaceFirst("Exception: ", "").trim();
      return _ItemsBootstrapState.error(
        message: message.isEmpty ? "Failed to load folder." : message,
      );
    }
  }

  //standard page layout for loading, error and empty state
  Widget _buildScaffoldShell({
    required Widget body,
    bool showBottomNav = false,
  }) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: const Color(0xff0B1E40),
        title: Text(
          widget.folderName,
          style: const TextStyle(color: Colors.white),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            if (!mounted) return;
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      bottomNavigationBar: showBottomNav
          ? const BottomNav(
        currentIndex: 1,
        hasFab: false,
        isRootScreen: false,
      )
          : null,
      body: body,
    );
  }

  //builds a centered message screen
  Widget _buildCenteredState({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    return _buildScaffoldShell(
      showBottomNav: true,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 56, color: Colors.grey.shade500),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                      height: 1.35,
                    ),
                  ),
                  if (action != null) ...[
                    const SizedBox(height: 20),
                    action,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingScaffold() {
    return _buildScaffoldShell(
      showBottomNav: true,
      body: const SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: Center(
                child: CircularProgressIndicator(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final future = _bootstrapFuture ?? _buildBootstrapForUser(_currentUser);

    return FutureBuilder<_ItemsBootstrapState>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildLoadingScaffold();
        }

        final state = snapshot.data ??
            const _ItemsBootstrapState.error(
              message: "Failed to load folder.",
            );

        if (state.isSignedOut) {
          return _buildCenteredState(
            icon: Icons.lock_outline,
            title: "Not signed in",
            subtitle: "Please sign in to access this folder.",
          );
        }

        if (state.isMissingTenant) {
          return _buildCenteredState(
            icon: Icons.apartment_outlined,
            title: "Tenant not found",
            subtitle: "Your account is not assigned to a tenant yet.",
          );
        }

        if (!state.isReady) {
          return _buildCenteredState(
            icon: Icons.error_outline,
            title: "Could not load folder",
            subtitle: state.message ?? "Something went wrong.",
            action: ElevatedButton(
              onPressed: () {
                if (!mounted) return;
                setState(() {
                  _bootstrapFuture = _buildBootstrapForUser(_currentUser);
                });
              },
              child: const Text("Retry"),
            ),
          );
        }

        return _ItemsContent(
          key: ValueKey<String>(
            'items-${state.tenantId}-${widget.folderId}-${state.role}',
          ),
          tenantId: state.tenantId!,
          folderId: widget.folderId,
          folderName: widget.folderName,
          role: state.role,
        );
      },
    );
  }
}

//represents the result of bootstrap loading
class _ItemsBootstrapState {
  final String? tenantId;
  final String role;
  final bool isSignedOut;
  final bool isMissingTenant;
  final String? message;

  const _ItemsBootstrapState._({
    required this.tenantId,
    required this.role,
    required this.isSignedOut,
    required this.isMissingTenant,
    required this.message,
  });

  const _ItemsBootstrapState.ready({
    required String tenantId,
    required String role,
  })  : this._(
    tenantId: tenantId,
    role: role,
    isSignedOut: false,
    isMissingTenant: false,
    message: null,
  );

  const _ItemsBootstrapState.signedOut()
      : this._(
    tenantId: null,
    role: "",
    isSignedOut: true,
    isMissingTenant: false,
    message: null,
  );

  const _ItemsBootstrapState.missingTenant()
      : this._(
    tenantId: null,
    role: "",
    isSignedOut: false,
    isMissingTenant: true,
    message: null,
  );

  const _ItemsBootstrapState.error({
    required String message,
  })  : this._(
    tenantId: null,
    role: "",
    isSignedOut: false,
    isMissingTenant: false,
    message: message,
  );

  bool get isReady => tenantId != null && tenantId!.trim().isNotEmpty;
}

//actual working screen
class _ItemsContent extends StatefulWidget {
  final String tenantId;
  final String folderId;
  final String folderName;
  final String role;

  const _ItemsContent({
    super.key,
    required this.tenantId,
    required this.folderId,
    required this.folderName,
    required this.role,
  });

  @override
  State<_ItemsContent> createState() => _ItemsContentState();
}

class _ItemsContentState extends State<_ItemsContent> {
  static const List<String> _sizes = [
    "XXS", "XS", "S", "M",
    "L", "XL", "2XL", "3XL",
  ];

  final ImagePicker _picker = ImagePicker();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  Timer? _searchDebounce;
  StreamSubscription<User?>? _authSub;

  String _appliedSearchQuery = "";
  bool _isSearchSettling = false;
  bool _handledSignedOut = false;

  final Set<String> _prefetchedProductIds = <String>{};

  bool _foldersErrorShown = false;
  bool _itemsErrorShown = false;

  //role helpers
  bool get _isAdmin => widget.role == "admin";
  bool get _isStorageManager => widget.role == "storage_manager";

  bool get _canCreateOrders =>
      widget.role == "admin" ||
          widget.role == "manager" ||
          widget.role == "accountant" ||
          widget.role == "staff" ||
          widget.role == "reseller";

  @override
  void initState() {
    super.initState();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted || _handledSignedOut) return;
      if (user == null) {
        _handledSignedOut = true;
      }
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _authSub?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
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

  //firestore collection helpers
  CollectionReference<Map<String, dynamic>> _productsCol() {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("products");
  }

  CollectionReference<Map<String, dynamic>> _foldersCol() {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("folders");
  }

  CollectionReference<Map<String, dynamic>> _ordersCol() {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("orders");
  }

  CollectionReference<Map<String, dynamic>> _shopsCol() {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("shops");
  }

  CollectionReference<Map<String, dynamic>> _movementHistoryCol() {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("movement_history");
  }

  //utility helpers
  String _cleanErr(Object e) =>
      e.toString().replaceFirst("Exception: ", "").trim();

  bool _isProtectedFolder(Map<String, dynamic> data) {
    return data["isSystemFolder"] == true ||
        (data["systemType"] ?? "").toString().trim() == "out_of_stock";
  }

  int _folderSort(
      QueryDocumentSnapshot<Map<String, dynamic>> a,
      QueryDocumentSnapshot<Map<String, dynamic>> b,
      ) {
    final aData = a.data();
    final bData = b.data();

    final aProtected = _isProtectedFolder(aData);
    final bProtected = _isProtectedFolder(bData);

    if (aProtected && !bProtected) return -1;
    if (!aProtected && bProtected) return 1;

    final aName = (aData["name"] ?? "").toString().toLowerCase();
    final bName = (bData["name"] ?? "").toString().toLowerCase();
    return aName.compareTo(bName);
  }

  //cache then server helpers
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

  Future<QuerySnapshot<Map<String, dynamic>>?> _tryGetQueryCacheThenServer(
      Query<Map<String, dynamic>> query,
      ) async {
    try {
      final cached = await query
          .get(const GetOptions(source: Source.cache))
          .timeout(const Duration(milliseconds: 600));
      if (cached.docs.isNotEmpty) return cached;
    } catch (_) {}

    try {
      return await query.get().timeout(const Duration(milliseconds: 1800));
    } catch (_) {}

    return null;
  }

  Future<bool> _isProtectedFolderById(String folderId) async {
    try {
      final snap = await _tryGetDocCacheThenServer(_foldersCol().doc(folderId));
      final data = snap?.data() ?? <String, dynamic>{};
      return _isProtectedFolder(data);
    } catch (_) {
      return false;
    }
  }

  void _showErrorToast(String message) {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;
    TopToast.error(context, message);
  }

  void _showSuccessToast(String message) {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;
    TopToast.success(context, message);
  }

  void _safeCloseDialog(BuildContext dialogContext, [dynamic result]) {
    if (!dialogContext.mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!dialogContext.mounted) return;
      final navigator = Navigator.of(dialogContext);
      if (navigator.canPop()) {
        navigator.pop(result);
      }
    });
  }

  Future<T?> _showSafeDialog<T>({
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) {
    if (!mounted || _isSignedOut() || _handledSignedOut) {
      return Future<T?>.value(null);
    }

    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      useRootNavigator: true,
      builder: builder,
    );
  }

  Future<void> _showPopMessage(String title, String message) async {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    await _showSafeDialog<void>(
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => _safeCloseDialog(dialogContext),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  int _responsiveGridCount(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width >= 900) return 4;
    if (width >= 600) return 3;
    return 2;
  }

  int get _currentYear => DateTime.now().year;

  //give faster UX
  Future<void> _completeWriteQuickly(Future<void> future) async {
    try {
      await future.timeout(const Duration(milliseconds: 900));
    } on TimeoutException {
      unawaited(future.catchError((_) {}));
    }
  }

  Future<bool> _completeWriteQuicklyBool(Future<void> future) async {
    try {
      await future.timeout(const Duration(milliseconds: 900));
      return true;
    } on TimeoutException {
      unawaited(future.catchError((_) {}));
      return true;
    } catch (_) {
      return false;
    }
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

  //order creation logic - decide how to create a new order
  Future<_OrderCreatePayload?> _promptOrderInfoWithShopLogic() async {
    if (_isSignedOut() || _handledSignedOut) return null;

    final shopsSnap = await _tryGetQueryCacheThenServer(
      _shopsCol().orderBy("createdAt", descending: false),
    );

    final shops = shopsSnap?.docs ??
        const <QueryDocumentSnapshot<Map<String, dynamic>>>[];

    if (shops.isEmpty) {
      final ctrl = TextEditingController();

      try {
        final name = await _showSafeDialog<String>(
          builder: (dialogContext) => AlertDialog(
            title: const Text("New Order"),
            content: TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: "Order name"),
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (value) {
                final v = value.trim();
                if (v.isEmpty) return;
                _safeCloseDialog(dialogContext, v);
              },
            ),
            actions: [
              TextButton(
                onPressed: () => _safeCloseDialog(dialogContext),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                onPressed: () {
                  final v = ctrl.text.trim();
                  if (v.isEmpty) return;
                  _safeCloseDialog(dialogContext, v);
                },
                child: const Text("Create"),
              ),
            ],
          ),
        );

        final finalName = (name ?? "").trim();
        if (finalName.isEmpty) return null;

        return _OrderCreatePayload(
          name: finalName,
          shopId: null,
          shopName: "",
        );
      } finally {
        ctrl.dispose();
      }
    }

    String selectedShopId = shops.first.id;
    String selectedShopName =
    ((shops.first.data())["name"] ?? "Untitled").toString();

    final ok = await _showSafeDialog<bool>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) {
          return AlertDialog(
            title: const Text("New Order"),
            content: DropdownButtonFormField<String>(
              isExpanded: true,
              value: selectedShopId,
              decoration: const InputDecoration(
                labelText: "Shop",
                border: OutlineInputBorder(),
              ),
              items: shops.map((d) {
                final data = d.data();
                final shopName = (data["name"] ?? "Untitled").toString();
                return DropdownMenuItem<String>(
                  value: d.id,
                  child: Text(shopName),
                );
              }).toList(),
              onChanged: (v) {
                if (v == null) return;
                final doc = shops.firstWhere((x) => x.id == v);
                final data = doc.data();
                setLocal(() {
                  selectedShopId = v;
                  selectedShopName = (data["name"] ?? "Untitled").toString();
                });
              },
            ),
            actions: [
              TextButton(
                onPressed: () => _safeCloseDialog(dialogContext, false),
                child: const Text("Cancel"),
              ),
              ElevatedButton(
                onPressed: () => _safeCloseDialog(dialogContext, true),
                child: const Text("Create"),
              ),
            ],
          );
        },
      ),
    );

    if (ok != true) return null;

    final finalName =
    selectedShopName.trim().isEmpty ? "Untitled" : selectedShopName.trim();

    return _OrderCreatePayload(
      name: finalName,
      shopId: selectedShopId,
      shopName: selectedShopName,
    );
  }

  //image cropping
  Future<XFile> _autoCenterCropTo4by3(
      XFile input, {
        int jpegQuality = 85,
      }) async {
    final Uint8List bytes = await input.readAsBytes();

    img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw Exception("Could not read image data.");
    }

    decoded = img.bakeOrientation(decoded);

    final int w = decoded.width;
    final int h = decoded.height;

    const double target = 4 / 3;

    int cropW = w;
    int cropH = h;

    if (w / h > target) {
      cropW = (h * target).round();
      cropH = h;
    } else {
      cropW = w;
      cropH = (w / target).round();
    }

    final int x = ((w - cropW) / 2).round();
    final int y = ((h - cropH) / 2).round();

    final img.Image cropped = img.copyCrop(
      decoded,
      x: x,
      y: y,
      width: cropW,
      height: cropH,
    );

    final List<int> outJpg = img.encodeJpg(cropped, quality: jpegQuality);

    if (kIsWeb) {
      //create image from bytes in memory (web)
      return XFile.fromData(
        Uint8List.fromList(outJpg),
        name: "cropped_4x3.jpg",
        mimeType: "image/jpeg",
      );
    } else {
      //create image from bytes in memory (mobile)
      final dir = await getTemporaryDirectory();
      final path =
          "${dir.path}/cropped_4x3_${DateTime.now().millisecondsSinceEpoch}.jpg";
      final file = File(path);
      await file.writeAsBytes(outJpg, flush: true);
      return XFile(file.path);
    }
  }

  Future<void> _pickAndOpenNewItem(ImageSource source) async {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    final navigator = Navigator.of(context);
    final focusScope = FocusScope.of(context);

    focusScope.unfocus();
    if (navigator.canPop()) {
      navigator.pop();
    }

    final XFile? picked = await _picker.pickImage(
      source: source,
      imageQuality: 100,
    );

    if (picked == null || !mounted || _isSignedOut() || _handledSignedOut) {
      return;
    }

    try {
      final XFile cropped = await _autoCenterCropTo4by3(
        picked,
        jpegQuality: 85,
      );

      if (!mounted || _isSignedOut() || _handledSignedOut) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NewItemScreen(
            folderId: widget.folderId,
            originalFolderId: widget.folderId,
            initialImage: cropped,
          ),
        ),
      );
    } catch (e) {
      if (!mounted || _isSignedOut() || _handledSignedOut) return;
      _showErrorToast("Image processing failed: ${_cleanErr(e)}");
    }
  }

  void _showAddMenu() {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    FocusScope.of(context).unfocus();

    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SizedBox(
          height: 220,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text("Take photo"),
                onTap: () => _pickAndOpenNewItem(ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.image),
                title: const Text("Upload photo"),
                onTap: () => _pickAndOpenNewItem(ImageSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder),
                title: const Text("Create Folder"),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  if (!mounted || _isSignedOut() || _handledSignedOut) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => NewFolderScreen(parentId: widget.folderId),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  int _numToInt(dynamic v) =>
      (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? "") ?? 0;

  int? _getAvailableStockNonTx({
    required Map<String, dynamic>? productData,
    required Map<String, dynamic>? yearData,
    required bool isTshirt,
    required String chosenSize,
  }) {
    if (productData == null) return null;

    if (!isTshirt) {
      final vNew = yearData?["currentStock"];
      if (vNew != null) return _numToInt(vNew);
      return _numToInt(productData["stockQuantity"]);
    }

    final Map<String, dynamic> newSizeMap =
        (yearData?["currentSizeStock"] as Map?)?.cast<String, dynamic>() ?? {};
    if (newSizeMap.containsKey(chosenSize)) {
      return _numToInt(newSizeMap[chosenSize]);
    }

    final Map<String, dynamic> oldSizeMap =
        (productData["sizeStock"] as Map?)?.cast<String, dynamic>() ?? {};
    if (oldSizeMap.containsKey(chosenSize)) {
      return _numToInt(oldSizeMap[chosenSize]);
    }

    return null;
  }

  Future<bool> _addItemToActiveOrder({
    required String productId,
    required String code,
    required int quantity,
    required bool isTshirt,
    String? size,
  }) async {
    if (quantity <= 0 || _isSignedOut() || _handledSignedOut) return false;
    if (!_canCreateOrders || _isStorageManager) return false;

    final chosenSize = (size ?? "").trim();
    if (isTshirt && chosenSize.isEmpty) {
      await _showPopMessage("Cannot add item", "Select a size first.");
      return false;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;

    final fs = FirebaseFirestore.instance;
    final year = _currentYear;

    final folderPathNames = await FolderPaths.getFolderPathNamesForOrders(
      fs,
      widget.tenantId,
      widget.folderId,
    );

    final productRef = _productsCol().doc(productId);
    final yearRef = productRef.collection("stock_years").doc(year.toString());

    try {
      final productSnap = await _tryGetDocCacheThenServer(productRef);
      final yearSnap = await _tryGetDocCacheThenServer(yearRef);

      final productData =
      productSnap?.exists == true ? productSnap!.data() : null;
      final yearData = yearSnap?.exists == true ? yearSnap!.data() : null;

      final activeQuery = _ordersCol()
          .where("userId", isEqualTo: uid)
          .where("isActive", isEqualTo: true)
          .limit(1);

      final activeSnap = await _tryGetQueryCacheThenServer(activeQuery);

      DocumentReference<Map<String, dynamic>> orderRef;
      bool creatingOrder = false;
      _OrderCreatePayload? payload;

      if (activeSnap != null && activeSnap.docs.isNotEmpty) {
        orderRef = activeSnap.docs.first.reference;
      } else {
        if (!mounted || _isSignedOut() || _handledSignedOut) return false;

        payload = await _promptOrderInfoWithShopLogic();
        if (payload == null || _isSignedOut() || _handledSignedOut) {
          return false;
        }

        orderRef = _ordersCol().doc();
        creatingOrder = true;
      }

      final String orderLineId =
      isTshirt ? "${productId}__$chosenSize" : productId;
      final orderItemRef = orderRef.collection("items").doc(orderLineId);

      final orderItemSnap = await _tryGetDocCacheThenServer(orderItemRef);
      final int alreadyInOrder = (orderItemSnap?.exists ?? false)
          ? _numToInt((orderItemSnap!.data() ?? <String, dynamic>{})[
      "qty"])
          : 0;

      final int newTotal = alreadyInOrder + quantity;

      final available = _getAvailableStockNonTx(
        productData: productData,
        yearData: yearData,
        isTshirt: isTshirt,
        chosenSize: chosenSize,
      );

      if (available != null && newTotal > available) {
        if (!isTshirt) {
          await _showPopMessage(
            "Cannot add item",
            "Not enough stock. Available: $available, already in order: $alreadyInOrder, trying to add: $quantity.",
          );
        } else {
          await _showPopMessage(
            "Cannot add item",
            "Not enough stock for size $chosenSize. Available: $available, already in order: $alreadyInOrder, trying to add: $quantity.",
          );
        }
        return false;
      }

      final batch = fs.batch();

      if (creatingOrder && payload != null) {
        final userInfo = await _getCurrentUserInfo(uid);
        final userName =
        userInfo["name"]!.isEmpty ? "Unknown" : userInfo["name"]!;
        final userEmail = userInfo["email"] ?? "";

        batch.set(orderRef, {
          "userId": uid,
          "userName": userName,
          "userEmail": userEmail,
          "name": payload.name,
          "shopId": payload.shopId,
          "shopName": payload.shopName,
          "createdAt": FieldValue.serverTimestamp(),
          "isActive": true,
          "isExported": false,
          "exportedAt": null,
          "closedAt": null,
        });
      }

      batch.set(
        orderItemRef,
        {
          "productId": productId,
          "code": code,
          "qty": FieldValue.increment(quantity),
          "folderPathNames": folderPathNames,
          "addedAt": FieldValue.serverTimestamp(),
          "year": year,
          "isTshirt": isTshirt,
          if (isTshirt) "size": chosenSize,
        },
        SetOptions(merge: true),
      );

      final queued = await _completeWriteQuicklyBool(batch.commit());

      if (!mounted || _isSignedOut() || _handledSignedOut) return queued;
      return queued;
    } catch (e) {
      if (!mounted || _isSignedOut() || _handledSignedOut) return false;

      if (_isUnavailableError(e)) {
        _showErrorToast(
          "Could not complete this action right now. Try again once Firestore reconnects, or open the data online first.",
        );
      } else if (!_isAuthOrPermissionError(e)) {
        _showErrorToast(_cleanErr(e));
      }

      return false;
    }
  }

  Future<void> _prefetchVisibleProductImages({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> items,
  }) async {
    final futures = <Future<void>>[];

    for (final item in items) {
      final id = item.id;
      if (_prefetchedProductIds.contains(id)) continue;

      final data = item.data();
      final imageUrl = (data["imageUrl"] ?? "").toString().trim();
      if (imageUrl.isEmpty) continue;

      _prefetchedProductIds.add(id);

      futures.add(
        OfflineMediaService.instance
            .ensureOfflineImage(
          tenantId: widget.tenantId,
          productId: id,
          imageUrl: imageUrl,
        )
            .then((_) {})
            .catchError((_) {}),
      );
    }

    if (futures.isNotEmpty) {
      unawaited(Future.wait(futures));
    }
  }

  //folder actions
  Future<void> _renameFolder(String folderId, String currentName) async {
    if (await _isProtectedFolderById(folderId)) {
      _showErrorToast("Out of stock folders cannot be renamed.");
      return;
    }

    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    final ctrl = TextEditingController(text: currentName);

    try {
      await _showSafeDialog<void>(
        builder: (dialogContext) => AlertDialog(
          title: const Text("Rename Folder"),
          content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(labelText: "New Folder Name"),
            textInputAction: TextInputAction.done,
            autofocus: true,
            onSubmitted: (_) async {
              final newName = ctrl.text.trim();
              _safeCloseDialog(dialogContext);

              if (newName.isEmpty) return;

              try {
                await _completeWriteQuickly(
                  _foldersCol().doc(folderId).update({
                    "name": newName,
                  }),
                );

                if (!mounted || _isSignedOut() || _handledSignedOut) return;
                _showSuccessToast("Folder renamed.");
              } catch (e) {
                if (_isAuthOrPermissionError(e)) return;
                if (mounted && !_isSignedOut() && !_handledSignedOut) {
                  _showErrorToast("Failed to rename folder.");
                }
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => _safeCloseDialog(dialogContext),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () async {
                final newName = ctrl.text.trim();
                _safeCloseDialog(dialogContext);

                if (newName.isEmpty) return;

                try {
                  await _completeWriteQuickly(
                    _foldersCol().doc(folderId).update({
                      "name": newName,
                    }),
                  );

                  if (!mounted || _isSignedOut() || _handledSignedOut) return;
                  _showSuccessToast("Folder renamed.");
                } catch (e) {
                  if (_isAuthOrPermissionError(e)) return;
                  if (mounted && !_isSignedOut() && !_handledSignedOut) {
                    _showErrorToast("Failed to rename folder.");
                  }
                }
              },
              child: const Text("Save"),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _moveFolder(String folderId) async {
    final fs = FirebaseFirestore.instance;

    if (await _isProtectedFolderById(folderId)) {
      _showErrorToast("Out of stock folders cannot be moved.");
      return;
    }

    final folderSnap =
    await _tryGetDocCacheThenServer(_foldersCol().doc(folderId));
    if (folderSnap == null || !folderSnap.exists) return;

    final f = folderSnap.data() ?? <String, dynamic>{};
    final String? oldParentId = f["parentId"] as String?;
    final String folderName = (f["name"] ?? "").toString().trim();

    String? newParent;
    bool hasPicked = false;
    bool ignoreFirstCallback = true;

    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    await _showSafeDialog<void>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) {
          final bool canMove = hasPicked && newParent != oldParentId;

          return AlertDialog(
            title: const Text("Move Folder"),
            content: SizedBox(
              width: double.maxFinite,
              child: FolderPicker(
                tenantId: widget.tenantId,
                placeholder: "Select folder",
                allowTopLevel: true,
                excludeFolderId: folderId,
                excludeParentOfFolderId: folderId,
                currentFolderId: folderId,
                preselectedFolder: null,
                onFolderSelected: (value) {
                  if (ignoreFirstCallback) {
                    ignoreFirstCallback = false;
                    return;
                  }
                  setLocal(() {
                    hasPicked = true;
                    newParent = value;
                  });
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => _safeCloseDialog(dialogContext),
                child: const Text("Cancel"),
              ),
              TextButton(
                onPressed: canMove
                    ? () async {
                  final pickedParent = newParent;
                  _safeCloseDialog(dialogContext);

                  if (pickedParent == oldParentId) return;

                  final uid =
                      FirebaseAuth.instance.currentUser?.uid ?? "";
                  String movedByName = "";

                  if (uid.isNotEmpty) {
                    final userSnap = await _tryGetDocCacheThenServer(
                      fs.collection("users").doc(uid),
                    );
                    final u = userSnap?.data() ?? <String, dynamic>{};
                    movedByName =
                        (u["name"] ?? "").toString().trim();
                  }

                  try {
                    final paths =
                    await FolderPaths.buildMovePathsNoRoot(
                      fs: fs,
                      tenantId: widget.tenantId,
                      oldParentId: oldParentId,
                      newParentId: pickedParent,
                      entityName: folderName.isEmpty
                          ? "(folder)"
                          : folderName,
                    );

                    final batch = fs.batch();
                    final folderRef = _foldersCol().doc(folderId);

                    batch.update(folderRef, {"parentId": pickedParent});
                    batch.set(_movementHistoryCol().doc(), {
                      "type": "folder",
                      "entityId": folderId,
                      "name": folderName,
                      "oldPathNames": paths["old"],
                      "newPathNames": paths["new"],
                      "movedAt": FieldValue.serverTimestamp(),
                      "movedBy": uid,
                      "movedByName": movedByName,
                    });

                    await _completeWriteQuickly(batch.commit());

                    if (!mounted || _isSignedOut() || _handledSignedOut) {
                      return;
                    }
                    _showSuccessToast("Folder moved.");
                  } catch (e) {
                    if (_isAuthOrPermissionError(e)) return;
                    _showErrorToast("Failed to move folder.");
                  }
                }
                    : null,
                child: const Text("Move"),
              ),
            ],
          );
        },
      ),
    );
  }


  Future<void> _deleteFolderRecursive(String folderId) async {
    final itemsSnap = await _tryGetQueryCacheThenServer(
      _productsCol().where("folderId", isEqualTo: folderId),
    );

    for (final doc in itemsSnap?.docs ??
        <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
      await OfflineMediaService.instance.deleteOfflineImage(
        tenantId: widget.tenantId,
        productId: doc.id,
      );
      await doc.reference.delete();
    }

    final subSnap = await _tryGetQueryCacheThenServer(
      _foldersCol().where("parentId", isEqualTo: folderId),
    );

    for (final sub in subSnap?.docs ??
        <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
      await _deleteFolderRecursive(sub.id);
    }

    await _foldersCol().doc(folderId).delete();
  }

  Future<void> _confirmDeleteFolder(String folderId, String folderName) async {
    if (await _isProtectedFolderById(folderId)) {
      _showErrorToast("Out of stock folders cannot be deleted.");
      return;
    }

    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    await _showSafeDialog<void>(
      builder: (dialogContext) => AlertDialog(
        title: const Text("Delete Folder"),
        content: Text(
          'Are you sure you want to delete "$folderName" and ALL its subfolders and items?',
        ),
        actions: [
          TextButton(
            onPressed: () => _safeCloseDialog(dialogContext),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              _safeCloseDialog(dialogContext);

              try {
                await _deleteFolderRecursive(folderId);
                if (!mounted || _isSignedOut() || _handledSignedOut) return;
                _showSuccessToast("Folder deleted.");
              } catch (e) {
                if (_isAuthOrPermissionError(e)) return;
                _showErrorToast("Failed to delete folder.");
              }
            },
            child: const Text(
              "Delete",
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _renameItem(String itemId, String currentCode) async {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    final ctrl = TextEditingController(text: currentCode);

    try {
      await _showSafeDialog<void>(
        builder: (dialogContext) => AlertDialog(
          title: const Text("Rename Item Code"),
          content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(labelText: "New Code"),
            textInputAction: TextInputAction.done,
            autofocus: true,
            onSubmitted: (_) async {
              final newCode = ctrl.text.trim();
              _safeCloseDialog(dialogContext);

              if (newCode.isEmpty) return;

              try {
                await _completeWriteQuickly(
                  _productsCol().doc(itemId).update({
                    "code": newCode,
                  }),
                );

                if (!mounted || _isSignedOut() || _handledSignedOut) return;
                _showSuccessToast("Item renamed.");
              } catch (e) {
                if (_isAuthOrPermissionError(e)) return;
                _showErrorToast("Failed to rename item.");
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => _safeCloseDialog(dialogContext),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () async {
                final newCode = ctrl.text.trim();
                _safeCloseDialog(dialogContext);

                if (newCode.isEmpty) return;

                try {
                  await _completeWriteQuickly(
                    _productsCol().doc(itemId).update({
                      "code": newCode,
                    }),
                  );

                  if (!mounted || _isSignedOut() || _handledSignedOut) return;
                  _showSuccessToast("Item renamed.");
                } catch (e) {
                  if (_isAuthOrPermissionError(e)) return;
                  _showErrorToast("Failed to rename item.");
                }
              },
              child: const Text("Save"),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _moveItem(String itemId) async {
    final fs = FirebaseFirestore.instance;

    final productRef = _productsCol().doc(itemId);
    final pSnap = await _tryGetDocCacheThenServer(productRef);
    if (pSnap == null || !pSnap.exists) return;

    final p = pSnap.data() ?? <String, dynamic>{};
    final code = (p["code"] ?? itemId).toString().trim();
    final String? oldFolderId = p["folderId"] as String?;

    String? newFolder;
    bool hasPicked = false;
    bool ignoreFirstCallback = true;

    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    await _showSafeDialog<void>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) {
          final bool canMove =
              hasPicked && newFolder != null && newFolder != oldFolderId;

          return AlertDialog(
            title: const Text("Move Item"),
            content: FolderPicker(
              tenantId: widget.tenantId,
              placeholder: "Select folder",
              allowTopLevel: false,
              currentFolderId: oldFolderId,
              preselectedFolder: null,
              onFolderSelected: (value) {
                if (ignoreFirstCallback) {
                  ignoreFirstCallback = false;
                  return;
                }

                setLocal(() {
                  hasPicked = true;
                  newFolder = value;
                });
              },
            ),
            actions: [
              TextButton(
                onPressed: () => _safeCloseDialog(dialogContext),
                child: const Text("Cancel"),
              ),
              TextButton(
                onPressed: canMove
                    ? () async {
                  final pickedFolder = newFolder;
                  _safeCloseDialog(dialogContext);

                  if (pickedFolder == null || pickedFolder == oldFolderId) {
                    return;
                  }

                  final uid =
                      FirebaseAuth.instance.currentUser?.uid ?? "";
                  String movedByName = "";
                  if (uid.isNotEmpty) {
                    final userSnap = await _tryGetDocCacheThenServer(
                      fs.collection("users").doc(uid),
                    );
                    final u = userSnap?.data() ?? <String, dynamic>{};
                    movedByName =
                        (u["name"] ?? "").toString().trim();
                  }

                  try {
                    final paths =
                    await FolderPaths.buildMovePathsNoRoot(
                      fs: fs,
                      tenantId: widget.tenantId,
                      oldParentId: oldFolderId,
                      newParentId: pickedFolder,
                      entityName: code.isEmpty ? "(item)" : code,
                    );

                    final pickedFolderSnap =
                    await _tryGetDocCacheThenServer(
                      _foldersCol().doc(pickedFolder),
                    );
                    final pickedFolderData =
                        pickedFolderSnap?.data() ?? <String, dynamic>{};
                    final pickedIsProtected =
                    _isProtectedFolder(pickedFolderData);

                    final batch = fs.batch();

                    final updateData = <String, dynamic>{
                      "folderId": pickedFolder,
                      "updatedAt": FieldValue.serverTimestamp(),
                    };

                    if (!pickedIsProtected) {
                      updateData["originalFolderId"] = pickedFolder;
                    }

                    batch.update(productRef, updateData);

                    batch.set(_movementHistoryCol().doc(), {
                      "type": "product",
                      "entityId": itemId,
                      "name": code,
                      "oldPathNames": paths["old"],
                      "newPathNames": paths["new"],
                      "movedAt": FieldValue.serverTimestamp(),
                      "movedBy": uid,
                      "movedByName": movedByName,
                    });

                    await _completeWriteQuickly(batch.commit());

                    if (!mounted || _isSignedOut() || _handledSignedOut) {
                      return;
                    }
                    _showSuccessToast("Item moved.");
                  } catch (e) {
                    if (_isAuthOrPermissionError(e)) return;
                    _showErrorToast("Failed to move item.");
                  }
                }
                    : null,
                child: const Text("Move"),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDeleteItem(String itemId, String code) async {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    await _showSafeDialog<void>(
      builder: (dialogContext) => AlertDialog(
        title: const Text("Delete Item"),
        content: Text('Are you sure you want to delete "$code"?'),
        actions: [
          TextButton(
            onPressed: () => _safeCloseDialog(dialogContext),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              _safeCloseDialog(dialogContext);

              try {
                await _completeWriteQuickly(
                  _productsCol().doc(itemId).delete(),
                );

                await OfflineMediaService.instance.deleteOfflineImage(
                  tenantId: widget.tenantId,
                  productId: itemId,
                );

                if (!mounted || _isSignedOut() || _handledSignedOut) return;
                _showSuccessToast("Item deleted.");
              } catch (e) {
                if (_isAuthOrPermissionError(e)) return;
                _showErrorToast("Failed to delete item.");
              }
            },
            child: const Text(
              "Delete",
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  void _onSearchChanged(String value) {
    final raw = value.trim().toLowerCase();

    _searchDebounce?.cancel();

    if (raw == _appliedSearchQuery) {
      if (_isSearchSettling) {
        setState(() => _isSearchSettling = false);
      }
      return;
    }

    if (!_isSearchSettling) {
      setState(() => _isSearchSettling = true);
    }

    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _isSignedOut() || _handledSignedOut) return;

      setState(() {
        _appliedSearchQuery = raw;
        _isSearchSettling = false;
      });

      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();

    if (!mounted) return;

    _searchController.clear();

    setState(() {
      _appliedSearchQuery = "";
      _isSearchSettling = false;
    });

    _searchFocusNode.requestFocus();
  }

  bool _matchesItemCode(String code, String query) {
    if (query.isEmpty) return true;
    final c = code.toLowerCase().trim();
    final q = query.toLowerCase().trim();

    return c == q || c.startsWith(q) || c.contains(q);
  }

  //folders section UI
  Widget _buildFoldersSection() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _foldersCol()
          .where("parentId", isEqualTo: widget.folderId)
          .orderBy("name")
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          if (_isAuthOrPermissionError(snap.error!)) {
            return const SizedBox.shrink();
          }

          if (!_foldersErrorShown) {
            _foldersErrorShown = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _isSignedOut() || _handledSignedOut) return;
              _showErrorToast("Failed to load folders.");
            });
          }

          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text("Failed to load folders."),
          );
        }

        _foldersErrorShown = false;

        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        final allFolders = snap.data!.docs;

        final folders = allFolders.where((f) {
          if (_appliedSearchQuery.isEmpty) return true;
          final name = (f.data()["name"] ?? "").toString().toLowerCase();
          return name.contains(_appliedSearchQuery);
        }).toList()
          ..sort(_folderSort);

        if (folders.isEmpty) {
          return const SizedBox.shrink();
        }

        return GridView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.all(12),
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _responsiveGridCount(context),
            mainAxisSpacing: 6,
            crossAxisSpacing: 20,
            childAspectRatio: 1.15,
          ),
          itemCount: folders.length,
          itemBuilder: (context, index) {
            final folder = folders[index];
            final folderId = folder.id;
            final folderData = folder.data();
            final folderName = (folderData["name"] ?? "").toString();
            final canManageFolder =
                _isAdmin && !_isProtectedFolder(folderData);

            return FolderGridTile(
              folderName: folderName,
              breadcrumb: "",
              isAdmin: canManageFolder,
              onTap: () {
                if (!mounted || _isSignedOut() || _handledSignedOut) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ItemsScreen(
                      folderId: folderId,
                      folderName: folderName,
                    ),
                  ),
                );
              },
              onRename: () => _renameFolder(folderId, folderName),
              onMove: () => _moveFolder(folderId),
              onDelete: () => _confirmDeleteFolder(folderId, folderName),
            );
          },
        );
      },
    );
  }

  //items section UI
  Widget _buildItemsSection() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _productsCol()
          .where("folderId", isEqualTo: widget.folderId)
          .orderBy("code")
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          if (_isAuthOrPermissionError(snap.error!)) {
            return const SizedBox.shrink();
          }

          if (!_itemsErrorShown) {
            _itemsErrorShown = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _isSignedOut() || _handledSignedOut) return;
              _showErrorToast("Failed to load items.");
            });
          }

          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text("Failed to load items."),
            ),
          );
        }

        _itemsErrorShown = false;

        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        final allItems = snap.data!.docs;
        final items = allItems.where((doc) {
          if (_appliedSearchQuery.isEmpty) return true;
          final data = doc.data();
          final code = (data["code"] ?? "").toString();
          return _matchesItemCode(code, _appliedSearchQuery);
        }).toList();

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _isSignedOut() || _handledSignedOut) return;
          unawaited(_prefetchVisibleProductImages(items: items));
        });

        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Center(
              child: Text(
                _appliedSearchQuery.isEmpty
                    ? "No items found."
                    : "No matching items found.",
              ),
            ),
          );
        }

        final itemIds = items.map((e) => e.id).toList();

        return GridView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.all(12),
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _responsiveGridCount(context),
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.65,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            final id = item.id;
            final data = item.data();

            return _ItemCard(
              tenantId: widget.tenantId,
              itemId: id,
              itemData: data,
              allItemIds: itemIds,
              initialIndex: index,
              isAdmin: _isAdmin,
              canCreateOrders: _canCreateOrders && !_isStorageManager,
              sizes: _sizes,
              onAdd: ({
                required int quantity,
                required String? size,
              }) async {
                return _addItemToActiveOrder(
                  productId: id,
                  code: (data["code"] ?? "").toString(),
                  quantity: quantity,
                  isTshirt: (data["isTshirt"] ?? false) == true,
                  size: size,
                );
              },
              onRename: () async => _renameItem(
                id,
                (data["code"] ?? "").toString(),
              ),
              onMove: () async => _moveItem(id),
              onDelete: () async => _confirmDeleteItem(
                id,
                (data["code"] ?? "").toString(),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

    return Scaffold(
      extendBody: true,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: const Color(0xff0B1E40),
        title: Text(
          widget.folderName,
          style: const TextStyle(color: Colors.white),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            if (!mounted) return;
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      floatingActionButtonLocation:
      _isAdmin ? FloatingActionButtonLocation.centerDocked : null,
      floatingActionButton: _isAdmin && !keyboardOpen
          ? FloatingActionButton(
        heroTag: null,
        backgroundColor: const Color(0xff0B1E40),
        onPressed: _showAddMenu,
        child: const Icon(
          Icons.add,
          size: 32,
          color: Colors.white,
        ),
      )
          : null,
      bottomNavigationBar: keyboardOpen
          ? null
          : RepaintBoundary(
        child: BottomNav(
          currentIndex: 1,
          hasFab: _isAdmin,
          isRootScreen: false,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            AppSearchBar(
              hint: "Search folders or items...",
              controller: _searchController,
              focusNode: _searchFocusNode,
              onChanged: _onSearchChanged,
              onClear: _clearSearch,
            ),
            if (_isSearchSettling)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                ScrollViewKeyboardDismissBehavior.manual,
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom + 120,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFoldersSection(),
                    _buildItemsSection(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemCard extends StatefulWidget {
  final String tenantId;
  final String itemId;
  final Map<String, dynamic> itemData;
  final List<String> allItemIds;
  final int initialIndex;
  final bool isAdmin;
  final bool canCreateOrders;
  final List<String> sizes;
  final Future<bool> Function({
  required int quantity,
  required String? size,
  }) onAdd;
  final Future<void> Function() onRename;
  final Future<void> Function() onMove;
  final Future<void> Function() onDelete;

  const _ItemCard({
    required this.tenantId,
    required this.itemId,
    required this.itemData,
    required this.allItemIds,
    required this.initialIndex,
    required this.isAdmin,
    required this.canCreateOrders,
    required this.sizes,
    required this.onAdd,
    required this.onRename,
    required this.onMove,
    required this.onDelete,
  });

  @override
  State<_ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<_ItemCard> {
  late int qty;
  late String selectedSize;
  bool showAddedTick = false;
  bool isSubmitting = false;
  Timer? _tickTimer;

  bool get isTshirt => (widget.itemData["isTshirt"] ?? false) == true;
  String get code => (widget.itemData["code"] ?? "").toString();
  String get imageUrl => (widget.itemData["imageUrl"] ?? "").toString().trim();
  int get _currentYear => DateTime.now().year;

  @override
  void initState() {
    super.initState();
    qty = 0;
    selectedSize = widget.sizes.first;
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  int _numToInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? "") ?? 0;
  }

  int _getAvailableStock({
    required Map<String, dynamic> productData,
    required Map<String, dynamic>? yearData,
    required bool isTshirt,
    required String selectedSize,
  }) {
    if (!isTshirt) {
      return _numToInt(productData["stockQuantity"]);
    }

    final Map<String, dynamic> currentSizeStock =
        (yearData?["currentSizeStock"] as Map?)?.cast<String, dynamic>() ?? {};

    if (currentSizeStock.containsKey(selectedSize)) {
      return _numToInt(currentSizeStock[selectedSize]);
    }

    final Map<String, dynamic> oldSizeStock =
        (productData["sizeStock"] as Map?)?.cast<String, dynamic>() ?? {};

    if (oldSizeStock.containsKey(selectedSize)) {
      return _numToInt(oldSizeStock[selectedSize]);
    }

    return 0;
  }

  void _triggerAddedTick() {
    _tickTimer?.cancel();

    if (!mounted) return;
    setState(() => showAddedTick = true);

    _tickTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => showAddedTick = false);
    });
  }

  Future<void> _handleAdd() async {
    if (qty <= 0 || isSubmitting || !widget.canCreateOrders) return;

    setState(() => isSubmitting = true);

    try {
      final added = await widget.onAdd(
        quantity: qty,
        size: isTshirt ? selectedSize : null,
      );

      if (!mounted) return;

      if (added) {
        setState(() => qty = 0);
        _triggerAddedTick();
      }
    } catch (_) {
      // Parent handles errors.
    } finally {
      if (mounted) {
        setState(() => isSubmitting = false);
      }
    }
  }

  Widget _buildQtyControls(int maxQty) {
    final bool canIncrease = qty < maxQty;
    final bool canDecrease = qty > 0;

    if (qty > maxQty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          qty = maxQty;
        });
      });
    }

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: canDecrease
                  ? () {
                setState(() => qty -= 1);
              }
                  : null,
            ),
            Text(
              qty.toString(),
              style: const TextStyle(fontSize: 18),
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: canIncrease
                  ? () {
                setState(() => qty += 1);
              }
                  : null,
            ),
            if (isTshirt) ...[
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(top: 9),
                child: SizedBox(
                  width: 68,
                  height: 32,
                  child: DropdownButtonFormField<String>(
                    value: selectedSize,
                    isDense: true,
                    isExpanded: true,
                    alignment: Alignment.center,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 6),
                      border: OutlineInputBorder(),
                    ),
                    items: widget.sizes
                        .map(
                          (s) => DropdownMenuItem<String>(
                        value: s,
                        child: Center(
                          child: Text(
                            s,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    )
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() {
                        selectedSize = v;
                      });
                    },
                  ),
                ),
              ),
            ],
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            "Available: $maxQty",
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade700,
            ),
          ),
        ),
        SizedBox(
          height: 46,
          child: qty > 0
              ? Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SizedBox(
              width: 120,
              child: ElevatedButton(
                onPressed: isSubmitting ? null : _handleAdd,
                child: isSubmitting
                    ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
                )
                    : const Text("Add"),
              ),
            ),
          )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final yearDocStream = FirebaseFirestore.instance
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("products")
        .doc(widget.itemId)
        .collection("stock_years")
        .doc(_currentYear.toString())
        .snapshots();

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ItemDetailsPagerScreen(
                          itemIds: widget.allItemIds,
                          initialIndex: widget.initialIndex,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    width: double.infinity,
                    decoration: const BoxDecoration(
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(12),
                      ),
                    ),
                    child: OfflineImageWidget(
                      tenantId: widget.tenantId,
                      productId: widget.itemId,
                      imageUrl: imageUrl.isEmpty ? null : imageUrl,
                      fit: BoxFit.cover,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(12),
                      ),
                      placeholder: Container(
                        color: Colors.grey.shade100,
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      errorWidget: Container(
                        color: Colors.grey.shade100,
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.image_outlined,
                          size: 56,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        code,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Positioned(
                      right: 10,
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          opacity: showAddedTick ? 1 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: const Icon(
                            Icons.check_circle,
                            color: Colors.green,
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.canCreateOrders)
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: yearDocStream,
                  builder: (context, snap) {
                    final yearData =
                        snap.data?.data() ?? <String, dynamic>{};

                    final maxQty = _getAvailableStock(
                      productData: widget.itemData,
                      yearData: yearData,
                      isTshirt: isTshirt,
                      selectedSize: selectedSize,
                    );

                    return _buildQtyControls(maxQty < 0 ? 0 : maxQty);
                  },
                )
              else
                const SizedBox(height: 46),
            ],
          ),
        ),
        if (widget.isAdmin)
          Positioned(
            right: -6,
            top: -6,
            child: PopupMenuButton<String>(
              onSelected: (value) async {
                if (!mounted) return;

                if (value == "rename") {
                  await widget.onRename();
                } else if (value == "move") {
                  await widget.onMove();
                } else if (value == "delete") {
                  await widget.onDelete();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: "rename",
                  child: Text("Rename"),
                ),
                PopupMenuItem(
                  value: "move",
                  child: Text("Move"),
                ),
                PopupMenuItem(
                  value: "delete",
                  child: Text("Delete"),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _OrderCreatePayload {
  final String name;
  final String? shopId;
  final String shopName;

  const _OrderCreatePayload({
    required this.name,
    required this.shopId,
    required this.shopName,
  });
}