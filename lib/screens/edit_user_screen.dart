//edit details of an existing user
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../widgets/top_toast.dart';

class EditUserScreen extends StatefulWidget {
  //values pass into the screen
  final String tenantId;
  final String uid;
  final String name;
  final String email;
  final String role;

  //constructor with require fields
  const EditUserScreen({
    super.key, //passes the widget key
    required this.tenantId,
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
  });

  @override
  State<EditUserScreen> createState() => _EditUserScreenState();
}

class _EditUserScreenState extends State<EditUserScreen> {
  //controllers
  late final TextEditingController nameCtrl;
  late final TextEditingController emailCtrl;

  //state variables
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ValueNotifier<bool> _isLoading = ValueNotifier<bool>(false); //store if screen is saving changes
  late final ValueNotifier<String> _selectedRole;

  StreamSubscription<User?>? _authSub;
  bool _handledSignedOut = false;
  bool _existingShopAccessLoaded = false;
  bool _visibleShopIdsFieldExists = false;
  bool _shopIdsInitialised = false;
  Set<String>? _existingVisibleShopIds;
  final Set<String> _selectedShopIds = <String>{};

  //role labels map - connect role values to user-friendly labels
  static const Map<String, String> _roleLabels = {
    "admin": "Admin",
    "manager": "Manager",
    "accountant": "Accountant",
    "storage_manager": "Storage Manager",
    "staff": "Staff",
    "reseller": "Reseller",
  };

  @override
  void initState() {
    super.initState();

    nameCtrl = TextEditingController(text: _capitalizeWords(widget.name)); //rafaella katsiari become Rafaella Katsiari
    emailCtrl = TextEditingController(text: widget.email.trim().toLowerCase()); //convert to lower case

    final incomingRole = widget.role.trim().toLowerCase();
    _selectedRole = ValueNotifier<String>(
      _roleLabels.containsKey(incomingRole) ? incomingRole : "staff", //prevent invalid roles
    );

    _listenToAuthChanges();
    unawaited(_loadExistingShopAccess());
  }

  void _listenToAuthChanges() {
    _authSub = _auth.authStateChanges().listen((user) {
      if (!mounted || _handledSignedOut) return;

      if (user == null) {
        _handledSignedOut = true;
        _unfocusSafely();
        _popIfPossible();
      }
    });
  }

  void _unfocusSafely() {
    FocusManager.instance.primaryFocus?.unfocus(); //?. -> only calls unfocus() if there is actually a focused widget
  } //avoid focus related widget errors

  bool _canUseContext() => mounted && !_handledSignedOut;

  void _popIfPossible<T extends Object?>([T? result]) {
    if (!mounted) return;

    final navigator = Navigator.maybeOf(context); //maybeOf return null instead of throwing
    if (navigator != null && navigator.canPop()) {
      navigator.pop(result);
    }
  }

  Future<void> _safePop<T extends Object?>([T? result]) async {
    if (!_canUseContext()) return;
    _unfocusSafely();
    await Future<void>.delayed(Duration.zero);
    if (!_canUseContext()) return; //stop if content is unsafe
    _popIfPossible(result);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _isLoading.dispose();
    _selectedRole.dispose();
    nameCtrl.dispose();
    emailCtrl.dispose();
    super.dispose();
  }

  //capitalise word helper
  String _capitalizeWords(String text) {
    final cleaned = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.isEmpty) return cleaned;

