// create a user through cloud function
import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../widgets/bottom_nav.dart';
import '../widgets/top_toast.dart';

class AddUserScreen extends StatefulWidget {
  final String tenantId;

  const AddUserScreen({
    super.key,
    required this.tenantId,
  });

  @override
  State<AddUserScreen> createState() => _AddUserScreenState();
}

class _AddUserScreenState extends State<AddUserScreen> {
  //text controllers
  final TextEditingController nameCtrl = TextEditingController();
  final TextEditingController emailCtrl = TextEditingController();
  final TextEditingController passCtrl = TextEditingController();
  final TextEditingController confirmPassCtrl = TextEditingController();

  final FirebaseAuth _auth = FirebaseAuth.instance;

  StreamSubscription<User?>? _authSub;

  //role map
  static const Map<String, String> _roleLabels = {
    "admin": "Admin",
    "manager": "Manager",
    "accountant": "Accountant",
    "storage_manager": "Storage Manager",
    "staff": "Staff",
    "reseller": "Reseller",
  };

  // control the UI
  String role = "staff";
  bool isLoading = false;
  bool _obscurePassword = true; //show password
  bool _obscureConfirmPassword = true; //show password
  bool _handledSignedOut = false; // to avoid lifecycle errors

  //listen in case user logout
  @override
  void initState() {
    super.initState();
    _listenToAuthChanges();
  }

  //protect screen to avoid red screens appear
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

  //close keyboard and remove focus
  void _unfocusSafely() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  //check if widget is alive
  bool _canUseContext() => mounted && !_handledSignedOut;

  //close page
  void _popIfPossible<T extends Object?>([T? result]) {
    if (!mounted) return;

    final navigator = Navigator.maybeOf(context);
    if (navigator != null && navigator.canPop()) {
      navigator.pop(result);
    }
  }

  Future<void> _safePop<T extends Object?>([T? result]) async {
    if (!_canUseContext()) return;
    _unfocusSafely();
    await Future<void>.delayed(Duration.zero); //prevent navigation timing problem
    if (!_canUseContext()) return;
    _popIfPossible(result);
  }

  //format the name to keep data in database consistent
  String _capitalizeWords(String text) {
    final cleaned = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.isEmpty) return cleaned;

