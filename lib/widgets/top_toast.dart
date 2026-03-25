import 'dart:async';

import 'package:flutter/material.dart';

class TopToast {
  TopToast._();

  static OverlayEntry? _entry;
  static Timer? _timer;

  static void _removeCurrent() {
    _timer?.cancel();
    _timer = null;

    try {
      _entry?.remove();
    } catch (_) {}

    _entry = null;
  }

  static void show({
    required BuildContext context,
    required String message,
    required Color background,
    IconData? icon,
    Duration duration = const Duration(seconds: 2),
  }) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    _removeCurrent();

    final entry = OverlayEntry(
      builder: (_) => SafeArea(
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 14, left: 16, right: 16),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 520),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(
                        blurRadius: 16,
                        offset: Offset(0, 8),
                        color: Color(0x33000000),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, color: Colors.white, size: 20),
                        const SizedBox(width: 10),
                      ],
                      Flexible(
                        child: Text(
                          message,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    _entry = entry;
    overlay.insert(entry);

    _timer = Timer(duration, _removeCurrent);
  }

  static void success(
      BuildContext context,
      String message, {
        Duration duration = const Duration(seconds: 2),
      }) {
    show(
      context: context,
      message: message,
      background: const Color(0xFF2E7D32),
      icon: Icons.check_circle_outline,
      duration: duration,
    );
  }

  static void error(
      BuildContext context,
      String message, {
        Duration duration = const Duration(seconds: 2),
      }) {
    show(
      context: context,
      message: message,
      background: const Color(0xFFD32F2F),
      icon: Icons.error_outline,
      duration: duration,
    );
  }

  static void info(
      BuildContext context,
      String message, {
        Duration duration = const Duration(seconds: 2),
      }) {
    show(
      context: context,
      message: message,
      background: const Color(0xFF1565C0),
      icon: Icons.info_outline,
      duration: duration,
    );
  }

  static void hide() {
    _removeCurrent();
  }
}