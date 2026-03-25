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
import '../services/reconnect_sync_service.dart';
import '../services/tenant_context_service.dart';
import '../utils/folder_paths.dart';
import '../widgets/app_search_bar.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/folder_grid_tile.dart';
import '../widgets/folder_picker.dart';
import '../widgets/offline_image_widget.dart';
import '../widgets/top_toast.dart';
import 'items_screen.dart';
import 'new_folder_screen.dart';
import 'new_item_screen.dart';

class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  late final StreamSubscription<User?> _authSub;

  User? _currentUser;
  Future<_FilesBootstrapState>? _bootstrapFuture;

  @override
  void initState() {
    super.initState();
    ReconnectSyncService.instance.start(); //handles syncing pending offline actions when internet is restored
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

  //avoid memory leaks
  @override
  void dispose() {
    _authSub.cancel();
    super.dispose();
  }

  //error helpers
  bool _isAuthOrPermissionError(Object error) { //auth or permission error
    final msg = error.toString().toLowerCase();
    return msg.contains(TenantContextService.kSignedOutMessage.toLowerCase()) ||
        msg.contains("permission-denied") ||
        msg.contains("permission denied") ||
        msg.contains("unauthenticated") ||
        msg.contains("user is not signed in") ||
        msg.contains("requires authentication") ||
        msg.contains("user_signed_out");
  }

  Future<_FilesBootstrapState> _buildBootstrapForUser(User? user) async {
    if (user == null) {
      return const _FilesBootstrapState.signedOut();
    }

    final tenantContext = TenantContextService(); //create tenant content service

    try { //try to get user profile from cache memory only
      Map<String, dynamic>? profile =
      await tenantContext.tryGetCurrentUserProfileCacheOnly();

      //if profile not found in cache then load normally
      profile ??= await tenantContext.tryGetCurrentUserProfile();

      //if profile does not exist
      if (profile == null) {
        return const _FilesBootstrapState.error(
          message: "Failed to load your profile.",
        );
      }

      //extract tenantId and role
      final tenantId = (profile["tenantId"] ?? "").toString().trim();
      final role = (profile["role"] ?? "staff").toString().trim(); //default to staff if no role available

      if (tenantId.isEmpty) {
        return const _FilesBootstrapState.missingTenant();
      }

      return _FilesBootstrapState.ready(
        tenantId: tenantId,
        isAdmin: role == "admin",
      );
    } catch (e) {
      if (_isAuthOrPermissionError(e)) {
        return const _FilesBootstrapState.signedOut();
      }

      return _FilesBootstrapState.error(
        message: e.toString().replaceFirst("Exception: ", "").trim().isEmpty
            ? "Failed to load tenant."
            : e.toString().replaceFirst("Exception: ", "").trim(),
      );
    }
  }

  Widget _buildCenteredState({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Files",
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xff0B1E40),
        automaticallyImplyLeading: false,
        centerTitle: false,
        titleSpacing: 16,
      ),
      bottomNavigationBar: const BottomNav(
        currentIndex: 1,
        hasFab: false,
        isRootScreen: true,
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440), //contents does not become too wide
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
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Files",
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xff0B1E40),
        automaticallyImplyLeading: false,
        centerTitle: false,
        titleSpacing: 16,
      ),
      bottomNavigationBar: const BottomNav(
        currentIndex: 1,
        hasFab: false,
        isRootScreen: true,
      ),
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
    //uses and existing bootstrap future if already created
    final future = _bootstrapFuture ?? _buildBootstrapForUser(_currentUser);

    return FutureBuilder<_FilesBootstrapState>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildLoadingScaffold();
        }

        //fallback error state
        final state = snapshot.data ??
            const _FilesBootstrapState.error(
              message: "Failed to load Files screen.",
            );

        //if not sign in show message
        if (state.isSignedOut) {
          return _buildCenteredState(
            icon: Icons.lock_outline,
            title: "Not signed in",
            subtitle: "Please sign in to access your files.",
          );
        }

        //if no tenant then show message
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
            title: "Could not load Files",
            subtitle: state.message ?? "Something went wrong.",
            action: ElevatedButton( //retry button
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

        return _FilesContent(
          key: ValueKey<String>('files-${state.tenantId}-${state.isAdmin}'),
          tenantId: state.tenantId!,
          isAdmin: state.isAdmin,
        );
      },
    );
  }
}

class _FilesBootstrapState {
  final String? tenantId;
  final bool isAdmin;
  final bool isSignedOut;
  final bool isMissingTenant;
  final String? message;

  //private base constructor
  const _FilesBootstrapState._({
    required this.tenantId,
    required this.isAdmin,
    required this.isSignedOut,
    required this.isMissingTenant,
    required this.message,
  });

  //create ready state
  const _FilesBootstrapState.ready({
    required String tenantId,
    required bool isAdmin,
  }) : this._(
    tenantId: tenantId,
    isAdmin: isAdmin,
    isSignedOut: false,
    isMissingTenant: false,
    message: null,
  );