    return cleaned
        .split(' ')
        .map((word) {
      if (word.isEmpty) return word;
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    })
        .join(' ');
  }

  //password validation
  String? _validatePassword(String password) {
    if (password.length < 8) {
      return "Password must be at least 8 characters.";
    }
    if (!RegExp(r'[A-Z]').hasMatch(password)) {
      return "Password must include at least 1 uppercase letter.";
    }
    if (!RegExp(r'[a-z]').hasMatch(password)) {
      return "Password must include at least 1 lowercase letter.";
    }
    if (!RegExp(r'[0-9]').hasMatch(password)) {
      return "Password must include at least 1 number.";
    }
    return null;
  }

  //validate email
  bool _looksLikeEmail(String s) {
    final x = s.trim();
    return x.contains("@") && x.contains(".") && x.length >= 5;
  }

  //toast helpers
  void _showErrorToast(String message) {
    if (!_canUseContext()) return;
    TopToast.error(context, message);
  }

  void _showSuccessToast(String message) {
    if (!_canUseContext()) return;
    TopToast.success(context, message);
  }

  //error handling for cloud function
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
    //email already exist
    if (code == "already-exists" ||
        code == "email-already-in-use" ||
        code == "auth/email-already-in-use" ||
        msg.contains("already in use") ||
        msg.contains("email-already-in-use") ||
        (msg.contains("email") && msg.contains("already"))) {
      _showErrorToast(
        "This email is already used by another account. Please use a different email.",
      );
      return;
    }
    //invalid email
    if (code == "invalid-argument" || msg.contains("invalid email")) {
      _showErrorToast("Please enter a valid email address.");
      return;
    }
    //no permission
    if (code == "permission-denied") {
      _showErrorToast("You don’t have permission to create users.");
      return;
    }
    //unauthenticated
    if (code == "unauthenticated") {
      _showErrorToast("You must be logged in.");
      return;
    }
    //default
    _showErrorToast(e.message ?? "Failed to create user (${e.code}).");
  }

  Future<void> createUser() async {
    if (isLoading) return; //prevent duplicate taps

    //make sure user is logged in
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      _showErrorToast("You must be logged in.");
      return;
    }

    //read user input
    final name = _capitalizeWords(nameCtrl.text);
    final email = emailCtrl.text.trim().toLowerCase(); //convert to lowercase
    final password = passCtrl.text.trim(); //no spaces
    final confirmPassword = confirmPassCtrl.text.trim();

    //check required fields
    if (name.isEmpty ||
        email.isEmpty ||
        password.isEmpty ||
        confirmPassword.isEmpty) {
      _showErrorToast("Please fill in all fields.");
      return;
    }

    //email format validation
    if (!_looksLikeEmail(email)) {
      _showErrorToast("Please enter a valid email address.");
      return;
    }

    //password rule validation
    final passwordError = _validatePassword(password);
    if (passwordError != null) {
      _showErrorToast(passwordError);
      return;
    }

    //confirm password check
    if (password != confirmPassword) {
      _showErrorToast(
        "Passwords do not match. Please make sure both password fields are the same.",
      );
      return;
    }

    //close keyboard
    _unfocusSafely();

    //loading state
    if (mounted) {
      setState(() => isLoading = true);
    }

    //cloud function is called
    try {
      final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
      final callable = functions.httpsCallable('createAuthUser');

      await callable.call({
        "tenantId": widget.tenantId,
        "name": name,
        "email": email,
        "password": password,
        "role": role,
      });

      if (!_canUseContext()) return;

      _showSuccessToast("User created successfully");

      await Future<void>.delayed(const Duration(milliseconds: 180));

      if (!_canUseContext()) return;
      await _safePop(true);
    } on FirebaseFunctionsException catch (e) {
      if (!_canUseContext()) return; //handle firebase functions errors
      _handleFunctionsError(e);
    } catch (_) {
      if (!_canUseContext()) return; //handle unknown errors
      _showErrorToast("Something went wrong. Please try again.");
    } finally { //reset loading always
      if (mounted && !_handledSignedOut) { //prevent setState problems
        setState(() => isLoading = false);
      }
    }
  }

  //clean up resources when screen is closed
  @override
  void dispose() {
    _authSub?.cancel(); //stop listening to auth changes
    nameCtrl.dispose();
    emailCtrl.dispose();
    passCtrl.dispose();
    confirmPassCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0; //used so bottom nav can hide

    return Scaffold(
      resizeToAvoidBottomInset: true,
      //show top bar
      appBar: AppBar(
        backgroundColor: const Color(0xff0B1E40),
        title: const Text(
          "Add User",
          style: TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: isLoading ? null : _safePop, //back button disabled
        ),
      ),
      body: SafeArea( //avoid system UI overlap
        child: ListView( //make it scrollable
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            keyboardOpen ? 24 : 20, //bottom padding increases with keyboard
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
              textInputAction: TextInputAction.next,
              enabled: !isLoading,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passCtrl,
              obscureText: _obscurePassword, //hide password
              decoration: InputDecoration(
                labelText: "Password",
                helperText: "Min 8 chars, 1 uppercase, 1 lowercase, 1 number",
                suffixIcon: IconButton( //visible password
                  onPressed: isLoading
                      ? null
                      : () {
                    setState(() {
                      _obscurePassword = !_obscurePassword;
                    });
                  },
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off
                        : Icons.visibility,
                  ),
                ),
              ),
              textInputAction: TextInputAction.next,
              enabled: !isLoading,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirmPassCtrl,
              obscureText: _obscureConfirmPassword,
              decoration: InputDecoration(
                labelText: "Confirm Password",
                suffixIcon: IconButton(
                  onPressed: isLoading
                      ? null
                      : () {
                    setState(() {
                      _obscureConfirmPassword =
                      !_obscureConfirmPassword;
                    });
                  },
                  icon: Icon(
                    _obscureConfirmPassword
                        ? Icons.visibility_off
                        : Icons.visibility,
                  ),
                ),
              ),
              textInputAction: TextInputAction.done, //last field for keyboard
              enabled: !isLoading,
              onSubmitted: (_) { //submit form with the press of button
                if (!isLoading) {
                  createUser();
                }
              },
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              value: role, //default value
              decoration: const InputDecoration(
                labelText: "Role",
                border: OutlineInputBorder(),
              ),
              items: _roleLabels.entries //convert to drop down items
                  .map(
                    (e) => DropdownMenuItem<String>(
                  value: e.key,
                  child: Text(e.value),
                ),
              )
                  .toList(),
              onChanged: isLoading
                  ? null
                  : (value) {
                if (value != null) {
                  setState(() => role = value);
                }
              },
            ),
            //create button
            const SizedBox(height: 20),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: isLoading ? null : createUser, //disable during loading
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xff0B1E40),
                  foregroundColor: Colors.white,
                ),
                child: isLoading
                    ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                    : const Text("Create User"),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: keyboardOpen
          ? null
          : const BottomNav(
        currentIndex: 3,
        hasFab: false,
      ),
    );
  }
}