import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_xlsio/xlsio.dart' as xlsio;

import '../utils/price_util.dart';
import '../widgets/top_toast.dart';
import 'app_navigation.dart';

/// Snapshot of what ExportService is currently doing. Any screen can listen
/// to [ExportService.stateNotifier] via a ValueListenableBuilder and see the
/// same live progress, regardless of which screen actually started the
/// export.
class ExportJobState {
  final bool isExporting;
  final bool isProfit;
  final bool isStock;
  final double progress;
  final String progressText;

  const ExportJobState({
    this.isExporting = false,
    this.isProfit = false,
    this.isStock = false,
    this.progress = 0.0,
    this.progressText = "",
  });

  static const ExportJobState idle = ExportJobState();
}

enum ExportResultType { success, info, error }

class ExportResult {
  final ExportResultType type;
  final String message;

  const ExportResult(this.type, this.message);
}

/// A finished export file that's waiting to be handed to the OS share
/// sheet because HomeScreen wasn't the visible screen when it finished.
class PendingShare {
  final String filename;
  final List<int> bytes;
  final String shareText;

  const PendingShare({
    required this.filename,
    required this.bytes,
    required this.shareText,
  });
}

/// Runs the profit/stock Excel exports independently of any screen's widget
/// lifecycle.
///
/// This logic used to live entirely inside _HomeScreenState. Every export
/// checkpoint checked `mounted` and bailed out silently, which meant
/// navigating away from Home mid-export (e.g. tapping a bottom-nav icon)
/// killed the export. Because this is a singleton driven by ValueNotifiers
/// instead of setState, the export keeps running - and keeps reporting
/// progress - no matter what screen the user navigates to, and a second
/// export can't be double-started from another screen while one is already
/// running.
///
/// All Firestore reads, Excel building (syncfusion_flutter_xlsio) and share
/// logic below is transplanted as-is from the old
/// _HomeScreenState._exportProfitXlsx / _exportStockXlsx - only the
/// `mounted`/setState/context plumbing was replaced with ValueNotifiers and
/// a global navigator key (see app_navigation.dart) for toasts.
class ExportService {
  ExportService._();
  static final ExportService instance = ExportService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final ValueNotifier<ExportJobState> stateNotifier =
  ValueNotifier<ExportJobState>(ExportJobState.idle);

  /// Last export outcome, in case a screen wants to react to it directly
  /// instead of (or in addition to) the automatic TopToast below.
  final ValueNotifier<ExportResult?> lastResult =
  ValueNotifier<ExportResult?>(null);

  final Map<String, Uint8List?> _imageCache = {};

  bool get isExporting => stateNotifier.value.isExporting;

  bool _isHomeVisible = false;
  PendingShare? _pendingShare;

  /// HomeScreen calls this (via RouteAware - see home_screen.dart) whenever
  /// it becomes the visible/topmost route or gets covered by a pushed
  /// route. When Home becomes visible and a finished export is waiting,
  /// this immediately opens the share sheet for it.
  void setHomeVisible(bool visible) {
    _isHomeVisible = visible;
    if (visible) {
      _shareIfPending();
    }
  }

  Future<void> _shareIfPending() async {
    final pending = _pendingShare;
    if (pending == null) return;

    _pendingShare = null;
    await _shareFile(
      filename: pending.filename,
      bytes: pending.bytes,
      shareText: pending.shareText,
    );
  }

  /// Opens the share sheet right away if Home is currently visible;
  /// otherwise stashes the file and shares it automatically the next time
  /// Home becomes visible.
  Future<void> _shareNowOrWhenHomeVisible({
    required String filename,
    required List<int> bytes,
    required String shareText,
  }) async {
    if (_isHomeVisible) {
      await _shareFile(filename: filename, bytes: bytes, shareText: shareText);
      return;
    }

    _pendingShare = PendingShare(
      filename: filename,
      bytes: bytes,
      shareText: shareText,
    );
  }

  static const Map<String, String> profitExportTypeLabels = {
    "storage": "Storage",
    "shop": "Shop",
    "total": "Total",
  };

  static const List<String> _adultTshirtSizes = [
    "XXS", "XS", "S", "M",
    "L", "XL", "2XL", "3XL",
  ];

  static const List<String> _kidsTshirtSizes = [
    "1-2", "3-4", "5-6", "7-8", "9-10", "11-12",
  ];

  static const int _picPx = 100;
  static const double _headerRowH = 28;
  static const double _normalRowH = 100;
  static const double _sizedItemRowH = 18;

  static const String _euroFmt = '€#,##0.00';
  static const String _qtyFmt = '0';

  // ---------------------------------------------------------------------
  // Small helpers (moved verbatim from _HomeScreenState)
  // ---------------------------------------------------------------------

  Map<String, dynamic> _asStringDynamicMap(dynamic value) {
    if (value is Map) {
      return value.map(
            (key, val) => MapEntry(key.toString().trim(), val),
      )..removeWhere((key, _) => key.isEmpty);
    }
    return <String, dynamic>{};
  }

  String _normalizeSizeKey(String value) => value.trim().toUpperCase();

  String _productItemType(Map<String, dynamic> data) {
    final raw = (data["itemType"] ?? "").toString().trim().toLowerCase();
    if (raw == "item" || raw == "tshirt" || raw == "shoes") return raw;

    // Backwards compatibility for products created before itemType existed.
    if ((data["isTshirt"] ?? false) == true) return "tshirt";

    final sizeStock = _asStringDynamicMap(data["sizeStock"]);
    if (sizeStock.isNotEmpty) return "shoes";

    return "item";
  }

  bool _isSizedProduct(Map<String, dynamic> data) {
    final type = _productItemType(data);
    return type == "tshirt" || type == "shoes";
  }