  //sign out constructor
  const _FilesBootstrapState.signedOut()
      : this._(
    tenantId: null,
    isAdmin: false,
    isSignedOut: true,
    isMissingTenant: false,
    message: null,
  );

  //missing tenant constructor
  const _FilesBootstrapState.missingTenant()
      : this._(
    tenantId: null,
    isAdmin: false,
    isSignedOut: false,
    isMissingTenant: true,
    message: null,
  );

  //error constructor
  const _FilesBootstrapState.error({
    required String message,
  }) : this._(
    tenantId: null,
    isAdmin: false,
    isSignedOut: false,
    isMissingTenant: false,
    message: message,
  );

  bool get isReady => tenantId != null && tenantId!.trim().isNotEmpty; //return true only if tenantId exist
}

class _FilesContent extends StatefulWidget {
  final String tenantId;
  final bool isAdmin;

  const _FilesContent({
    super.key,
    required this.tenantId,
    required this.isAdmin,
  });

  @override
  State<_FilesContent> createState() => _FilesContentState();
}

class _FilesContentState extends State<_FilesContent> {
  //constant
  static const Duration _searchDebounceDuration =
  Duration(milliseconds: 350);

  //controllers
  final ImagePicker _picker = ImagePicker(); //used for camera or gallery picking
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ValueNotifier<String> _liveSearchQuery = ValueNotifier<String>(""); //stores lived type text

  Timer? _searchDebounce;
  StreamSubscription<User?>? _authSub;

  bool _handledSignedOut = false;

  bool _topFoldersErrorShown = false;
  bool _searchFoldersErrorShown = false;
  bool _searchItemsErrorShown = false;

  final Set<String> _prefetchedProductIds = <String>{}; //store products whose offline image has been prefetch
  final Map<String, String> _folderBreadcrumbCache = <String, String>{};
  final Set<String> _folderBreadcrumbsLoading = <String>{};
  final Set<String> _deletingFolderIds = <String>{}; //track folders who have been deleted so they can be removed from UI

  String _appliedSearchQuery = ""; //query being used in search logic
  String _lastCompletedSearchQuery = ""; //latest query

  bool _isSearching = false;
  String? _folderSearchError;
  String? _itemSearchError;

  //list of folder search results
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _folderResults =
  <QueryDocumentSnapshot<Map<String, dynamic>>>[];
  //list of item search results
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _itemResults =
  <QueryDocumentSnapshot<Map<String, dynamic>>>[];

  int _searchRequestToken = 0;

  @override
  void initState() {
    super.initState();
    _listenToAuthChanges();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _authSub?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _liveSearchQuery.dispose();
    super.dispose();
  }

