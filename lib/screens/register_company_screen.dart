//register a company and create an admin user
import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../widgets/top_toast.dart';

class RegisterCompanyScreen extends StatefulWidget {
  const RegisterCompanyScreen({super.key});

  @override
  State<RegisterCompanyScreen> createState() => _RegisterCompanyScreenState();
}

class _RegisterCompanyScreenState extends State<RegisterCompanyScreen> {
  final companyController = TextEditingController();
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();

  bool isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  @override
  void dispose() {
    companyController.dispose();
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  //convert company name into firestore safe tenant ID
  String _slugifyTenantId(String input) {
    var value = input.trim().toLowerCase();

    value = value.replaceAll("&", "and");
    value = value.replaceAll(RegExp(r"[^\w\s-]"), "");
    value = value.replaceAll(RegExp(r"\s+"), "_");
    value = value.replaceAll(RegExp(r"_+"), "_");
    value = value.replaceAll(RegExp(r"^_+|_+$"), "");

    return value;
  }

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

  Future<bool> _hasInternetConnection() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();

      final hasNetworkInterface = connectivityResult.any(
            (result) => result != ConnectivityResult.none,
      );

      if (!hasNetworkInterface) return false;

      if (kIsWeb) {
        return true;
      }

      final result = await InternetAddress.lookup('google.com').timeout(
        const Duration(seconds: 4),
      );

      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

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

  Future<void> registerCompany() async {
    if (isLoading) return;

    FocusScope.of(context).unfocus();

    final companyName = companyController.text.trim();
    final name = _capitalizeWords(nameController.text);
    final email = emailController.text.trim().toLowerCase();
    final password = passwordController.text;
    final confirmPassword = confirmPasswordController.text;

    if (companyName.isEmpty ||
        name.isEmpty ||
        email.isEmpty ||
        password.isEmpty ||
        confirmPassword.isEmpty) {
      _toast("Please fill all fields", true);
      return;
    }

    final passwordError = _validatePassword(password);
    if (passwordError != null) {
      _toast(passwordError, true);
      return;
    }

    if (password != confirmPassword) {
      _toast("Passwords do not match", true);
      return;
    }

    setState(() => isLoading = true);

    UserCredential? cred;

    try {
      final hasInternet = await _hasInternetConnection();

      if (!mounted) return;

      if (!hasInternet) {
        setState(() => isLoading = false);
        _toast("No internet connection. Please try again.", true);
        return;
      }

      final fs = FirebaseFirestore.instance;
      final auth = FirebaseAuth.instance;

      //generate tenantId
      final tenantId = _slugifyTenantId(companyName);

      if (tenantId.isEmpty) {
        throw Exception("Please enter a valid company name.");
      }

      //check if comany name already exist
      final tenantRef = fs.collection("tenants").doc(tenantId);
      final tenantSnap = await tenantRef.get();

      if (tenantSnap.exists) {
        throw Exception(
          "A company with this name already exists. Please use a different company name.",
        );
      }

      //create firebase auth account
      cred = await auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      //confirm user exist
      final user = cred.user;
      if (user == null) {
        throw Exception("Failed to create account.");
      }

      final uid = user.uid;

      final globalUserRef = fs.collection("users").doc(uid);
      final tenantUserRef = tenantRef.collection("users").doc(uid);

      final batch = fs.batch();

      batch.set(
        tenantRef,
        {
          "name": companyName,
          "ownerUid": uid,
          "isActive": true,
          "created_at": FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      batch.set(globalUserRef, {
        "name": name,
        "email": email,
        "role": "admin",
        "tenantId": tenantId,
        "isActive": true,
        "created_at": FieldValue.serverTimestamp(),
      });

      batch.set(tenantUserRef, {
        "uid": uid,
        "name": name,
        "email": email,
        "role": "admin",
        "tenantId": tenantId,
        "isActive": true,
        "created_at": FieldValue.serverTimestamp(),
      });

      await batch.commit();

      _toast("Company registered successfully", false);

      if (mounted) {
        Navigator.of(context).pop();
      }
    } on FirebaseAuthException catch (e) {
      if (_isNetworkError(e)) {
        _toast("No internet connection. Please try again.", true);
        return;
      }

      _toast(e.message ?? "Authentication error", true);
    } on FirebaseException catch (e) {
      try {
        await cred?.user?.delete();
      } catch (_) {
        try {
          await FirebaseAuth.instance.signOut();
        } catch (_) {}
      }

      if (_isNetworkError(e)) {
        _toast("No internet connection. Please try again.", true);
        return;
      }

      String message = "Database error";
      if (e.code == "permission-denied") {
        message = "You do not have permission to register this company.";
      } else if ((e.message ?? "").trim().isNotEmpty) {
        message = e.message!.trim();
      }

      _toast(message, true);
    } catch (e) {
      try {
        await cred?.user?.delete();
      } catch (_) {
        try {
          await FirebaseAuth.instance.signOut();
        } catch (_) {}
      }

      if (_isNetworkError(e)) {
        _toast("No internet connection. Please try again.", true);
        return;
      }

      final cleaned = e.toString().replaceFirst("Exception: ", "").trim();
      _toast(cleaned.isEmpty ? "Unexpected error occurred" : cleaned, true);
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  void _toast(String msg, bool isError) {
    if (!mounted) return;

    if (isError) {
      TopToast.error(context, msg);
    } else {
      TopToast.success(context, msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text("Register Company"),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  "Create Your Company Account",
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                const Text(
                  "Register your company and create the first admin account.",
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 30),
                TextField(
                  controller: companyController,
                  enabled: !isLoading,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: "Company Name",
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameController,
                  enabled: !isLoading,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: "Full Name",
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: emailController,
                  enabled: !isLoading,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: "Email",
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: passwordController,
                  enabled: !isLoading,
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: "Password",
                    helperText:
                    "Min 8 chars, 1 uppercase, 1 lowercase, 1 number",
                    border: const OutlineInputBorder(),
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
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: confirmPasswordController,
                  enabled: !isLoading,
                  obscureText: _obscureConfirmPassword,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (!isLoading) {
                      registerCompany();
                    }
                  },
                  decoration: InputDecoration(
                    labelText: "Confirm Password",
                    border: const OutlineInputBorder(),
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
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: isLoading ? null : registerCompany,
                  child: isLoading
                      ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                      : const Text("Register Company"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}