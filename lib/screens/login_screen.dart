//login screen
import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../widgets/top_toast.dart';
import 'files_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  bool isLoading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> _showPopup(String title, String message) async {
    if (!mounted) return; //prevents crash if widget is already disposed

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  //simple email validation
  bool _looksLikeEmail(String value) {
    final v = value.trim();
    return v.contains("@") && v.contains(".") && v.length >= 5;
  }

  void _showErrorToast(String message) {
    if (!mounted) return;
    TopToast.error(context, message);
  }

  void _showSuccessToast(String message) {
    if (!mounted) return;
    TopToast.success(context, message);
  }

  //internet check
  Future<bool> _hasInternetConnection() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();

      final hasNetworkInterface = connectivityResult.any(
            (result) => result != ConnectivityResult.none,
      );

      if (!hasNetworkInterface) return false;

      //web fallback
      if (kIsWeb) {
        return true;
      }

      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 4));

      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

  //network error
  bool _isNetworkError(Object error) {
    final msg = error.toString().toLowerCase();

    return msg.contains('network-request-failed') ||
        msg.contains('network request failed') ||
        msg.contains('socketexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('dns') ||
        msg.contains('timeout') ||
        msg.contains('timed out') ||
        msg.contains('unreachable') ||
        msg.contains('connection error') ||
        msg.contains('unable to resolve host') ||
        msg.contains('internet');
  }

  //log in function
  Future<void> _login() async {
    if (isLoading) return; //prevent double clicks

    final email = emailController.text.trim();
    final password = passwordController.text;

    //validate input
    if (email.isEmpty || password.isEmpty) {
      _showErrorToast("Please enter email and password.");
      return;
    }

    if (!_looksLikeEmail(email)) {
      _showErrorToast("Please enter a valid email address.");
      return;
    }

    //close keyboard - prevent UI glitches
    FocusScope.of(context).unfocus();

    //show loading
    if (mounted) {
      setState(() => isLoading = true);
    }

    //check internet
    try {
      final hasInternet = await _hasInternetConnection();

      if (!mounted) return;

      if (!hasInternet) {
        setState(() => isLoading = false);
        _showErrorToast("No internet connection. Please try again.");
        return;
      }

      //firebase login
      final ok = await AuthService().signIn(email, password);

      if (!mounted) return;

      if (!ok) {
        setState(() => isLoading = false);
        _showErrorToast("Invalid email or password.");
        return;
      }

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const FilesScreen()),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() => isLoading = false);

      if (_isNetworkError(e)) {
        _showErrorToast("No internet connection. Please try again.");
        return;
      }

      _showErrorToast("Login failed. Please try again.");
    }
  }

  Future<void> _forgotPassword() async {
    if (isLoading) return;

    final email = emailController.text.trim();

    if (email.isEmpty) {
      await _showPopup(
        "Missing Email",
        "Please enter your account email first.",
      );
      return;
    }

    if (!_looksLikeEmail(email)) {
      await _showPopup(
        "Invalid Email",
        "Please enter a valid email address.",
      );
      return;
    }

    FocusScope.of(context).unfocus();

    if (mounted) {
      setState(() => isLoading = true);
    }

    try {
      final hasInternet = await _hasInternetConnection();

      if (!mounted) return;

      if (!hasInternet) {
        setState(() => isLoading = false);
        _showErrorToast("No internet connection. Please try again.");
        return;
      }

      await AuthService().sendPasswordResetSecure(email);

      if (!mounted) return;

      setState(() => isLoading = false);
      _showSuccessToast("Reset email sent. Check spam.");
    } catch (e) {
      if (!mounted) return;

      setState(() => isLoading = false);

      if (_isNetworkError(e)) {
        _showErrorToast("No internet connection. Please try again.");
        return;
      }

      _showErrorToast("Could not process password reset right now.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: const Color(0xff0B1E40),
        foregroundColor: Colors.white,
        title: const Text("Login"),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              32,
              24,
              32,
              keyboardOpen ? 24 : 32,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    "STOCKIO HUB",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 30),
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: "EMAIL"),
                    enabled: !isLoading,
                    autofillHints: const [AutofillHints.username],
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: passwordController,
                    decoration: InputDecoration(
                      labelText: "PASSWORD",
                      suffixIcon: IconButton(
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
                    obscureText: _obscurePassword,
                    textInputAction: TextInputAction.done,
                    enabled: !isLoading,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) {
                      if (!isLoading) _login();
                    },
                  ),
                  const SizedBox(height: 30),
                  SizedBox(
                    height: 50,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xff0B1E40),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: isLoading ? null : _login,
                      child: isLoading
                          ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2.5,
                        ),
                      )
                          : const Text("LOG IN"),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: isLoading ? null : _forgotPassword,
                    child: const Text("Forgot password?"),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}