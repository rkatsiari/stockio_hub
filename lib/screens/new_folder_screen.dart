//create a new folder and a system generated out of stock folder
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/tenant_context_service.dart';
import '../widgets/folder_picker.dart';
import '../widgets/top_toast.dart';

class NewFolderScreen extends StatefulWidget {
  final String? parentId;

  const NewFolderScreen({super.key, this.parentId});

  @override
  State<NewFolderScreen> createState() => _NewFolderScreenState();
}

class _NewFolderScreenState extends State<NewFolderScreen> {
  final TextEditingController nameCtrl = TextEditingController();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  late final Future<String> _tenantIdFuture;

  StreamSubscription<User?>? _authSub;

  String? selectedParent;
  bool _isSaving = false;
  bool _handledSignedOut = false;
  bool _didClose = false;

  @override
  void initState() {
    super.initState();
    selectedParent = widget.parentId;
    _tenantIdFuture = TenantContextService().getTenantIdOrThrow();
    _listenToAuthChanges();
  }

  void _listenToAuthChanges() {
    _authSub = _auth.authStateChanges().listen((user) {
      if (!mounted || _handledSignedOut || _didClose) return;

      if (user == null) {
        _handledSignedOut = true;
        _popSafely();
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    nameCtrl.dispose();
    super.dispose();
  }

  //capitalise folder name and clean it
  String _capitalizeFirst(String text) {
    final cleaned = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.isEmpty) return cleaned;
    return cleaned[0].toUpperCase() + cleaned.substring(1);
  }

  //clean error message
  String _cleanErr(Object e) {
    return e.toString().replaceFirst('Exception: ', '').trim();
  }

  //unfocus keyboard
  void _unfocusSafely() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _showError(String message) {
    if (!mounted || _handledSignedOut || _didClose) return;
    TopToast.error(context, message);
  }

  void _showSuccess(String message) {
    if (!mounted || _handledSignedOut || _didClose) return;
    TopToast.success(context, message);
  }

  void _popSafely([dynamic result]) {
    if (!mounted || _didClose) return;
    _didClose = true;
    _unfocusSafely();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop(result);
      }
    });
  }

  Future<void> createFolder(String tenantId) async {
    if (_isSaving || _didClose || _handledSignedOut) return;

    //check login user
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      _showError("You must be logged in.");
      return;
    }

    //validate name
    final folderName = _capitalizeFirst(nameCtrl.text);

    if (folderName.isEmpty) {
      _showError("Please enter a folder name.");
      return;
    }

    _unfocusSafely();

    if (mounted) {
      setState(() => _isSaving = true);
    }

    try {
      final fs = FirebaseFirestore.instance;
      final foldersCol = fs
          .collection("tenants")
          .doc(tenantId)
          .collection("folders");

      final mainFolderRef = foldersCol.doc();
      final outOfStockRef = foldersCol.doc();

      final batch = fs.batch(); //use a batch write so both folder documents are written together

      batch.set(mainFolderRef, {
        "name": folderName,
        "parentId": selectedParent,
        "createdAt": FieldValue.serverTimestamp(),
        "isSystemFolder": false,
        "systemType": null,
      });

      batch.set(outOfStockRef, {
        "name": "Out of stock",
        "parentId": mainFolderRef.id,
        "createdAt": FieldValue.serverTimestamp(),
        "isSystemFolder": true,
        "systemType": "out_of_stock",
      });

      final commitFuture = batch.commit();

      var commitFinishedQuickly = false;
      try {
        await commitFuture.timeout(const Duration(milliseconds: 700));
        commitFinishedQuickly = true;
      } catch (_) {
        commitFinishedQuickly = false;
      }

      if (!mounted || _handledSignedOut || _didClose) return;

      _showSuccess(
        commitFinishedQuickly
            ? "Folder created successfully."
            : "Folder saved offline and will sync automatically.",
      );

      _popSafely(true);

      if (!commitFinishedQuickly) {
        unawaited(
          commitFuture.catchError((_) {
          }),
        );
      }
    } catch (e) { //error handling
      if (!mounted || _handledSignedOut || _didClose) return;

      final msg = _cleanErr(e);
      _showError(
        msg.isEmpty ? "Failed to create folder. Please try again." : msg,
      );

      if (mounted && !_handledSignedOut && !_didClose) {
        setState(() => _isSaving = false);
      }
    }
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: const Text(
        "Create Folder",
        style: TextStyle(color: Colors.white),
      ),
      backgroundColor: const Color(0xff0B1E40),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: _isSaving
            ? null
            : () {
          _unfocusSafely();
          _popSafely();
        },
      ),
    );
  }

  Widget _buildLoadingState() {
    return Scaffold(
      appBar: _buildAppBar(),
      resizeToAvoidBottomInset: true,
      body: const SafeArea(
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Widget _buildErrorState(Object? error) {
    final message = error == null
        ? "Failed to load tenant."
        : error.toString().replaceFirst("Exception: ", "").trim();

    return Scaffold(
      appBar: _buildAppBar(),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              message.isEmpty ? "Failed to load tenant." : message,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyboardBottom = MediaQuery.of(context).viewInsets.bottom;

    return FutureBuilder<String>(
      future: _tenantIdFuture,
      builder: (context, tenantSnap) {
        if (tenantSnap.connectionState == ConnectionState.waiting) {
          return _buildLoadingState();
        }

        if (tenantSnap.hasError || !tenantSnap.hasData) {
          return _buildErrorState(tenantSnap.error);
        }

        final tenantId = tenantSnap.data!;

        return Scaffold(
          resizeToAvoidBottomInset: true,
          appBar: _buildAppBar(),
          body: SafeArea(
            child: GestureDetector( //if the user taps outside fields, the keyboard closes
              onTap: _unfocusSafely,
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.fromLTRB(20, 20, 20,
                  keyboardBottom > 0 ? keyboardBottom + 20 : 20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      enabled: !_isSaving,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        labelText: "Folder Name",
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) {
                        if (!_isSaving) {
                          createFolder(tenantId);
                        }
                      },
                    ),
                    const SizedBox(height: 20),
                    IgnorePointer( //cannot be changed during saving
                      ignoring: _isSaving,
                      //user choose which folder the new folder goes inside
                      child: FolderPicker(
                        tenantId: tenantId,
                        preselectedFolder: widget.parentId,
                        onFolderSelected: (folderId) {
                          if (!mounted || _didClose) return;
                          setState(() {
                            selectedParent = folderId;
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _isSaving ? null : () => createFolder(tenantId),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xff0B1E40),
                          foregroundColor: Colors.white,
                        ),
                        child: _isSaving
                            ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                            : const Text("Create Folder"),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}