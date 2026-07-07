import 'package:flutter/material.dart';

/// App-wide navigator key.
///
/// Services that don't own a BuildContext (e.g. ExportService, which can
/// finish its work well after the screen that started it has been
/// navigated away from) use this to grab a valid context and show the
/// user feedback (TopToast, dialogs, etc) no matter what screen is
/// currently on top.
///
/// Wired up once in main.dart via `MaterialApp(navigatorKey: ...)`.
class AppNavigation {
  AppNavigation._();

  static final GlobalKey<NavigatorState> navigatorKey =
  GlobalKey<NavigatorState>();

  static BuildContext? get currentContext => navigatorKey.currentContext;

  /// Lets any screen that mixes in RouteAware find out when it becomes the
  /// visible/topmost route vs. when it gets covered by a pushed route.
  /// HomeScreen uses this so ExportService knows whether it's safe to pop
  /// the native share sheet right now or whether it should wait.
  ///
  /// Wired up once in main.dart via `MaterialApp(navigatorObservers: ...)`.
  static final RouteObserver<PageRoute> routeObserver =
  RouteObserver<PageRoute>();
}