    return cleaned
        .split(' ') //split words into list
        .map((word) { //loop each word
      if (word.isEmpty) return word;
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    })
        .join(' '); //join the words together
  }

  //basic email validator
  bool _looksLikeEmail(String s) {
    final x = s.trim();
    return x.contains("@") && x.contains(".") && x.length >= 5; //should include @, ., and must be more than or equal to 5
  }

  //show error toast
  void _showErrorToast(String message) {
    if (!_canUseContext()) return;
    TopToast.error(context, message);
  }

  bool _roleUsesShopPermissions(String value) {
    final cleanRole = value.trim().toLowerCase();
    return cleanRole != "admin" && cleanRole != "storage_manager";
  }



  CollectionReference<Map<String, dynamic>> _shopsRef() {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("shops");
  }

  DocumentReference<Map<String, dynamic>> _tenantUserRef() {
    return FirebaseFirestore.instance
        .collection("tenants")
        .doc(widget.tenantId)
        .collection("users")
        .doc(widget.uid);
  }

  DocumentReference<Map<String, dynamic>> _rootUserRef() {
    return FirebaseFirestore.instance.collection("users").doc(widget.uid);
  }

  Set<String>? _parseVisibleShopIds(Map<String, dynamic> data) {
    if (!data.containsKey("visibleShopIds")) return null;
    final raw = data["visibleShopIds"];
    if (raw == null) return <String>{};
    if (raw is Iterable) {
      return raw
          .map((e) => e.toString().trim())
          .where((id) => id.isNotEmpty)
          .toSet();
    }
    return <String>{};
  }

  Future<void> _loadExistingShopAccess() async {
    Set<String>? visibleIds;
    bool fieldExists = false;

    final refs = <DocumentReference<Map<String, dynamic>>>[
      _tenantUserRef(),
      _rootUserRef(),
    ];

    for (final ref in refs) {
      try {
        final snap = await ref.get(const GetOptions(source: Source.cache));
        final data = snap.data();
        if (snap.exists && data != null && data.containsKey("visibleShopIds")) {
          visibleIds = _parseVisibleShopIds(data);
          fieldExists = true;
          break;
        }
      } catch (_) {}
    }

    if (!fieldExists) {
      for (final ref in refs) {
        try {
          final snap = await ref.get();
          final data = snap.data();
          if (snap.exists && data != null && data.containsKey("visibleShopIds")) {
            visibleIds = _parseVisibleShopIds(data);
            fieldExists = true;
            break;
          }
        } catch (_) {}
      }
    }

    if (!mounted || _handledSignedOut) return;
    setState(() {
      _existingVisibleShopIds = visibleIds;
      _visibleShopIdsFieldExists = fieldExists;
      _existingShopAccessLoaded = true;
    });
  }

  Future<void> _saveVisibleShopIdsForUser() async {
    final ids = _selectedShopIds.toList()..sort();
    final batch = FirebaseFirestore.instance.batch();
    final data = <String, dynamic>{
      "visibleShopIds": ids,
      "shopAccessUpdatedAt": FieldValue.serverTimestamp(),
    };

    batch.set(_tenantUserRef(), data, SetOptions(merge: true));
    batch.set(_rootUserRef(), data, SetOptions(merge: true));
    await batch.commit();
  }

  Widget _buildShopAccessSelector(bool isLoading) {
    if (!_existingShopAccessLoaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _shopsRef().orderBy("createdAt", descending: false).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Text("Could not load shops.");
        }

        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final shops = snapshot.data!.docs;
        final allShopIds = shops.map((d) => d.id).toSet();

        if (!_shopIdsInitialised) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _shopIdsInitialised) return;
            setState(() {
              _selectedShopIds
                ..clear()
                ..addAll(_visibleShopIdsFieldExists
                    ? (_existingVisibleShopIds ?? <String>{}).where(allShopIds.contains)
                    : allShopIds);
              _shopIdsInitialised = true;
            });
          });
        }

        if (shops.isEmpty) {
          return const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              "No shops have been created yet. This user will not be able to create shop orders until shops are added.",
              style: TextStyle(color: Colors.black54),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    "Shop permissions",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.black87,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: const Color(0xff0B1E40),
                  ),
                  onPressed: isLoading
                      ? null
                      : () {
                    setState(() {
                      _selectedShopIds
                        ..clear()
                        ..addAll(allShopIds);
                      _shopIdsInitialised = true;
                    });
                  },
                  child: const Text("All"),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: const Color(0xff0B1E40),
                  ),
                  onPressed: isLoading
                      ? null
                      : () {
                    setState(() {
                      _selectedShopIds.clear();
                      _shopIdsInitialised = true;
                    });
                  },
                  child: const Text("None"),
                ),
              ],
            ),
            Text(
              _selectedShopIds.isEmpty
                  ? "No shops selected. This user cannot create orders."
                  : "Selected ${_selectedShopIds.length} of ${shops.length} shops.",
              style: TextStyle(
                color: _selectedShopIds.isEmpty
                    ? Colors.red.shade700
                    : Colors.black54,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            ...shops.map((shop) {
              final data = shop.data();
              final name = (data["name"] ?? "Untitled").toString();
              final selected = _selectedShopIds.contains(shop.id);

              return CheckboxListTile(
                value: selected,
                enabled: !isLoading,
                dense: true,
                contentPadding: EdgeInsets.zero,
                visualDensity: const VisualDensity(horizontal: -4, vertical: -3),
                title: Text(name),
                secondary: const Icon(Icons.store_outlined),
                controlAffinity: ListTileControlAffinity.trailing,
                onChanged: isLoading
                    ? null
                    : (value) {
                  setState(() {
                    _shopIdsInitialised = true;
                    if (value == true) {
                      _selectedShopIds.add(shop.id);
                    } else {
                      _selectedShopIds.remove(shop.id);
                    }
                  });
                },
              );
            }),
          ],
        );
      },
    );
  }

  //firebase function errors
  void _handleFunctionsError(FirebaseFunctionsException e) {
    final code = e.code.toLowerCase();
    final msg = (e.message ?? "").toLowerCase();

    //server unavailable
    if (code == "unavailable") {
      _showErrorToast(
        "The server is not reachable right now. Check your internet and try again.",
      );
      return;
    }

    //email already in use
    if (code == "already-exists" ||
        code == "email-already-in-use" ||
        code == "auth/email-already-in-use" ||
        msg.contains("already in use") ||
        msg.contains("email already") ||
        (msg.contains("email") && msg.contains("already"))) {
      _showErrorToast(
        "This email is already used by another account. Please use a different email.",
      );
      return;
    }

    //invalid argument
    if (code == "invalid-argument") {
      _showErrorToast("Invalid data. Please check the fields and try again.");
      return;
    }

    //permission denied
    if (code == "permission-denied") {
      _showErrorToast("You don’t have permission to edit users.");
      return;
    }

    //unauthorised
    if (code == "unauthenticated") {
      _showErrorToast("You must be logged in.");
      return;
    }

    //user not found
    if (code == "not-found") {
      _showErrorToast("User not found.");
      return;
    }

    //failed precondition
    if (code == "failed-precondition") {
      _showErrorToast(e.message ?? "This user cannot be updated right now.");
      return;
    }

    //fallback error
    _showErrorToast(e.message ?? "Failed to update user (${e.code}).");
  }

  Future<void> saveChanges() async {
    if (_isLoading.value) return; //prevent duplicate submissions

    final currentUser = _auth.currentUser;

    if (currentUser == null) {
      _showErrorToast("You must be logged in.");
      return;
    }

    final name = _capitalizeWords(nameCtrl.text);
    final email = emailCtrl.text.trim().toLowerCase();
    final selectedRole = _selectedRole.value;

    //validate fields
    if (name.isEmpty || email.isEmpty) {
      _showErrorToast("Please fill in all fields.");
      return;
    }

    if (!_looksLikeEmail(email)) {
      _showErrorToast("Please enter a valid email address.");
      return;
    }

    _unfocusSafely();
    _isLoading.value = true;

    //call cloud function
    try {
      final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
      final callable = functions.httpsCallable('updateAuthUser');

      await callable.call({
        //sends the updated user data
        "tenantId": widget.tenantId,
        "uid": widget.uid,
        "name": name,
        "email": email,
        "role": selectedRole,
      });

      if (_roleUsesShopPermissions(selectedRole)) {
        await _saveVisibleShopIdsForUser();
      }

      if (!_canUseContext()) return;

      await Future<void>.delayed(const Duration(milliseconds: 180));

      if (!_canUseContext()) return;
      await _safePop(true);
      //firebase function error handling
    } on FirebaseFunctionsException catch (e) {
      if (!_canUseContext()) return;
      _handleFunctionsError(e);
      //generic error handling
    } catch (_) {
      if (!_canUseContext()) return;
      _showErrorToast("Something went wrong. Please try again.");
    } finally {
      if (mounted && !_handledSignedOut) {
        _isLoading.value = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

    return ValueListenableBuilder<bool>(
      valueListenable: _isLoading,
      builder: (context, isLoading, _) {
        return Scaffold(
          resizeToAvoidBottomInset: true,
          appBar: AppBar(
            backgroundColor: const Color(0xff0B1E40),
            title: const Text(
              "Edit User",
              style: TextStyle(color: Colors.white),
            ),
            iconTheme: const IconThemeData(color: Colors.white),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: isLoading ? null : _safePop,
            ),
          ),
          body: SafeArea(
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                keyboardOpen ? 24 : 20,
              ),
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: "Name"),
                  textInputAction: TextInputAction.next,
                  enabled: !isLoading,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: emailCtrl,
                  decoration: const InputDecoration(labelText: "Email"),
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  enabled: !isLoading,
                  onSubmitted: (_) {
                    if (!isLoading) {
                      saveChanges();
                    }
                  },
                ),
                const SizedBox(height: 20),
                ValueListenableBuilder<String>(
                  valueListenable: _selectedRole,
                  builder: (context, selectedRole, _) {
                    return DropdownButtonFormField<String>(
                      value: selectedRole,
                      decoration: const InputDecoration(
                        labelText: "Role",
                        border: OutlineInputBorder(),
                      ),
                      items: _roleLabels.entries
                          .map( //create dropdown
                            (e) => DropdownMenuItem<String>(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      )
                          .toList(),
                      onChanged: isLoading
                          ? null
                          : (value) {
                        _selectedRole.value = value ?? "staff";
                      },
                    );
                  },
                ),
                ValueListenableBuilder<String>(
                  valueListenable: _selectedRole,
                  builder: (context, selectedRole, _) {
                    if (!_roleUsesShopPermissions(selectedRole)) {
                      return const SizedBox.shrink();
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 20),
                        _buildShopAccessSelector(isLoading),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 50,
                  child: ElevatedButton(
                    onPressed: isLoading ? null : saveChanges,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xff0B1E40),
                      foregroundColor: Colors.white,
                    ),
                    child: isLoading
                        ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                      ),
                    )
                        : const Text("Save Changes"),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}