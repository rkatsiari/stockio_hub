import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'models/app_user.dart';
import 'screens/auth_choice_screen.dart';
import 'screens/files_screen.dart';
import 'services/current_user_service.dart';
import 'services/reconnect_sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
  );

  ReconnectSyncService.instance.start();

  runApp(const MyApp());
}

enum AppStartDestination {
  loading,
  authChoice,
  files,
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  Future<AppUser?> _loadValidAppUser(String uid) async {
    final userService = CurrentUserService();
    final appUser = await userService.load();

    if (appUser == null) return null;
    if (appUser.uid != uid) return null;
    if (!appUser.hasValidTenantId) return null;

    final tenantOk = await userService.hasValidTenantAndMembership(appUser);
    if (!tenantOk) return null;

    return appUser;
  }

  Future<AppStartDestination> _resolveStartScreen(User? user) async {
    if (user == null) {
      return AppStartDestination.authChoice;
    }

    final appUser = await _loadValidAppUser(user.uid);

    if (appUser != null) {
      return AppStartDestination.files;
    }

    await FirebaseAuth.instance.signOut();
    return AppStartDestination.authChoice;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Inventory Management',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff0B1E40),
        ),
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xff0B1E40),
          iconTheme: IconThemeData(color: Colors.white),
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        useMaterial3: true,
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, authSnapshot) {
          if (authSnapshot.connectionState == ConnectionState.waiting) {
            return const LoadingScreen();
          }

          return FutureBuilder<AppStartDestination>(
            future: _resolveStartScreen(authSnapshot.data),
            builder: (context, startSnapshot) {
              if (startSnapshot.connectionState == ConnectionState.waiting) {
                return const LoadingScreen();
              }

              if (startSnapshot.hasError) {
                return const ErrorScreen(
                  message: "Something went wrong while starting the app.",
                );
              }

              final destination =
                  startSnapshot.data ?? AppStartDestination.loading;

              switch (destination) {
                case AppStartDestination.authChoice:
                  return const AuthChoiceScreen();

                case AppStartDestination.files:
                  return const FilesScreen();

                case AppStartDestination.loading:
                  return const LoadingScreen();
              }
            },
          );
        },
      ),
    );
  }
}

class LoadingScreen extends StatelessWidget {
  const LoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}

class ErrorScreen extends StatelessWidget {
  final String message;

  const ErrorScreen({
    super.key,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}