//entry page
import 'package:flutter/material.dart';

import 'login_screen.dart';
import 'register_company_screen.dart';

class AuthChoiceScreen extends StatefulWidget {
  const AuthChoiceScreen({super.key});

  @override
  State<AuthChoiceScreen> createState() => _AuthChoiceScreenState();
}

class _AuthChoiceScreenState extends State<AuthChoiceScreen> {
  final ValueNotifier<bool> _isNavigating = ValueNotifier<bool>(false); //store whether the user navigated to another screen or not

  //handle navigation
  Future<void> _openScreen(Widget screen) async {
    if (!mounted || _isNavigating.value) return; //safety check

    FocusScope.of(context).unfocus();
    _isNavigating.value = true; //mark as navigating so buttons are disabled

    try {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => screen), //pushes a new screen on top of this one
      );
    } finally { //reset navigation state
      if (mounted) {
        _isNavigating.value = false;
      }
    }
  }

  //avoid memory leaks
  @override
  void dispose() {
    _isNavigating.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Welcome"),
        backgroundColor: const Color(0xff0B1E40),
        foregroundColor: Colors.white,
      ),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView( //makes screen scrollable to avoid overflow
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag, //close keyboard while drugging
            padding: EdgeInsets.fromLTRB(
              24,
              24,
              24,
              keyboardOpen ? 24 : 32, //bottom padding
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420), //prevent ui becoming too wide on web or tablets
              child: ValueListenableBuilder<bool>(
                valueListenable: _isNavigating,
                builder: (context, isNavigating, _) { //only this part rebuild not the whole screen
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(
                        Icons.business,
                        size: 72,
                        color: Color(0xff0B1E40),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        "Inventory Management System",
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "Login to your existing company account or register a new company.",
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 32),
                      SizedBox(
                        height: 50, //login button size
                        child: ElevatedButton(
                          onPressed: isNavigating
                              ? null
                              : () => _openScreen(const LoginScreen()),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xff0B1E40),
                            foregroundColor: Colors.white,
                          ),
                          child: isNavigating
                              ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                              : const Text("Login"),
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 50, //register button size
                        child: OutlinedButton(
                          onPressed: isNavigating
                              ? null
                              : () => _openScreen(
                            const RegisterCompanyScreen(),
                          ),
                          child: const Text("Register Company"),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}