  List<String> _sizeLabelsForProduct(
      Map<String, dynamic> data, {
        Iterable<String> extraSizes = const <String>[],
      }) {
    final type = _productItemType(data);
    final labels = <String>[];
    final seen = <String>{};

    void addSize(String value) {
      final clean = value.trim();
      if (clean.isEmpty) return;
      final key = _normalizeSizeKey(clean);
      if (seen.add(key)) labels.add(clean);
    }

    if (type == "tshirt") {
      final sizeGroup =
      (data["sizeGroup"] ?? "adult").toString().trim().toLowerCase();
      final baseSizes =
      sizeGroup == "kids" ? _kidsTshirtSizes : _adultTshirtSizes;
      for (final size in baseSizes) {
        addSize(size);
      }
    } else if (type == "shoes") {
      final sizeStock = _asStringDynamicMap(data["sizeStock"]);
      for (final size in sizeStock.keys) {
        addSize(size);
      }
    }

    // Fallback/repair path: include any saved sizeStock keys and any sizes
    // found in orders or stock movements, so exports do not lose custom
    // shoe sizes.
    final sizeStock = _asStringDynamicMap(data["sizeStock"]);
    for (final size in sizeStock.keys) {
      addSize(size);
    }

    for (final size in extraSizes) {
      addSize(size);
    }

    return labels;
  }

  CollectionReference<Map<String, dynamic>> _productsCol(String tenantId) {
    return _firestore.collection("tenants").doc(tenantId).collection("products");
  }

  CollectionReference<Map<String, dynamic>> _ordersCol(String tenantId) {
    return _firestore.collection("tenants").doc(tenantId).collection("orders");
  }