  //auth listener
  void _listenToAuthChanges() {
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted || _handledSignedOut) return;
      if (user == null) {
        _handledSignedOut = true;
      }
    });
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
        msg.contains("user_signed_out");
  }

  bool _isNetworkLikeError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains("cloud_firestore/unavailable") ||
        msg.contains("service is currently unavailable") ||
        msg.contains("unable to resolve host") ||
        msg.contains("firestore.googleapis.com") ||
        msg.contains("unknownhostexception") ||
        msg.contains("socketexception") ||
        msg.contains("failed host lookup");
  }

  //toast helpers
  void _showErrorToast(String message) {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;
    TopToast.error(context, message);
  }

  void _showSuccessToast(String message) {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;
    TopToast.success(context, message);
  }

  //firestore collection helpers
  CollectionReference<Map<String, dynamic>> _foldersRef() { //return firestore path to folders collection
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("folders");
  }

  CollectionReference<Map<String, dynamic>> _productsRef() { //return tenant’s products collection
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("products");
  }

  CollectionReference<Map<String, dynamic>> _movementHistoryRef() { //return tenant's movement history collection
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("movement_history");
  }

  //cache then server fetches
  Future<DocumentSnapshot<Map<String, dynamic>>> _getDocCacheThenServer(
      DocumentReference<Map<String, dynamic>> ref,
      ) async {
    try {
      final cached =
      await ref.get(const GetOptions(source: Source.cache)).timeout(
        const Duration(milliseconds: 500),
      );
      if (cached.exists) return cached;
    } catch (_) {}

    return ref.get().timeout(const Duration(milliseconds: 1500));
  }

  Future<QuerySnapshot<Map<String, dynamic>>> _getQueryCacheThenServer(
      Query<Map<String, dynamic>> query,
      ) async {
    try {
      final cached =
      await query.get(const GetOptions(source: Source.cache)).timeout(
        const Duration(milliseconds: 600),
      );
      if (cached.docs.isNotEmpty) return cached;
    } catch (_) {}

    return query.get().timeout(const Duration(milliseconds: 1800));
  }

  //check whether a folder is marked for delete
  bool _isFolderDeleting(String folderId) {
    return _deletingFolderIds.contains(folderId);
  }

  //remove deleted folder from list
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _filterOutDeletingFolders(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> folders,
      ) {
    return folders.where((d) => !_isFolderDeleting(d.id)).toList();
  }

  //responsive grid base on screen's width
  int _responsiveGridCount(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width >= 900) return 4;
    if (width >= 600) return 3;
    return 2;
  }

  //check if it a protected folder (Out of order folders)
  bool _isProtectedFolder(Map<String, dynamic> data) {
    return data["isSystemFolder"] == true ||
        (data["systemType"] ?? "").toString().trim() == "out_of_stock";
  }

  Future<bool> _isProtectedFolderById(String folderId) async {
    try {
      final snap = await _getDocCacheThenServer(_foldersRef().doc(folderId));
      final data = snap.data() ?? <String, dynamic>{};
      return _isProtectedFolder(data);
    } catch (_) {
      return false;
    }
  }

  //dialog closing helpers
  void _safeCloseDialog(NavigatorState navigator) { //closes dialog immediately
    if (navigator.mounted && navigator.canPop()) {
      navigator.pop();
    }
  }

  //avoid focus lifecycle issues
  void _safeCloseDialogAfterUnfocus(NavigatorState navigator) { //remove keyboard focus first
    FocusManager.instance.primaryFocus?.unfocus();

    WidgetsBinding.instance.addPostFrameCallback((_) { //then close dialog
      if (navigator.mounted && navigator.canPop()) {
        navigator.pop();
      }
    });
  }

  //image crop helper
  Future<XFile> _autoCenterCropTo4by3(
      XFile input, {
        int jpegQuality = 85, //crop it to 4:3 from the middle
      }) async {
    final Uint8List bytes = await input.readAsBytes(); //read raw bytes from the image

    img.Image? decoded = img.decodeImage(bytes); //decode bytes into editable image object
    if (decoded == null) {
      throw Exception("Could not read image data."); //decode fail message
    }

    decoded = img.bakeOrientation(decoded); //proper image orientation

    final int w = decoded.width;
    final int h = decoded.height;

    const double target = 4 / 3; //target aspect ratio 4:3

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

    //crop image
    final img.Image cropped = img.copyCrop(
      decoded,
      x: x,
      y: y,
      width: cropW,
      height: cropH,
    );

    final List<int> outJpg = img.encodeJpg(cropped, quality: jpegQuality); //re-encodes as JPEG with chosen quality

    //if on web then creates an in-memory x-file
    if (kIsWeb) {
      return XFile.fromData(
        Uint8List.fromList(outJpg),
        name: "cropped_4x3.jpg",
        mimeType: "image/jpeg",
      );
    } else { //on mobile save the image to temporary storage
      final dir = await getTemporaryDirectory();
      final path =
          "${dir.path}/cropped_4x3_${DateTime.now().millisecondsSinceEpoch}.jpg";
      final file = File(path);
      await file.writeAsBytes(outJpg, flush: true);
      return XFile(file.path);
    }
  }

  //when user chose camera or gallery
  Future<void> _pickAndOpenNewItem(ImageSource source) async {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    final navigator = Navigator.of(context);
    final focusScope = FocusScope.of(context);

    focusScope.unfocus(); //dismiss keyboard

    if (navigator.canPop()) {
      navigator.pop(); //closes bottom sheet
    }

    final XFile? picked = await _picker.pickImage(
      source: source,
      imageQuality: 100,
    );

    if (picked == null || !mounted || _isSignedOut() || _handledSignedOut) {
      return;
    }

    try {
      final XFile cropped =
      await _autoCenterCropTo4by3(picked, jpegQuality: 85);

      if (!mounted || _isSignedOut() || _handledSignedOut) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NewItemScreen(
            folderId: null,
            initialImage: cropped,
          ),
        ),
      );
    } catch (_) {
      if (!mounted || _isSignedOut() || _handledSignedOut) return;
      _showErrorToast( //crop error message
        "The image could not be processed. Please try another photo.",
      );
    }
  }

  //admin add action
  void _showAddMenu() {
    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    FocusScope.of(context).unfocus();

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)), //rounded corners
      ),
      builder: (sheetContext) { //inside the sheet
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
                  Navigator.of(sheetContext).pop(); //close bottom sheet
                  //open new item screen
                  if (!mounted || _isSignedOut() || _handledSignedOut) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const NewFolderScreen(),
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

  //prefetch products
  Future<void> _prefetchProducts( //pre-cache product images offline after search results

      //load folder breadcrumbs used in search
      List<QueryDocumentSnapshot<Map<String, dynamic>>> products,
      ) async {
    for (final p in products) {
      final productId = p.id;
      if (_prefetchedProductIds.contains(productId)) continue; //skip if cached

      final data = p.data();
      final imageUrl = (data["imageUrl"] ?? "").toString().trim();
      if (imageUrl.isEmpty) continue;

      _prefetchedProductIds.add(productId);

      unawaited(
        OfflineMediaService.instance.ensureOfflineImage(
          tenantId: widget.tenantId,
          productId: productId,
          imageUrl: imageUrl,
        ),
      );
    }
  }

  Future<void> _ensureFolderBreadcrumbsLoaded(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> folders,
      ) async {
    for (final folder in folders) {
      final folderId = folder.id;
      if (_folderBreadcrumbCache.containsKey(folderId) ||
          _folderBreadcrumbsLoading.contains(folderId)) {
        continue;
      }

      _folderBreadcrumbsLoading.add(folderId);

      unawaited(() async {
        try {
          final parts = await FolderPaths.getFolderBreadcrumbForFolderDoc(
            FirebaseFirestore.instance,
            widget.tenantId,
            folder,
          );

          if (!mounted || _handledSignedOut || _isSignedOut()) return;

          final nextValue = parts.join(" > ");
          if (_folderBreadcrumbCache[folderId] != nextValue) {
            setState(() {
              _folderBreadcrumbCache[folderId] = nextValue;
            });
          }
        } catch (_) {
          if (!mounted || _handledSignedOut || _isSignedOut()) return;

          if (_folderBreadcrumbCache[folderId] != "") {
            setState(() {
              _folderBreadcrumbCache[folderId] = "";
            });
          }
        } finally {
          _folderBreadcrumbsLoading.remove(folderId);
        }
      }());
    }
  }

  //rename folder
  Future<void> _renameFolder(String folderId, String currentName) async {
    if (_isFolderDeleting(folderId)) {
      _showErrorToast("This folder is already being deleted.");
      return;
    }

    if (await _isProtectedFolderById(folderId)) {
      _showErrorToast("Out of stock folders cannot be renamed.");
      return;
    }

    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    final ctrl = TextEditingController(text: currentName); //prefilled with current name

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          final dialogNavigator = Navigator.of(dialogContext);

          return AlertDialog(
            title: const Text("Rename Folder"),
            content: TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: "New Folder Name"),
              textInputAction: TextInputAction.done,
              autofocus: true,
              onSubmitted: (_) async {
                final newName = ctrl.text.trim();
                _safeCloseDialogAfterUnfocus(dialogNavigator);

                if (newName.isEmpty) return; //ignore empty name

                try {
                  await _foldersRef().doc(folderId).update({"name": newName}); //update firestore folder document
                  if (!mounted || _isSignedOut() || _handledSignedOut) return;
                  _showSuccessToast("Folder renamed."); //success toast
                } catch (e) {
                  if (_isAuthOrPermissionError(e)) return;
                  if (!mounted || _isSignedOut() || _handledSignedOut) return;
                  _showErrorToast("Failed to rename folder."); //rename error
                }
              },
            ),
            actions: [ //cancel button
              TextButton(
                onPressed: () => _safeCloseDialogAfterUnfocus(dialogNavigator),
                child: const Text("Cancel"),
              ),
              TextButton(
                onPressed: () async {
                  final newName = ctrl.text.trim();
                  _safeCloseDialogAfterUnfocus(dialogNavigator);

                  if (newName.isEmpty) return;

                  try {
                    await _foldersRef().doc(folderId).update({"name": newName});
                    if (!mounted || _isSignedOut() || _handledSignedOut) return;
                    _showSuccessToast("Folder renamed.");
                  } catch (e) {
                    if (_isAuthOrPermissionError(e)) return;
                    if (!mounted || _isSignedOut() || _handledSignedOut) return;
                    _showErrorToast("Failed to rename folder.");
                  }
                },
                child: const Text("Save"),
              ),
            ],
          );
        },
      );
    } finally {
      ctrl.dispose(); //dispose controller
    }
  }

  //move folder
  Future<void> _moveFolder(String folderId) async {
    if (_isFolderDeleting(folderId)) {
      _showErrorToast("This folder is already being deleted.");
      return;
    }

    if (await _isProtectedFolderById(folderId)) {
      _showErrorToast("Out of stock folders cannot be moved.");
      return;
    }

    final fs = FirebaseFirestore.instance;

    //load current folder document
    DocumentSnapshot<Map<String, dynamic>> folderSnap;
    try {
      folderSnap = await _getDocCacheThenServer(_foldersRef().doc(folderId));
    } catch (e) {
      if (_isAuthOrPermissionError(e)) return;
      _showErrorToast("Failed to load folder.");
      return;
    }

    if (!folderSnap.exists) return; //if folder no longer exist stop

    //read current folder data
    final f = folderSnap.data() ?? <String, dynamic>{};
    final String? oldParentId = f["parentId"] as String?;
    final bool isAlreadyTopLevel = oldParentId?.isEmpty ?? true;
    final String folderName = (f["name"] ?? "").toString().trim();

    String? newParent;
    bool hasPicked = false;
    bool ignoreFirstCallback = true;

    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final dialogNavigator = Navigator.of(dialogContext);

        return StatefulBuilder(
          builder: (dialogContext, setLocal) {
            final canMove = hasPicked && newParent != oldParentId;
            final maxH = MediaQuery.of(dialogContext).size.height * 0.55;

            return AlertDialog(
              title: const Text("Move Folder"),
              content: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxH, maxWidth: 520),
                child: SingleChildScrollView(
                  child: SizedBox(
                    width: double.maxFinite,
                    child: FolderPicker(
                      tenantId: widget.tenantId,
                      placeholder: "Select folder",
                      //folder picker configuration
                      allowTopLevel: !isAlreadyTopLevel,
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
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      _safeCloseDialogAfterUnfocus(dialogNavigator),
                  child: const Text("Cancel"),
                ),
                TextButton(
                  onPressed: canMove
                      ? () async {
                    final pickedParent = newParent;
                    if (pickedParent == oldParentId) {
                      _safeCloseDialogAfterUnfocus(dialogNavigator);
                      return;
                    }

                    final uid = FirebaseAuth.instance.currentUser?.uid ?? "";
                    String movedByName = "";

                    if (uid.isNotEmpty) {
                      try {
                        final userSnap = await _getDocCacheThenServer(
                          fs.collection("users").doc(uid),
                        );
                        final u = userSnap.data() ?? {};
                        movedByName = (u["name"] ?? "").toString().trim();
                      } catch (_) {}
                    }

                    _safeCloseDialogAfterUnfocus(dialogNavigator);

                    try {
                      final paths =
                      await FolderPaths.buildMovePathsNoRoot(
                        fs: fs,
                        tenantId: widget.tenantId,
                        oldParentId: oldParentId,
                        newParentId: pickedParent,
                        entityName:
                        folderName.isEmpty ? "(folder)" : folderName,
                      );

                      final batch = fs.batch();
                      final folderRef = _foldersRef().doc(folderId);

                      batch.update(folderRef, {"parentId": pickedParent});
                      batch.set(_movementHistoryRef().doc(), {
                        "type": "folder",
                        "entityId": folderId,
                        "name": folderName,
                        "oldPathNames": paths["old"],
                        "newPathNames": paths["new"],
                        "movedAt": FieldValue.serverTimestamp(),
                        "movedBy": uid,
                        "movedByName": movedByName,
                      });

                      await batch.commit();
                      if (!mounted || _isSignedOut() || _handledSignedOut) {
                        return;
                      }
                      _showSuccessToast("Folder moved.");
                    } catch (e) {
                      if (_isAuthOrPermissionError(e)) return;
                      if (!mounted || _isSignedOut() || _handledSignedOut) {
                        return;
                      }
                      _showErrorToast("Failed to move folder.");
                    }
                  }
                      : null,
                  child: const Text("Move"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  //
  Future<Set<String>> _collectFolderAndDescendantIds(String folderId) async {
    final ids = <String>{folderId}; //start with current folder

    final subsnap = await _getQueryCacheThenServer( //find direct children
      _foldersRef().where("parentId", isEqualTo: folderId),
    );

    for (final sub in subsnap.docs) { //include all descendants recursively
      final childIds = await _collectFolderAndDescendantIds(sub.id);
      ids.addAll(childIds);
    }

    return ids;
  }

  //delete folder recursively
  Future<void> _deleteFolderRecursive(String folderId) async {
    final itemsSnap = await _getQueryCacheThenServer(
      _productsRef().where("folderId", isEqualTo: folderId),
    );

    for (final item in itemsSnap.docs) {
      //delete offline cache image first, then delete firestore product
      await OfflineMediaService.instance.deleteOfflineImage(
        tenantId: widget.tenantId,
        productId: item.id,
      );
      await item.reference.delete();
    }

    //delete subfolders
    final subsnap = await _getQueryCacheThenServer(
      _foldersRef().where("parentId", isEqualTo: folderId),
    );

    for (final sub in subsnap.docs) {
      await _deleteFolderRecursive(sub.id);
    }

    //delete current folder
    await _foldersRef().doc(folderId).delete();
  }

  Future<void> _queueDeleteFolder(String folderId, String folderName) async {
    if (_isFolderDeleting(folderId)) {
      _showErrorToast("Delete already queued for this folder.");
      return;
    }

    Set<String> idsToHide = <String>{folderId}; //hide current folder

    try { //collect descendants so they can be hidden too
      idsToHide = await _collectFolderAndDescendantIds(folderId);
    } catch (_) {
      idsToHide = <String>{folderId};
    }

    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    //mark as deleted and remove from visible search results
    setState(() {
      _deletingFolderIds.addAll(idsToHide);
      _folderResults = _folderResults
          .where((d) => !_deletingFolderIds.contains(d.id))
          .toList();
    });

    //actually perform recursive deletion
    try {
      await _deleteFolderRecursive(folderId);

      if (!mounted || _isSignedOut() || _handledSignedOut) return;
      _showSuccessToast('"$folderName" delete queued.'); //show success toast
    } catch (e) {
      if (!mounted || _isSignedOut() || _handledSignedOut) return;

      setState(() {
        for (final id in idsToHide) {
          _deletingFolderIds.remove(id);
        }
      });

      final message = e.toString().replaceFirst("Exception: ", "").trim();
      _showErrorToast(
        message.isEmpty ? "Failed to delete folder." : message,
      );
    }
  }

  //confirm delete dialog
  Future<void> _confirmDeleteFolder(String folderId, String folderName) async {
    if (_isFolderDeleting(folderId)) {
      _showErrorToast("Delete already queued for this folder.");
      return;
    }

    if (await _isProtectedFolderById(folderId)) {
      _showErrorToast("Out of stock folders cannot be deleted.");
      return;
    }

    if (!mounted || _isSignedOut() || _handledSignedOut) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final dialogNavigator = Navigator.of(dialogContext);

        return AlertDialog(
          title: const Text("Delete Folder"),
          content: Text(
            'Are you sure you want to delete "$folderName" and ALL its contents?',
          ),
          actions: [
            TextButton(
              onPressed: () => _safeCloseDialog(dialogNavigator),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () async {
                _safeCloseDialog(dialogNavigator);
                await _queueDeleteFolder(folderId, folderName);
              },
              child: const Text(
                "Delete",
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        );
      },
    );
  }

  //search folders of any depth
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _searchFoldersAnyDepth(
      String q,
      ) async {
    final qLower = q.toLowerCase(); //case-insensitive
    final snap = await _getQueryCacheThenServer(
      _foldersRef().orderBy("name"), //ordered by name
    );

    return snap.docs.where((d) {
      final data = d.data();
      final name = (data["name"] ?? "").toString().toLowerCase();
      return name.contains(qLower);
    }).toList();
  }

  //search products by code
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _searchProductsByCode(
      String qRaw,
      ) async {
    final q = qRaw.trim();
    if (q.isEmpty) return <QueryDocumentSnapshot<Map<String, dynamic>>>[];

    //uses map so exact and prefix result does not duplicate items
    final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> map =
    <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};

    final exactQuery = _productsRef().where("code", isEqualTo: q).limit(20); //find exact code matches

    try { //add exact matches to map
      final exactSnap = await _getQueryCacheThenServer(exactQuery);
      for (final d in exactSnap.docs) {
        map[d.id] = d;
      }
    } catch (_) {}

    //prefix search
    final start = q;
    final end = "$start\uf8ff";

    final prefixQuery = _productsRef()
        .orderBy("code")
        .startAt([start])
        .endAt([end])
        .limit(20);

    final prefixSnap = await _getQueryCacheThenServer(prefixQuery);
    for (final d in prefixSnap.docs) {
      map[d.id] = d;
    }

    //prefetch images and return results
    final results = map.values.toList();
    await _prefetchProducts(results);
    return results;
  }

  //debounce search
  Future<void> _runDebouncedSearch(String rawValue) async {
    _searchDebounce?.cancel();

    final next = rawValue.trim();
    if (_liveSearchQuery.value != next) { //update live search value
      _liveSearchQuery.value = next;
    }

    _searchDebounce = Timer(_searchDebounceDuration, () {
      if (!mounted || _isSignedOut() || _handledSignedOut) return;

      if (next == _appliedSearchQuery) return;

      if (next.isEmpty) {
        setState(() {
          _appliedSearchQuery = "";
          _lastCompletedSearchQuery = "";
          _isSearching = false;
          _folderSearchError = null;
          _itemSearchError = null;
          _folderResults = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
          _itemResults = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
        });
        if (mounted) {
          _searchFocusNode.requestFocus();
        }
        return;
      }

      _performSearch(next);
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  //perform search
  Future<void> _performSearch(String query) async {
    final int token = ++_searchRequestToken; //create unique token to avoid old async results

    setState(() {
      _appliedSearchQuery = query;
      _isSearching = true;
      _folderSearchError = null;
      _itemSearchError = null;
    });

    try { //run both search in parallel
      final results = await Future.wait<
          List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
        [
          _searchFoldersAnyDepth(query),
          _searchProductsByCode(query),
        ],
      );

      if (!mounted || _isSignedOut() || _handledSignedOut) return;
      if (token != _searchRequestToken) return;

      //separate results
      final folders =
      List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(results[0]);
      final items =
      List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(results[1]);

      setState(() {
        _folderResults = _filterOutDeletingFolders(folders);
        _itemResults = items;
        _lastCompletedSearchQuery = query;
        _isSearching = false;
      });

      await _ensureFolderBreadcrumbsLoaded(_folderResults);
    } catch (e) {
      if (!mounted || _isSignedOut() || _handledSignedOut) return;
      if (token != _searchRequestToken) return;

      if (_isAuthOrPermissionError(e)) {
        setState(() {
          _isSearching = false;
        });
        return;
      }

      setState(() {
        _isSearching = false;
        _folderSearchError = _isNetworkLikeError(e)
            ? "Folder search is unavailable right now."
            : "Failed to search folders.";
        _itemSearchError = _isNetworkLikeError(e)
            ? "Item search is unavailable right now."
            : "Failed to search items.";
      });

      if (!_searchFoldersErrorShown) {
        _searchFoldersErrorShown = true;
        _showErrorToast(_folderSearchError!);
      }
      if (!_searchItemsErrorShown) {
        _searchItemsErrorShown = true;
        _showErrorToast(_itemSearchError!);
      }
    }
  }

  //open folder that the item belong to
  Future<void> _openFolderFromProduct(
      QueryDocumentSnapshot<Map<String, dynamic>> productDoc,
      ) async {
    final data = productDoc.data();
    final folderId = (data["folderId"] ?? "").toString(); //get folderId from item

    if (folderId.isEmpty || _isFolderDeleting(folderId)) return;

    try {
      final folderSnap =
      await _getDocCacheThenServer(_foldersRef().doc(folderId));
      final f = folderSnap.data() ?? <String, dynamic>{};
      final folderName = (f["name"] ?? "").toString().trim();

      if (!mounted || _isSignedOut() || _handledSignedOut) return;

      //open ItemScreen for that folder
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ItemsScreen(
            folderId: folderId,
            folderName: folderName.isEmpty ? "Folder" : folderName,
          ),
        ),
      );
    } catch (e) {
      if (_isAuthOrPermissionError(e)) return;
      _showErrorToast("Failed to open folder.");
    }
  }

  Widget _buildSearchProductCard(
      QueryDocumentSnapshot<Map<String, dynamic>> p,
      ) {
    final d = p.data(); //product data

    final code = (d["code"] ?? "").toString();
    final stock = (d["stockQuantity"] ?? "").toString();
    final imageUrl = (d["imageUrl"] ?? "").toString();
    final folderId = (d["folderId"] ?? "").toString();

    final breadcrumb = _folderBreadcrumbCache[folderId] ?? "";

    if (folderId.isNotEmpty &&
        !_folderBreadcrumbCache.containsKey(folderId) &&
        !_folderBreadcrumbsLoading.contains(folderId) &&
        !_isFolderDeleting(folderId)) {
      _folderBreadcrumbsLoading.add(folderId);

      unawaited(() async {
        try {
          final parts = await FolderPaths.getFolderBreadcrumbFromFolderId(
            FirebaseFirestore.instance,
            widget.tenantId,
            folderId,
          );

          if (!mounted || _handledSignedOut || _isSignedOut()) return;

          final nextValue = parts.join(" > ");
          if (_folderBreadcrumbCache[folderId] != nextValue) {
            setState(() {
              _folderBreadcrumbCache[folderId] = nextValue;
            });
          }
        } catch (_) {
          if (!mounted || _handledSignedOut || _isSignedOut()) return;

          if (_folderBreadcrumbCache[folderId] != "") {
            setState(() {
              _folderBreadcrumbCache[folderId] = "";
            });
          }
        } finally {
          _folderBreadcrumbsLoading.remove(folderId);
        }
      }());
    }

    return GestureDetector(
      onTap: () => _openFolderFromProduct(p),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius:
                const BorderRadius.vertical(top: Radius.circular(12)),
                child: imageUrl.isNotEmpty
                    ? OfflineImageWidget(
                  tenantId: widget.tenantId,
                  productId: p.id,
                  imageUrl: imageUrl,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  errorWidget: Container(
                    color: Colors.grey.shade100,
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.inventory_2_outlined,
                      size: 60,
                      color: Colors.grey,
                    ),
                  ),
                )
                    : Container(
                  color: Colors.grey.shade100,
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.inventory_2,
                    size: 60,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                code.isEmpty ? "(no code)" : code,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (breadcrumb.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Text(
                  breadcrumb,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.black54,
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                stock.isEmpty ? "" : "Stock: $stock",
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopFoldersSection() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _foldersRef()
          .where("parentId", isNull: true)
          .orderBy("name")
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          if (_isAuthOrPermissionError(snapshot.error!)) {
            return const SizedBox.shrink();
          }

          if (!_topFoldersErrorShown) {
            _topFoldersErrorShown = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              //error handling
              if (!mounted || _isSignedOut() || _handledSignedOut) return;
              _showErrorToast("Failed to load folders.");
            });
          }

          return const Padding(
            padding: EdgeInsets.only(top: 30),
            child: Center(
              child: Text("Failed to load folders."),
            ),
          );
        }

        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.only(top: 30),
            child: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        _topFoldersErrorShown = false;

        final folders = snapshot.data!.docs
            .where((folder) => !_isFolderDeleting(folder.id))
            .toList();

        if (folders.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.only(top: 24),
              child: Text("No folders found"),
            ),
          );
        }

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          itemCount: folders.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _responsiveGridCount(context),
            mainAxisSpacing: 6,
            crossAxisSpacing: 20,
            childAspectRatio: 1.15,
          ),
          itemBuilder: (context, index) {
            final folder = folders[index];
            final folderId = folder.id;
            final folderData = folder.data();
            final folderName = (folderData["name"] ?? "").toString();
            final canManageFolder =
                widget.isAdmin && !_isProtectedFolder(folderData);

            return FolderGridTile(
              folderName: folderName,
              breadcrumb: "",
              isAdmin: canManageFolder,
              onTap: () {
                if (_isFolderDeleting(folderId)) return;

                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ItemsScreen(
                      folderId: folderId,
                      folderName: folderName,
                    ),
                  ),
                );
              },
              onRename: () async {
                if (!mounted || _isSignedOut() || _isFolderDeleting(folderId)) {
                  return;
                }
                await _renameFolder(folderId, folderName);
              },
              onMove: () async {
                if (!mounted || _isSignedOut() || _isFolderDeleting(folderId)) {
                  return;
                }
                await _moveFolder(folderId);
              },
              onDelete: () async {
                if (!mounted || _isSignedOut() || _isFolderDeleting(folderId)) {
                  return;
                }
                await _confirmDeleteFolder(folderId, folderName);
              },
            );
          },
        );
      },
    );
  }

  Widget _buildFolderResultsSection() {
    if (_folderSearchError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
        child: Text(_folderSearchError!),
      );
    }

    final visibleFolders =
    _folderResults.where((folder) => !_isFolderDeleting(folder.id)).toList();

    if (visibleFolders.isEmpty &&
        !_isSearching &&
        _lastCompletedSearchQuery == _appliedSearchQuery) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 6, 16, 16),
        child: Text("No folder results"),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
      itemCount: visibleFolders.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _responsiveGridCount(context),
        mainAxisSpacing: 10,
        crossAxisSpacing: 20,
        childAspectRatio: 1.05,
      ),
      itemBuilder: (context, index) {
        final folder = visibleFolders[index];
        final folderId = folder.id;
        final f = folder.data();
        final folderName = (f["name"] ?? "").toString();
        final canManageFolder = widget.isAdmin && !_isProtectedFolder(f);
        final breadcrumb = _folderBreadcrumbCache[folderId] ?? "";

        return FolderGridTile(
          folderName: folderName,
          breadcrumb: breadcrumb,
          isAdmin: canManageFolder,
          iconSize: 110,
          onTap: () {
            if (_isFolderDeleting(folderId)) return;

            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ItemsScreen(
                  folderId: folderId,
                  folderName: folderName,
                ),
              ),
            );
          },
          onRename: () async {
            if (!mounted || _isSignedOut() || _isFolderDeleting(folderId)) {
              return;
            }
            await _renameFolder(folderId, folderName);
          },
          onMove: () async {
            if (!mounted || _isSignedOut() || _isFolderDeleting(folderId)) {
              return;
            }
            await _moveFolder(folderId);
          },
          onDelete: () async {
            if (!mounted || _isSignedOut() || _isFolderDeleting(folderId)) {
              return;
            }
            await _confirmDeleteFolder(folderId, folderName);
          },
        );
      },
    );
  }

  Widget _buildItemResultsSection() {
    if (_itemSearchError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
        child: Text(_itemSearchError!),
      );
    }

    if (_itemResults.isEmpty &&
        !_isSearching &&
        _lastCompletedSearchQuery == _appliedSearchQuery) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 6, 16, 16),
        child: Text("No item results"),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
      itemCount: _itemResults.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _responsiveGridCount(context),
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 1.05,
      ),
      itemBuilder: (context, index) {
        return _buildSearchProductCard(_itemResults[index]);
      },
    );
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    _liveSearchQuery.value = "";

    if (!mounted) return;

    setState(() {
      _appliedSearchQuery = "";
      _lastCompletedSearchQuery = "";
      _isSearching = false;
      _folderSearchError = null;
      _itemSearchError = null;
      _folderResults = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      _itemResults = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    });

    _searchFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

    return ValueListenableBuilder<String>(
      valueListenable: _liveSearchQuery,
      builder: (context, _, __) {
        final currentHasSearch = _appliedSearchQuery.isNotEmpty ||
            _liveSearchQuery.value.trim().isNotEmpty;

        return PopScope(
          canPop: false,
          child: Scaffold(
            resizeToAvoidBottomInset: true,
            appBar: AppBar(
              title: const Text(
                "Files",
                style: TextStyle(color: Colors.white),
              ),
              backgroundColor: const Color(0xff0B1E40),
              centerTitle: false,
              titleSpacing: 16,
              automaticallyImplyLeading: false,
              leadingWidth: 0,
              leading: null,
            ),
            //if admin fab is centered
            floatingActionButtonLocation: widget.isAdmin
                ? FloatingActionButtonLocation.centerDocked
                : null,
            floatingActionButton: widget.isAdmin && !keyboardOpen
                ? FloatingActionButton(
              heroTag: null,
              backgroundColor: const Color(0xff0B1E40),
              onPressed: _showAddMenu, //show sheet
              child: const Icon(Icons.add, color: Colors.white, size: 32),
            )
                : null,
            bottomNavigationBar: keyboardOpen
                ? null
                : BottomNav(
              currentIndex: 1,
              hasFab: widget.isAdmin,
              isRootScreen: true,
            ),
            body: SafeArea(
              child: Column(
                children: [
                  AppSearchBar(
                    hint: "Search folders or item code...",
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    onChanged: _runDebouncedSearch,
                    onClear: _clearSearch,
                  ),
                  if (_isSearching && currentHasSearch)
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
                          if (!currentHasSearch) _buildTopFoldersSection(),
                          if (currentHasSearch) ...[
                            const Padding(
                              padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
                              child: Text(
                                "Folders",
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            _buildFolderResultsSection(),
                            const Padding(
                              padding: EdgeInsets.fromLTRB(16, 6, 16, 6),
                              child: Text(
                                "Items (by code)",
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            _buildItemResultsSection(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}