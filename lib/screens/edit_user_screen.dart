//edit details of an existing user
import 'dart:async';

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