  Future<bool> _hasInternetConnection() async {
    try {
      final results = await Connectivity().checkConnectivity();
      final hasNetwork =
      results.any((result) => result != ConnectivityResult.none);

      if (!hasNetwork) return false;

      final response = await http
          .get(Uri.parse("https://www.google.com/generate_204"))
          .timeout(const Duration(seconds: 5));

      return response.statusCode == 204 || response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ensureInternetForExport() async {
    final hasInternet = await _hasInternetConnection();

    if (!hasInternet) {
      _announce(
        ExportResultType.error,
        "No internet connection. Please connect to Wi-Fi or mobile data to export.",
      );
    }

    return hasInternet;
  }

  Future<Uint8List?> _downloadImageBytes(String url) async {
    final clean = url.trim();
    if (clean.isEmpty) return null;

    if (_imageCache.containsKey(clean)) return _imageCache[clean];

    final uri = Uri.tryParse(clean);
    if (uri == null) {
      //malformed URL - this will never succeed, so it's safe to remember
      _imageCache[clean] = null;
      return null;
    }

    try {
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        _imageCache[clean] = resp.bodyBytes;
        return resp.bodyBytes;
      }
    } catch (_) {}

    //don't cache a network/timeout failure - it may be transient, and since
    //this cache now lives on the singleton for the whole app session (not
    //just one screen visit), permanently blacklisting an image here would
    //mean it never loads again until the app is restarted
    return null;
  }

  Future<void> _shareFile({
    required String filename,
    required List<int> bytes,
    required String shareText,
  }) async {
    //clean up temp export folders left behind by earlier exports so they
    //don't accumulate in app storage over time
    try {
      final entries = Directory.systemTemp.listSync();
      for (final entity in entries) {
        if (entity is Directory && entity.path.contains("ims_exports_")) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}

    final dir = await Directory.systemTemp.createTemp("ims_exports_");
    final file = File("${dir.path}/$filename");
    await file.writeAsBytes(bytes, flush: true);

    await Share.shareXFiles([XFile(file.path)], text: shareText);
  }

  //normalizes the selected export shop name into a display string and a
  //filesystem-safe filename fragment (shared by both export methods)
  (String, String) _safeShopNameAndFile(String shopName) {
    final safeShop = shopName.trim().isEmpty ? "All" : shopName.trim();
    final safeShopFile = safeShop.replaceAll(RegExp(r'[\\/:*?"<>|]'), "_");
    return (safeShop, safeShopFile);
  }

  void _applyHeaderStyle(
      xlsio.Worksheet sheet,
      int row,
      int colStart,
      int colEnd,
      ) {
    final r = sheet.getRangeByIndex(row, colStart, row, colEnd);
    r.cellStyle.bold = true;
    r.cellStyle.hAlign = xlsio.HAlignType.center;
    r.cellStyle.vAlign = xlsio.VAlignType.center;
  }

  void _applyTableBordersCenter(
      xlsio.Worksheet sheet,
      int row1,
      int col1,
      int row2,
      int col2,
      ) {
    final table = sheet.getRangeByIndex(row1, col1, row2, col2);
    table.cellStyle.hAlign = xlsio.HAlignType.center;
    table.cellStyle.vAlign = xlsio.VAlignType.center;
    table.cellStyle.borders.all.lineStyle = xlsio.LineStyle.thin;
  }

  void _applyLandscape(xlsio.Worksheet sheet) {
    sheet.pageSetup.orientation = xlsio.ExcelPageOrientation.landscape;
    sheet.pageSetup.fitToPagesWide = 1;
    sheet.pageSetup.fitToPagesTall = 0;
  }

  void _applyProductSeparator(
      xlsio.Worksheet sheet,
      int row,
      int colStart,
      int colEnd,
      ) {
    final r = sheet.getRangeByIndex(row, colStart, row, colEnd);
    r.cellStyle.borders.bottom.lineStyle = xlsio.LineStyle.medium;
  }

  String _friendlyExportError(Object e) {
    if (e is FirebaseException) {
      if (e.code == "permission-denied") {
        return "You don't have permission to export this data. Please contact an admin.";
      }
      if (e.code == "unauthenticated") {
        return "You are not logged in. Please sign in again and retry.";
      }
      return "Firebase error: ${e.message ?? e.code}";
    }

    final msg = e.toString();

    if (msg.contains("TimeoutException")) {
      return "The export took too long. Please check your internet connection and try again.";
    }
    if (msg.contains("SocketException") || msg.contains("Failed host lookup")) {
      return "No internet connection. Please connect to Wi-Fi/mobile data and try again.";
    }
    if (msg.toLowerCase().contains("share")) {
      return "Couldn't open the share menu. Please try again.";
    }

    return "Something went wrong while exporting. $msg";
  }

  void _setState(ExportJobState next) {
    stateNotifier.value = next;
  }

  void _updateProgress(double progress, String text) {
    final current = stateNotifier.value;
    stateNotifier.value = ExportJobState(
      isExporting: current.isExporting,
      isProfit: current.isProfit,
      isStock: current.isStock,
      progress: progress.clamp(0.0, 1.0),
      progressText: text,
    );
  }

  /// Reports a result both to anyone listening on [lastResult] and, if the
  /// app currently has a visible screen (it almost always will, since this
  /// only runs while the app is in the foreground), as a TopToast - even if
  /// that screen isn't the one that started the export.
  void _announce(ExportResultType type, String message) {
    lastResult.value = ExportResult(type, message);

    final ctx = AppNavigation.currentContext;
    if (ctx == null) return;

    switch (type) {
      case ExportResultType.success:
        TopToast.success(ctx, message);
        break;
      case ExportResultType.info:
        TopToast.info(ctx, message);
        break;
      case ExportResultType.error:
        TopToast.error(ctx, message);
        break;
    }
  }

  // ---------------------------------------------------------------------
  // Profit export
  // ---------------------------------------------------------------------

  Future<void> exportProfitXlsx({
    required String tenantId,
    required int year,
    String? shopId,
    required String shopName,
    required String profitType,
  }) async {
    if (isExporting) {
      _announce(ExportResultType.info, "An export is already in progress.");
      return;
    }
    if (tenantId.trim().isEmpty) return;

    //claim the export slot immediately - the internet check below awaits,
    //and doing this first closes the window where a second rapid call
    //(a fast double-tap, or tapping Profit then Stock in quick succession)
    //could start a duplicate concurrent export before isExporting flips
    //true. On failure we drop back to idle below.
    _setState(const ExportJobState(
      isExporting: true,
      isProfit: true,
      isStock: false,
      progress: 0.0,
      progressText: "Preparing profit export...",
    ));

    final canExport = await _ensureInternetForExport();
    if (!canExport) {
      _setState(ExportJobState.idle);
      return;
    }

    try {
      final fs = _firestore;
      _updateProgress(0.05, "Loading exported orders...");

      final yearStart = DateTime(year, 1, 1);
      final yearEnd = DateTime(year + 1, 1, 1);

      Query<Map<String, dynamic>> q = _ordersCol(tenantId)
          .where("isExported", isEqualTo: true)
          .where(
        "exportedAt",
        isGreaterThanOrEqualTo: Timestamp.fromDate(yearStart),
      )
          .where("exportedAt", isLessThan: Timestamp.fromDate(yearEnd));

      if ((shopId ?? "").isNotEmpty) {
        q = q.where("shopId", isEqualTo: shopId);
      }

      final ordersSnap = await q.get();
      _updateProgress(0.15, "Reading order items...");

      final Map<String, double> qtyByProductId = {};

      for (final o in ordersSnap.docs) {
        final itemsSnap = await o.reference.collection("items").get();
        for (final it in itemsSnap.docs) {
          final x = it.data();
          final productId = (x["productId"] ?? "").toString().trim();
          if (productId.isEmpty) continue;

          final qty = (x["qty"] is num)
              ? (x["qty"] as num).toDouble()
              : double.tryParse("${x["qty"]}") ?? 0.0;

          if (qty <= 0) continue;
          qtyByProductId[productId] = (qtyByProductId[productId] ?? 0) + qty;
        }
      }

      _updateProgress(0.35, "Loading products...");

      if (qtyByProductId.isEmpty) {
        _setState(ExportJobState.idle);
        _announce(
          ExportResultType.info,
          "No exported sales found for $shopName in $year.",
        );
        return;
      }

      final productIds = qtyByProductId.keys.toList();
      final productDocs = await Future.wait(
        productIds.map((id) => _productsCol(tenantId).doc(id).get()),
      );
      _updateProgress(0.45, "Downloading product images...");

      for (final pDoc in productDocs) {
        final p = pDoc.data() ?? {};
        final imageUrl = (p["imageUrl"] ?? "").toString().trim();
        if (imageUrl.isNotEmpty) {
          await _downloadImageBytes(imageUrl);
        }
      }

      String colDHeader = "Cost price";
      String colEHeader = "Retail price";
      String Function(int) profitItemFormula = (row) => "=E$row-D$row";

      switch (profitType) {
        case "storage":
          colDHeader = "Cost price";
          colEHeader = "Wholesale price";
          break;
        case "shop":
          colDHeader = "Wholesale price";
          colEHeader = "Retail price";
          break;
        case "total":
        default:
          colDHeader = "Cost price";
          colEHeader = "Retail price";
          break;
      }

      _updateProgress(0.75, "Building Excel workbook...");

      final workbook = xlsio.Workbook();
      final sheet = workbook.worksheets[0];
      sheet.name = "Profit";
      _applyLandscape(sheet);

      final headers = [
        "Image",
        "Code",
        "Qty sold",
        colDHeader,
        colEHeader,
        "Profit /item",
        "Profit",
      ];

      for (int c = 0; c < headers.length; c++) {
        sheet.getRangeByIndex(1, c + 1).setText(headers[c]);
      }
      _applyHeaderStyle(sheet, 1, 1, headers.length);
      sheet.getRangeByIndex(1, 1).rowHeight = _headerRowH;

      sheet.getRangeByIndex(1, 1).columnWidth = 14;
      sheet.getRangeByIndex(1, 2).columnWidth = 16;
      sheet.getRangeByIndex(1, 3).columnWidth = 10;
      sheet.getRangeByIndex(1, 4).columnWidth = 13;
      sheet.getRangeByIndex(1, 5).columnWidth = 13;
      sheet.getRangeByIndex(1, 6).columnWidth = 13;
      sheet.getRangeByIndex(1, 7).columnWidth = 13;

      final rows = <Map<String, dynamic>>[];

      for (final doc in productDocs) {
        if (!doc.exists) continue;
        final p = doc.data() ?? {};
        final productId = doc.id;

        final qty = qtyByProductId[productId] ?? 0;
        if (qty <= 0) continue;

        final code = (p["code"] ?? productId).toString().trim();
        final costUnit = await PriceUtil.getPrice(fs, tenantId, productId, "cost");
        final wholesaleUnit =
        await PriceUtil.getPrice(fs, tenantId, productId, "wholesale");
        final retailUnit = await PriceUtil.getPrice(fs, tenantId, productId, "retail");

        double colDValue = costUnit;
        double colEValue = retailUnit;

        switch (profitType) {
          case "storage":
            colDValue = costUnit;
            colEValue = wholesaleUnit;
            break;
          case "shop":
            colDValue = wholesaleUnit;
            colEValue = retailUnit;
            break;
          case "total":
          default:
            colDValue = costUnit;
            colEValue = retailUnit;
            break;
        }

        final profitItem = colEValue - colDValue;
        final profit = profitItem * qty;

        rows.add({
          "productId": productId,
          "code": code,
          "qty": qty,
          "colDValue": colDValue,
          "colEValue": colEValue,
          "profit": profit,
          "imageUrl": (p["imageUrl"] ?? "").toString().trim(),
        });
      }

      //sort by highest profit
      rows.sort(
            (a, b) => (b["profit"] as double).compareTo(a["profit"] as double),
      );

      int row = 2;
      final productEndRows = <int>[];

      for (final r in rows) {
        sheet.getRangeByIndex(row, 1).rowHeight = _normalRowH;

        sheet.getRangeByIndex(row, 2).setText((r["code"] ?? "").toString());

        final qtyCell = sheet.getRangeByIndex(row, 3);
        qtyCell.setNumber((r["qty"] as double));
        qtyCell.numberFormat = _qtyFmt;

        final dCell = sheet.getRangeByIndex(row, 4);
        dCell.setNumber((r["colDValue"] as double));
        dCell.numberFormat = _euroFmt;

        final eCell = sheet.getRangeByIndex(row, 5);
        eCell.setNumber((r["colEValue"] as double));
        eCell.numberFormat = _euroFmt;

        final profitItemCell = sheet.getRangeByIndex(row, 6);
        profitItemCell.setFormula(profitItemFormula(row));
        profitItemCell.numberFormat = _euroFmt;

        final profitCell = sheet.getRangeByIndex(row, 7);
        profitCell.setFormula("=F$row*C$row");
        profitCell.numberFormat = _euroFmt;

        final imageUrl = (r["imageUrl"] ?? "").toString();
        if (imageUrl.isNotEmpty) {
          final bytes = await _downloadImageBytes(imageUrl);
          if (bytes != null && bytes.isNotEmpty) {
            final pic = sheet.pictures.addStream(row, 1, bytes);
            pic.width = _picPx;
            pic.height = _picPx;
          }
        }

        productEndRows.add(row);
        row++;
      }

      final lastDataRow = row - 1;
      final totalsRow = lastDataRow + 2;

      final labelCell = sheet.getRangeByIndex(totalsRow, 6);
      labelCell.setText("TOTAL PROFIT");
      labelCell.cellStyle.bold = true;
      labelCell.cellStyle.hAlign = xlsio.HAlignType.right;

      final totalProfitCell = sheet.getRangeByIndex(totalsRow, 7);
      totalProfitCell.setFormula("=SUM(G2:G$lastDataRow)");
      totalProfitCell.numberFormat = _euroFmt;
      totalProfitCell.cellStyle.bold = true;

      if (lastDataRow >= 2) {
        _applyTableBordersCenter(sheet, 1, 1, lastDataRow, 7);
      }
      _applyTableBordersCenter(sheet, totalsRow, 6, totalsRow, 7);

      for (final rEnd in productEndRows) {
        if (rEnd >= 2 && rEnd <= lastDataRow) {
          _applyProductSeparator(sheet, rEnd, 1, 7);
        }
      }

      _updateProgress(0.90, "Saving Excel file...");

      final bytes = workbook.saveAsStream();
      workbook.dispose();

      final (safeShop, safeShopFile) = _safeShopNameAndFile(shopName);
      final safeTypeFile = (profitExportTypeLabels[profitType] ?? "Total")
          .replaceAll(" ", "_")
          .toLowerCase();
      //filename of profit export
      final filename = "profit_${safeTypeFile}_${safeShopFile}_$year.xlsx";
      final shareText =
          "Profit export (${profitExportTypeLabels[profitType] ?? "Total"} • $safeShop • $year)";

      _updateProgress(
        0.97,
        _isHomeVisible ? "Opening share menu..." : "Finishing up...",
      );

      await _shareNowOrWhenHomeVisible(
        filename: filename,
        bytes: bytes,
        shareText: shareText,
      );

      _updateProgress(1.0, "Profit export ready.");
      //brief pause so the "ready" message is actually visible before the
      //progress indicator is hidden below
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final sharedNow = _isHomeVisible;
      _setState(ExportJobState.idle);

      _announce(
        sharedNow ? ExportResultType.success : ExportResultType.info,
        sharedNow
            ? "Profit export successful."
            : "Profit export ready — open Home to share it.",
      );
    } catch (e) {
      _setState(ExportJobState.idle);
      _announce(ExportResultType.error, _friendlyExportError(e));
    }
  }

  // ---------------------------------------------------------------------
  // Stock export
  // ---------------------------------------------------------------------

  Future<void> exportStockXlsx({
    required String tenantId,
    required int year,
    String? shopId,
    required String shopName,
  }) async {
    if (isExporting) {
      _announce(ExportResultType.info, "An export is already in progress.");
      return;
    }
    if (tenantId.trim().isEmpty) return;

    //claim the export slot immediately - see the same comment in
    //exportProfitXlsx
    _setState(const ExportJobState(
      isExporting: true,
      isProfit: false,
      isStock: true,
      progress: 0.0,
      progressText: "Preparing stock export...",
    ));

    final canExport = await _ensureInternetForExport();
    if (!canExport) {
      _setState(ExportJobState.idle);
      return;
    }

    try {
      final fs = _firestore;
      _updateProgress(0.05, "Loading products...");

      final yearStart = DateTime(year, 1, 1);
      final yearEnd = DateTime(year + 1, 1, 1);

      final productsSnap = await _productsCol(tenantId).get();
      final products = productsSnap.docs;
      _updateProgress(0.15, "Checking product data...");

      if (products.isEmpty) {
        _setState(ExportJobState.idle);
        _announce(ExportResultType.info, "There are no products to export yet.");
        return;
      }

      _updateProgress(0.25, "Downloading product images...");

      //preload product images
      for (final p in products) {
        final data = p.data();
        final imageUrl = (data["imageUrl"] ?? "").toString().trim();
        if (imageUrl.isNotEmpty) {
          await _downloadImageBytes(imageUrl);
        }
      }

      Query<Map<String, dynamic>> oq = _ordersCol(tenantId)
          .where("isExported", isEqualTo: true)
          .where(
        "exportedAt",
        isGreaterThanOrEqualTo: Timestamp.fromDate(yearStart),
      )
          .where("exportedAt", isLessThan: Timestamp.fromDate(yearEnd));

      if ((shopId ?? "").isNotEmpty) {
        oq = oq.where("shopId", isEqualTo: shopId);
      }

      final ordersSnap = await oq.get();
      _updateProgress(0.40, "Reading exported order items...");

      final Map<String, double> soldByProduct = {};
      final Map<String, double> soldByProductSize = {};

      for (final o in ordersSnap.docs) {
        final itemsSnap = await o.reference.collection("items").get();
        for (final it in itemsSnap.docs) {
          final x = it.data();

          final productId = (x["productId"] ?? "").toString().trim();
          if (productId.isEmpty) continue;

          final qty = (x["qty"] is num)
              ? (x["qty"] as num).toDouble()
              : double.tryParse("${x["qty"]}") ?? 0.0;
          if (qty <= 0) continue;

          final sizeRaw = (x["size"] ?? "").toString().trim();
          final sizeKey = _normalizeSizeKey(sizeRaw);

          if (sizeKey.isNotEmpty) {
            final key = "$productId|$sizeKey";
            soldByProductSize[key] = (soldByProductSize[key] ?? 0) + qty;
          } else {
            soldByProduct[productId] = (soldByProduct[productId] ?? 0) + qty;
          }
        }
      }

      _updateProgress(0.50, "Reading stock movements...");

      final Map<String, double> addedByProduct = {};
      final Map<String, double> addedByProductSize = {};

      //read stock movements (add,adjust,undo)
      Future<void> readProductMovements(
          String productId,
          Map<String, dynamic> productData,
          ) async {
        final isSized = _isSizedProduct(productData);

        final movesSnap = await _firestore
            .collection("tenants")
            .doc(tenantId)
            .collection("products")
            .doc(productId)
            .collection("stock_movements")
            .where("at", isGreaterThanOrEqualTo: Timestamp.fromDate(yearStart))
            .where("at", isLessThan: Timestamp.fromDate(yearEnd))
            .get();

        for (final mDoc in movesSnap.docs) {
          final m = mDoc.data();

          final type = (m["type"] ?? "").toString().trim().toLowerCase();
          final bool countsAsAdded =
              type == "add" || type == "adjust" || type.startsWith("undo");
          if (!countsAsAdded) continue;

          final sizeDeltaRaw = _asStringDynamicMap(m["sizeDelta"]);

          if (isSized && sizeDeltaRaw.isNotEmpty) {
            for (final entry in sizeDeltaRaw.entries) {
              final sz = _normalizeSizeKey(entry.key);
              if (sz.isEmpty) continue;

              final v = entry.value;
              final d =
              (v is num) ? v.toDouble() : double.tryParse("$v") ?? 0.0;
              if (d == 0) continue;

              final key = "$productId|$sz";
              addedByProductSize[key] = (addedByProductSize[key] ?? 0) + d;
            }
          } else {
            final delta = (m["delta"] is num)
                ? (m["delta"] as num).toDouble()
                : double.tryParse("${m["delta"]}") ?? 0.0;

            if (delta == 0) continue;
            addedByProduct[productId] = (addedByProduct[productId] ?? 0) + delta;
          }
        }
      }

      for (final p in products) {
        await readProductMovements(p.id, p.data());
      }

      _updateProgress(0.65, "Reading opening stock...");

      final Map<String, double> openingByProduct = {};
      final Map<String, double> openingByProductSize = {};

      //get opening stock
      Future<void> readOpening(
          String productId,
          Map<String, dynamic> productData,
          ) async {
        final isSized = _isSizedProduct(productData);

        final yDoc = await _firestore
            .collection("tenants")
            .doc(tenantId)
            .collection("products")
            .doc(productId)
            .collection("stock_years")
            .doc(year.toString())
            .get();

        if (!yDoc.exists) {
          openingByProduct[productId] = 0;

          if (isSized) {
            final productSizeStock = _asStringDynamicMap(productData["sizeStock"]);
            for (final entry in productSizeStock.entries) {
              final sz = _normalizeSizeKey(entry.key);
              if (sz.isEmpty) continue;
              final v = entry.value;
              final d =
              (v is num) ? v.toDouble() : double.tryParse("$v") ?? 0.0;
              openingByProductSize["$productId|$sz"] = d;
            }
          }
          return;
        }

        final y = yDoc.data() ?? {};
        final init = (y["initialStock"] is num)
            ? (y["initialStock"] as num).toDouble()
            : double.tryParse("${y["initialStock"]}") ?? 0.0;

        openingByProduct[productId] = init;

        if (isSized) {
          final initSizeRaw = _asStringDynamicMap(y["initialSizeStock"]);
          final currentSizeRaw = _asStringDynamicMap(y["currentSizeStock"]);
          final productSizeRaw = _asStringDynamicMap(productData["sizeStock"]);

          final effectiveSizeStock = initSizeRaw.isNotEmpty
              ? initSizeRaw
              : currentSizeRaw.isNotEmpty
              ? currentSizeRaw
              : productSizeRaw;

          for (final entry in effectiveSizeStock.entries) {
            final sz = _normalizeSizeKey(entry.key);
            if (sz.isEmpty) continue;

            final v = entry.value;
            final d = (v is num) ? v.toDouble() : double.tryParse("$v") ?? 0.0;
            final key = "$productId|$sz";
            openingByProductSize[key] = d;
          }
        }
      }

      for (final p in products) {
        await readOpening(p.id, p.data());
      }

      _updateProgress(0.75, "Building Excel workbook...");

      final workbook = xlsio.Workbook();
      final sheet = workbook.worksheets[0];
      sheet.name = "Stock";
      _applyLandscape(sheet);

      final headers = [
        "Image",
        "Code",
        "Size",
        "Opening qnty",
        "Qnty added",
        "Qty sold",
        "Closing qnty",
        "Cost price",
        "Wholesale price",
        "Total cost",
        "Total wholesale",
      ];

      for (int c = 0; c < headers.length; c++) {
        sheet.getRangeByIndex(1, c + 1).setText(headers[c]);
      }
      _applyHeaderStyle(sheet, 1, 1, headers.length);
      sheet.getRangeByIndex(1, 1).rowHeight = _headerRowH;

      sheet.getRangeByIndex(1, 1).columnWidth = 14;
      sheet.getRangeByIndex(1, 2).columnWidth = 14;
      sheet.getRangeByIndex(1, 3).columnWidth = 10;
      sheet.getRangeByIndex(1, 4).columnWidth = 12;
      sheet.getRangeByIndex(1, 5).columnWidth = 12;
      sheet.getRangeByIndex(1, 6).columnWidth = 10;
      sheet.getRangeByIndex(1, 7).columnWidth = 12;
      sheet.getRangeByIndex(1, 8).columnWidth = 13;
      sheet.getRangeByIndex(1, 9).columnWidth = 16;
      sheet.getRangeByIndex(1, 10).columnWidth = 14;
      sheet.getRangeByIndex(1, 11).columnWidth = 16;

      final rows = <Map<String, dynamic>>[];

      Iterable<String> sizeKeysFromMap(
          String productId,
          Map<String, double> source,
          ) sync* {
        final prefix = "$productId|";
        for (final key in source.keys) {
          if (key.startsWith(prefix)) {
            final size = key.substring(prefix.length).trim();
            if (size.isNotEmpty) yield size;
          }
        }
      }

      for (final p in products) {
        final pd = p.data();
        final productId = p.id;
        final code = (pd["code"] ?? productId).toString().trim();
        final isSized = _isSizedProduct(pd);
        final imageUrl = (pd["imageUrl"] ?? "").toString().trim();

        final cost = await PriceUtil.getPrice(fs, tenantId, productId, "cost");
        final wholesale = await PriceUtil.getPrice(fs, tenantId, productId, "wholesale");

        final extraSizes = <String>[
          ...sizeKeysFromMap(productId, openingByProductSize),
          ...sizeKeysFromMap(productId, addedByProductSize),
          ...sizeKeysFromMap(productId, soldByProductSize),
        ];

        final sizeLabels = isSized
            ? _sizeLabelsForProduct(pd, extraSizes: extraSizes)
            : <String>[];

        if (!isSized || sizeLabels.isEmpty) {
          final opening = openingByProduct[productId] ?? 0;
          final added = addedByProduct[productId] ?? 0;
          final sold = soldByProduct[productId] ?? 0;
          final closing = opening + added - sold;

          rows.add({
            "isSizedItem": false,
            "productId": productId,
            "code": code,
            "size": "",
            "opening": opening,
            "added": added,
            "sold": sold,
            "closing": closing,
            "cost": cost,
            "wholesale": wholesale,
            "imageUrl": imageUrl,
            "sizeOrder": 0,
          });
        } else {
          for (int sizeIndex = 0; sizeIndex < sizeLabels.length; sizeIndex++) {
            final sz = sizeLabels[sizeIndex];
            final key = "$productId|${_normalizeSizeKey(sz)}";

            final openingSz = openingByProductSize[key] ?? 0.0;
            final addedSz = addedByProductSize[key] ?? 0.0;
            final soldSz = soldByProductSize[key] ?? 0.0;
            final closingSz = openingSz + addedSz - soldSz;

            rows.add({
              "isSizedItem": true,
              "productId": productId,
              "code": code,
              "size": sz,
              "opening": openingSz,
              "added": addedSz,
              "sold": soldSz,
              "closing": closingSz,
              "cost": cost,
              "wholesale": wholesale,
              "imageUrl": imageUrl,
              "sizeOrder": sizeIndex,
            });
          }
        }
      }

      //sort with code and keep each product's saved size order
      rows.sort((a, b) {
        final codeCompare = (a["code"] as String).compareTo(b["code"] as String);
        if (codeCompare != 0) return codeCompare;

        final productCompare =
        (a["productId"] as String).compareTo(b["productId"] as String);
        if (productCompare != 0) return productCompare;

        final aOrder = (a["sizeOrder"] is num) ? (a["sizeOrder"] as num).toInt() : 0;
        final bOrder = (b["sizeOrder"] is num) ? (b["sizeOrder"] as num).toInt() : 0;
        return aOrder.compareTo(bOrder);
      });

      int row = 2;
      int i = 0;
      final productEndRows = <int>[];

      while (i < rows.length) {
        final r = rows[i];
        final bool isSizedItem = r["isSizedItem"] == true;

        if (!isSizedItem) {
          sheet.getRangeByIndex(row, 1).rowHeight = _normalRowH;

          final imageUrl = (r["imageUrl"] ?? "").toString();
          if (imageUrl.isNotEmpty) {
            final bytes = await _downloadImageBytes(imageUrl);
            if (bytes != null && bytes.isNotEmpty) {
              final pic = sheet.pictures.addStream(row, 1, bytes);
              pic.width = _picPx;
              pic.height = _picPx;
            }
          }

          sheet.getRangeByIndex(row, 2).setText((r["code"] ?? "").toString());
          sheet.getRangeByIndex(row, 3).setText("");

          for (final col in [4, 5, 6, 7]) {
            sheet.getRangeByIndex(row, col).numberFormat = _qtyFmt;
          }

          sheet.getRangeByIndex(row, 4).setNumber((r["opening"] as double));
          sheet.getRangeByIndex(row, 5).setNumber((r["added"] as double));
          sheet.getRangeByIndex(row, 6).setNumber((r["sold"] as double));
          sheet.getRangeByIndex(row, 7).setNumber((r["closing"] as double));

          final costCell = sheet.getRangeByIndex(row, 8);
          costCell.setNumber((r["cost"] as double));
          costCell.numberFormat = _euroFmt;

          final whCell = sheet.getRangeByIndex(row, 9);
          whCell.setNumber((r["wholesale"] as double));
          whCell.numberFormat = _euroFmt;

          final totalCostCell = sheet.getRangeByIndex(row, 10);
          totalCostCell.setFormula("=G$row*H$row");
          totalCostCell.numberFormat = _euroFmt;

          final totalWholesaleCell = sheet.getRangeByIndex(row, 11);
          totalWholesaleCell.setFormula("=G$row*I$row");
          totalWholesaleCell.numberFormat = _euroFmt;

          productEndRows.add(row);

          row++;
          i++;
          continue;
        }

        //same block layout for all sized items: adult T-shirts, kids T-shirts, and shoes
        final productId = (r["productId"] ?? "").toString();
        final startRow = row;

        final block = <Map<String, dynamic>>[];
        while (i < rows.length) {
          final rr = rows[i];
          if (rr["isSizedItem"] != true) break;
          if ((rr["productId"] ?? "").toString() != productId) break;
          block.add(rr);
          i++;
        }

        final endRow = startRow + block.length - 1;
        final fitPhotoRowHeight = _picPx / block.length;
        final sizedRowHeight = block.length == 1
            ? _normalRowH
            : (fitPhotoRowHeight > _sizedItemRowH
            ? fitPhotoRowHeight
            : _sizedItemRowH);

        for (int rr = startRow; rr <= endRow; rr++) {
          sheet.getRangeByIndex(rr, 1).rowHeight = sizedRowHeight;
        }

        xlsio.Range imgRange;
        xlsio.Range codeRange;
        xlsio.Range costRange;
        xlsio.Range whRange;
        xlsio.Range totalCostRange;
        xlsio.Range totalWhRange;

        if (endRow > startRow) {
          imgRange = sheet.getRangeByIndex(startRow, 1, endRow, 1)..merge();
          codeRange = sheet.getRangeByIndex(startRow, 2, endRow, 2)..merge();
          costRange = sheet.getRangeByIndex(startRow, 8, endRow, 8)..merge();
          whRange = sheet.getRangeByIndex(startRow, 9, endRow, 9)..merge();
          totalCostRange = sheet.getRangeByIndex(startRow, 10, endRow, 10)..merge();
          totalWhRange = sheet.getRangeByIndex(startRow, 11, endRow, 11)..merge();
        } else {
          imgRange = sheet.getRangeByIndex(startRow, 1);
          codeRange = sheet.getRangeByIndex(startRow, 2);
          costRange = sheet.getRangeByIndex(startRow, 8);
          whRange = sheet.getRangeByIndex(startRow, 9);
          totalCostRange = sheet.getRangeByIndex(startRow, 10);
          totalWhRange = sheet.getRangeByIndex(startRow, 11);
        }

        for (final rng in [
          imgRange,
          codeRange,
          costRange,
          whRange,
          totalCostRange,
          totalWhRange,
        ]) {
          rng.cellStyle.vAlign = xlsio.VAlignType.center;
          rng.cellStyle.hAlign = xlsio.HAlignType.center;
        }

        final imageUrl = (block.first["imageUrl"] ?? "").toString();
        if (imageUrl.isNotEmpty) {
          final bytes = await _downloadImageBytes(imageUrl);
          if (bytes != null && bytes.isNotEmpty) {
            final anchorRow = startRow + ((block.length - 1) ~/ 2);
            final pic = sheet.pictures.addStream(anchorRow, 1, bytes);
            pic.width = _picPx;
            pic.height = _picPx;
          }
        }

        sheet
            .getRangeByIndex(startRow, 2)
            .setText((block.first["code"] ?? "").toString());

        final costCell = sheet.getRangeByIndex(startRow, 8);
        costCell.setNumber((block.first["cost"] as double));
        costCell.numberFormat = _euroFmt;

        final whCell = sheet.getRangeByIndex(startRow, 9);
        whCell.setNumber((block.first["wholesale"] as double));
        whCell.numberFormat = _euroFmt;

        final jCell = sheet.getRangeByIndex(startRow, 10);
        jCell.setFormula("=SUM(G$startRow:G$endRow)*H$startRow");
        jCell.numberFormat = _euroFmt;

        final kCell = sheet.getRangeByIndex(startRow, 11);
        kCell.setFormula("=SUM(G$startRow:G$endRow)*I$startRow");
        kCell.numberFormat = _euroFmt;

        int rr = startRow;
        for (final line in block) {
          sheet.getRangeByIndex(rr, 3).setText((line["size"] ?? "").toString());

          for (final col in [4, 5, 6, 7]) {
            sheet.getRangeByIndex(rr, col).numberFormat = _qtyFmt;
          }

          sheet.getRangeByIndex(rr, 4).setNumber((line["opening"] as double));
          sheet.getRangeByIndex(rr, 5).setNumber((line["added"] as double));
          sheet.getRangeByIndex(rr, 6).setNumber((line["sold"] as double));
          sheet.getRangeByIndex(rr, 7).setNumber((line["closing"] as double));

          rr++;
        }

        productEndRows.add(endRow);
        row = endRow + 1;
      }

      final lastDataRow = row - 1;

      final totalsRow = lastDataRow + 3;
      sheet.getRangeByIndex(totalsRow, 2).setText("TOTALS");
      sheet.getRangeByIndex(totalsRow, 2).cellStyle.bold = true;
      sheet.getRangeByIndex(totalsRow, 2).cellStyle.hAlign =
          xlsio.HAlignType.right;

      sheet.getRangeByIndex(totalsRow, 4).setFormula("=SUM(D2:D$lastDataRow)");
      sheet.getRangeByIndex(totalsRow, 5).setFormula("=SUM(E2:E$lastDataRow)");
      sheet.getRangeByIndex(totalsRow, 6).setFormula("=SUM(F2:F$lastDataRow)");
      sheet.getRangeByIndex(totalsRow, 7).setFormula("=SUM(G2:G$lastDataRow)");

      for (final col in [4, 5, 6, 7]) {
        final c = sheet.getRangeByIndex(totalsRow, col);
        c.numberFormat = _qtyFmt;
        c.cellStyle.bold = true;
      }

      final totalCostAll = sheet.getRangeByIndex(totalsRow, 10);
      totalCostAll.setFormula("=SUM(J2:J$lastDataRow)");
      totalCostAll.numberFormat = _euroFmt;
      totalCostAll.cellStyle.bold = true;

      final totalWholesaleAll = sheet.getRangeByIndex(totalsRow, 11);
      totalWholesaleAll.setFormula("=SUM(K2:K$lastDataRow)");
      totalWholesaleAll.numberFormat = _euroFmt;
      totalWholesaleAll.cellStyle.bold = true;

      if (lastDataRow >= 2) {
        _applyTableBordersCenter(sheet, 1, 1, lastDataRow, 11);
      }
      _applyTableBordersCenter(sheet, totalsRow, 2, totalsRow, 11);

      for (final rEnd in productEndRows) {
        if (rEnd >= 2 && rEnd <= lastDataRow) {
          _applyProductSeparator(sheet, rEnd, 1, 11);
        }
      }

      _updateProgress(0.90, "Saving Excel file...");

      final bytes = workbook.saveAsStream();
      workbook.dispose();

      final (safeShop, safeShopFile) = _safeShopNameAndFile(shopName);
      final filename = "stock_${safeShopFile}_$year.xlsx";
      final shareText = "Stock export ($safeShop • $year)";

      _updateProgress(
        0.97,
        _isHomeVisible ? "Opening share menu..." : "Finishing up...",
      );

      await _shareNowOrWhenHomeVisible(
        filename: filename,
        bytes: bytes,
        shareText: shareText,
      );

      _updateProgress(1.0, "Stock export ready.");
      //brief pause so the "ready" message is actually visible before the
      //progress indicator is hidden below
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final sharedNow = _isHomeVisible;
      _setState(ExportJobState.idle);

      _announce(
        sharedNow ? ExportResultType.success : ExportResultType.info,
        sharedNow
            ? "Stock export successful."
            : "Stock export ready — open Home to share it.",
      );
    } catch (e) {
      _setState(ExportJobState.idle);
      _announce(ExportResultType.error, _friendlyExportError(e));
    }
  }
}