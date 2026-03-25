import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../screens/files_screen.dart';
import '../screens/home_screen.dart';
import '../screens/order_details_screen.dart';
import '../screens/orders_screen.dart';
import '../screens/profile_screen.dart';
import '../services/tenant_context_service.dart';

class BottomNav extends StatelessWidget {
  final int currentIndex;
  final bool hasFab;

  final bool isRootScreen;

  const BottomNav({
    super.key,
    required this.currentIndex,
    this.hasFab = true,
    this.isRootScreen = true,
  });

  TenantContextService get _tenantContext => TenantContextService();

  bool _isSignedOut() => FirebaseAuth.instance.currentUser == null;

  bool _isSignedOutError(Object error) {
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
        msg.contains("unknownhostexception");
  }

  Future<bool> _isAdmin() async {
    if (_isSignedOut()) return false;

    try {
      return await _tenantContext.isAdmin();
    } catch (_) {
      return false;
    }
  }

  Route _smoothRoute(Widget page) {
    return PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 240),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );

        final fade = Tween<double>(begin: 0.0, end: 1.0).animate(curved);
        final slide = Tween<Offset>(
          begin: const Offset(0.04, 0.0),
          end: Offset.zero,
        ).animate(curved);

        return FadeTransition(
          opacity: fade,
          child: SlideTransition(position: slide, child: child),
        );
      },
    );
  }

  void _unfocusSafely() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _pushReplacementSmooth(BuildContext context, Widget page) {
    if (!context.mounted) return;
    _unfocusSafely();
    Navigator.of(context).pushReplacement(_smoothRoute(page));
  }

  Future<QuerySnapshot<Map<String, dynamic>>?> _tryGetQueryQuickly(
      Query<Map<String, dynamic>> query,
      ) async {
    try {
      return await query.get(const GetOptions(source: Source.cache));
    } catch (_) {}

    try {
      return await query.get();
    } catch (_) {}

    return null;
  }

  Future<Widget> _resolveOrdersTarget() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) {
      return const OrdersScreen();
    }

    try {
      final tenantId = await _tenantContext.getTenantIdOrThrow();

      if (_isSignedOut()) {
        return const OrdersScreen();
      }

      final ordersRef = FirebaseFirestore.instance
          .collection("tenants")
          .doc(tenantId)
          .collection("orders");

      final query = ordersRef
          .where("userId", isEqualTo: uid)
          .where("isActive", isEqualTo: true)
          .limit(1);

      final activeSnap = await _tryGetQueryQuickly(query);

      if (activeSnap != null && activeSnap.docs.isNotEmpty) {
        final activeOrderId = activeSnap.docs.first.id;
        return OrderDetailsScreen(orderId: activeOrderId);
      }

      return const OrdersScreen();
    } catch (e) {
      if (_isSignedOutError(e) ||
          _isUnavailableError(e) ||
          e is TimeoutException) {
        return const OrdersScreen();
      }

      return const OrdersScreen();
    }
  }

  Future<void> _navigate(BuildContext context, int index) async {
    if (!context.mounted) return;

    if (index == currentIndex && isRootScreen) return;

    _unfocusSafely();
    await Future<void>.delayed(Duration.zero);

    if (!context.mounted) return;

    if (_isSignedOut()) {
      switch (index) {
        case 1:
          _pushReplacementSmooth(context, const FilesScreen());
          return;
        case 2:
          _pushReplacementSmooth(context, const OrdersScreen());
          return;
        case 3:
          _pushReplacementSmooth(context, const ProfileScreen());
          return;
        case 0:
          return;
      }
    }

    if (index == 0) {
      final ok = await _isAdmin();
      if (!context.mounted) return;
      if (!ok) return;
    }

    switch (index) {
      case 0:
        _pushReplacementSmooth(context, const HomeScreen());
        break;
      case 1:
        _pushReplacementSmooth(context, const FilesScreen());
        break;
      case 2:
        final target = await _resolveOrdersTarget();
        if (!context.mounted) return;
        _pushReplacementSmooth(context, target);
        break;
      case 3:
        _pushReplacementSmooth(context, const ProfileScreen());
        break;
    }
  }

  Color _iconColor(int index) {
    return currentIndex == index ? const Color(0xff0B1E40) : Colors.grey;
  }

  Widget _navButton(BuildContext context, IconData icon, int index) {
    return Expanded(
      child: IconButton(
        icon: Icon(icon, color: _iconColor(index)),
        onPressed: () => _navigate(context, index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BottomAppBar(
      shape: hasFab ? const CircularNotchedRectangle() : null,
      notchMargin: hasFab ? 8.0 : 0.0,
      child: SizedBox(
        height: 60,
        child: Row(
          children: hasFab
              ? [
            _navButton(context, Icons.home, 0),
            _navButton(context, Icons.folder, 1),
            const SizedBox(width: 40),
            _navButton(context, Icons.receipt_long, 2),
            _navButton(context, Icons.person, 3),
          ]
              : [
            _navButton(context, Icons.home, 0),
            _navButton(context, Icons.folder, 1),
            _navButton(context, Icons.receipt_long, 2),
            _navButton(context, Icons.person, 3),
          ],
        ),
      ),
    );
  }
}