//home dashboard screen
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_xlsio/xlsio.dart' as xlsio;

import '../services/tenant_context_service.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/top_toast.dart';
import 'files_screen.dart';
import 'movement_history_screen.dart';

//widget declaration
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TenantContextService _tenantContextService = TenantContextService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  //dashboard month and year selection
  int _dashMonth = DateTime.now().month;
  int _dashYear = DateTime.now().year;

  DateTime get _dashMonthStart => DateTime(_dashYear, _dashMonth, 1);
  DateTime get _dashMonthEnd => DateTime(_dashYear, _dashMonth + 1, 1);

  static const List<String> _monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ];

  //export options
  int _exportYear = DateTime.now().year;

  String? _exportShopId;
  String _exportShopName = "All";
  String _profitExportType = "total";

  //maps internal export type values to text
  static const Map<String, String> _profitExportTypeLabels = {
    "storage": "Storage",
    "shop": "Shop",
    "total": "Total",
  };

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _shops = [];

  //export flags
  bool _exporting = false;
  bool _exportingProfit = false;
  bool _exportingStock = false;

  //loading flags
  bool _loadingTenant = true;
  bool _isAdmin = false;

  String? _tenantId;
  StreamSubscription<User?>? _authSub;
  int _authLoadToken = 0;

  //cashes
  final Map<String, Uint8List?> _imageCache = {};
  final Map<String, String> _userNameCache = {};

  static const List<String> _sizes = [
    "XXS", "XS", "S", "M",
    "L", "XL", "2XL", "3XL",
  ];

  //excel layout constants
  static const int _picPx = 100;
  static const double _headerRowH = 28;
  static const double _normalRowH = 84;
  static const double _tshirtRowH = 18;

  static const String _euroFmt = '€#,##0.00';
  static const String _qtyFmt = '0';

  @override
  void initState() {
    super.initState();
    _listenToAuth();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose(); //avoid memory leaks
  }

  //firestore helper methods to access tenant collections
  CollectionReference<Map<String, dynamic>> _tenantProductsRef(String tenantId) {
    return _firestore.collection("tenants").doc(tenantId).collection("products");
  }

  CollectionReference<Map<String, dynamic>> _tenantOrdersRef(String tenantId) {
    return _firestore.collection("tenants").doc(tenantId).collection("orders");
  }

  CollectionReference<Map<String, dynamic>> _tenantMovementHistoryRef(
      String tenantId,
      ) {
    return _firestore
        .collection("tenants")
        .doc(tenantId)
        .collection("movement_history");
  }

  //query for tenant shops
  Query<Map<String, dynamic>> _tenantShopsQuery(String tenantId) {
    return _firestore
        .collection("tenants")
        .doc(tenantId)
        .collection("shops")
        .orderBy("createdAt", descending: false); //ordered by creation date
  }

  //auth listener
  void _listenToAuth() {
    _authSub?.cancel();

    _authSub = _auth.authStateChanges().listen((user) async {
      final token = ++_authLoadToken;
      if (!mounted) return;

      //user log out
      if (user == null) {
        setState(() {
          _tenantId = null;
          _shops = [];
          _exportShopId = null;
          _exportShopName = "All";
          _isAdmin = false;
          _loadingTenant = false;
          _exporting = false;
          _exportingProfit = false;
          _exportingStock = false;
        });
        return;
      }

      //user logs in
      setState(() {
        _loadingTenant = true;
        _tenantId = null;
        _shops = [];
        _exportShopId = null;
        _exportShopName = "All";
        _isAdmin = false;
      });

      await _loadTenantAndAdmin(token);
    });
  }

  //load tenant and admin data
  Future<void> _loadTenantAndAdmin(int token) async {
    try {
      final user = _auth.currentUser; //safety check
      if (user == null) {
        if (!mounted || token != _authLoadToken) return;
        setState(() {
          _tenantId = null;
          _shops = [];
          _exportShopId = null;
          _exportShopName = "All";
          _isAdmin = false;
          _loadingTenant = false;
        });
        return;
      }

      //load cache
      final cachedProfile =
      await _tenantContextService.tryGetCurrentUserProfileCacheOnly();

      final cachedTenantId =
      (cachedProfile?["tenantId"] ?? "").toString().trim();
      final cachedRole = (cachedProfile?["role"] ?? "")
          .toString()
          .trim()
          .toLowerCase();
      final cachedIsAdmin = cachedRole == "admin";

      if (cachedTenantId.isNotEmpty) {
        final cachedShops = await _fetchShopsForTenantCacheOnly(cachedTenantId);
        if (!mounted || token != _authLoadToken) return;

        final normalized = _normalizeExportShopSelection(cachedShops);

        setState(() {
          _tenantId = cachedTenantId;
          _isAdmin = cachedIsAdmin;
          _shops = cachedShops;
          _exportShopId = normalized.$1;
          _exportShopName = normalized.$2;
          _loadingTenant = false;
        });
      }

      final freshProfile =
      await _tenantContextService.tryGetCurrentUserProfile();
      if (!mounted || token != _authLoadToken) return;

      final effectiveProfile =
          freshProfile ?? cachedProfile ?? <String, dynamic>{};

      final tenantId = (effectiveProfile["tenantId"] ?? "").toString().trim();
      final role =
      (effectiveProfile["role"] ?? "").toString().trim().toLowerCase();
      final isAdmin = role == "admin";

      if (tenantId.isEmpty) {
        setState(() {
          _tenantId = null;
          _shops = [];
          _exportShopId = null;
          _exportShopName = "All";
          _isAdmin = false;
          _loadingTenant = false;
        });
        return;
      }

      final shops = await _fetchShopsForTenantServerThenCache(tenantId);
      if (!mounted || token != _authLoadToken) return;

      final normalized = _normalizeExportShopSelection(shops);

      setState(() {
        _tenantId = tenantId;
        _isAdmin = isAdmin;
        _shops = shops;
        _exportShopId = normalized.$1;
        _exportShopName = normalized.$2;
        _loadingTenant = false;
      });
    } catch (_) {
      if (!mounted || token != _authLoadToken) return;

      setState(() {
        _tenantId = null;
        _shops = [];
        _exportShopId = null;
        _exportShopName = "All";
        _isAdmin = false;
        _loadingTenant = false;
      });
    }
  }

  //checks whether the selected export shop still exists in the current shop list
  (String?, String) _normalizeExportShopSelection(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> shops,
      ) {
    String? exportShopId = _exportShopId;
    String exportShopName = "All";

    if (exportShopId != null) {
      final match = shops.where((s) => s.id == exportShopId).toList();
      final name = match.isEmpty
          ? ""
          : (match.first.data()["name"] ?? "").toString().trim();

      if (name.isEmpty) {
        exportShopId = null;
        exportShopName = "All";
      } else {
        exportShopName = name;
      }
    }

    return (exportShopId, exportShopName);
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  //fetch shops only from firestore cache
  _fetchShopsForTenantCacheOnly(String tenantId) async {
    try {
      final snap = await _tenantShopsQuery(tenantId)
          .get(const GetOptions(source: Source.cache))
          .timeout(const Duration(milliseconds: 500));
      return snap.docs;
    } catch (_) {
      return [];
    }
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  //server then cache
  _fetchShopsForTenantServerThenCache(String tenantId) async {
    try {
      final snap = await _tenantShopsQuery(tenantId)
          .get()
          .timeout(const Duration(milliseconds: 1200));
      return snap.docs;
    } catch (_) {
      return _fetchShopsForTenantCacheOnly(tenantId);
    }
  }

  //check internet connection
  Future<bool> _hasInternetConnection() async {
    try {
      final List<ConnectivityResult> results =
      await Connectivity().checkConnectivity();

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

  //ensure that before exporting there is internet connection
  Future<bool> _ensureInternetForExport() async {
    final hasInternet = await _hasInternetConnection();

    if (!hasInternet && mounted) {
      TopToast.error(
        context,
        "No internet connection. Please connect to Wi-Fi or mobile data to export.",
      );
    }

    return hasInternet;
  }

  //download image and caching
  Future<Uint8List?> _downloadImageBytes(String url) async {
    final clean = url.trim();
    if (clean.isEmpty) return null;

    if (_imageCache.containsKey(clean)) return _imageCache[clean];

    try {
      final uri = Uri.tryParse(clean);
      if (uri == null) {
        _imageCache[clean] = null;
        return null;
      }

      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        _imageCache[clean] = resp.bodyBytes;
        return resp.bodyBytes;
      }
    } catch (_) {}

    _imageCache[clean] = null;
    return null;
  }

  //path formating helpers
  List<String> _asStringList(dynamic v) {
    if (v is List) {
      return v
          .map((e) => e.toString())
          .where((s) => s.trim().isNotEmpty)
          .toList();
    }
    return [];
  }

  String _formatPathNames(dynamic v) {
    final list = _asStringList(v);
    if (list.isEmpty) return "Root";
    return list.join(" > ");
  }

  String _foldersOnlyFromPath(dynamic v) {
    final list = _asStringList(v);
    if (list.isEmpty) return "Root";

    final folders =
    list.length > 1 ? list.take(list.length - 1).toList() : <String>[];
    if (folders.isEmpty) return "Root";

    final last = folders.last.trim().toLowerCase();
    if (last == "out of stock") {
      return "Out of stock";
    }

    return folders.join(" > ");
  }

  //formats firestore timestamp
  String _formatTime(Timestamp? ts) {
    if (ts == null) return "";
    final d = ts.toDate();
    return "${d.year}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")} "
        "${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}";
  }

  Future<void> _shareFile({
    required String filename,
    required List<int> bytes,
    required String shareText,
  }) async {
    final dir = await Directory.systemTemp.createTemp("ims_exports_");
    final file = File("${dir.path}/$filename");
    await file.writeAsBytes(bytes, flush: true);

    if (!mounted) return;
    await Share.shareXFiles([XFile(file.path)], text: shareText);
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  _fetchOrdersForDashMonth(String tenantId) async {
    final snap = await _tenantOrdersRef(tenantId)
        .where("isExported", isEqualTo: true)
        .where(
      "exportedAt",
      isGreaterThanOrEqualTo: Timestamp.fromDate(_dashMonthStart),
    )
        .where("exportedAt", isLessThan: Timestamp.fromDate(_dashMonthEnd))
        .get();

    return snap.docs;
  }

  //main analytic method
  Future<Map<String, dynamic>> _computeInsights(String tenantId) async {
    //get order from selected month
    final orders = await _fetchOrdersForDashMonth(tenantId);

    //create tracking maps
    final Map<String, int> qtyByProductId = {};
    final Map<String, int> orderFreqByProductId = {};
    final Map<String, Map<String, dynamic>> metaByProductId = {};

    //loop through orders and items
    for (final o in orders) {
      final itemsSnap = await o.reference.collection("items").get();

      //don't count the same item twice in one order for frequency
      final Set<String> productsSeenInThisOrder = {};

      for (final it in itemsSnap.docs) {
        final m = it.data();

        final productId = (m["productId"] ?? "").toString().trim();
        final code = (m["code"] ?? "").toString().trim();
        final qty = (m["qty"] is num)
            ? (m["qty"] as num).toInt()
            : int.tryParse("${m["qty"]}") ?? 0;

        if (productId.isEmpty && code.isEmpty) continue;

        final key = productId.isNotEmpty ? productId : code;

        //best sellers
        qtyByProductId[key] = (qtyByProductId[key] ?? 0) + qty;

        //fast moving
        if (!productsSeenInThisOrder.contains(key)) {
          orderFreqByProductId[key] = (orderFreqByProductId[key] ?? 0) + 1;
          productsSeenInThisOrder.add(key);
        }

        metaByProductId.putIfAbsent(key, () {
          return {
            "productId": productId,
            "code": code,
            "size": (m["size"] ?? "").toString(),
            "description": (m["description"] ?? "").toString(),
            "folderPathNames": m["folderPathNames"],
          };
        });
      }
    }

    //sort fast moving
    final fastSorted = orderFreqByProductId.entries.toList()
      ..sort((a, b) {
        final freqCompare = b.value.compareTo(a.value);
        if (freqCompare != 0) return freqCompare;

        // Tie-breaker: higher qty sold first
        final qtyA = qtyByProductId[a.key] ?? 0;
        final qtyB = qtyByProductId[b.key] ?? 0;
        return qtyB.compareTo(qtyA);
      });

    final fastMovingTop10 = fastSorted.take(10).map((e) {
      final meta = metaByProductId[e.key] ?? {};
      return {
        "key": e.key,
        "orderCount": e.value,
        "qty": qtyByProductId[e.key] ?? 0,
        ...meta,
      };
    }).toList();

    //sort best sellers
    final bestSorted = qtyByProductId.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final top5 = bestSorted.take(5).map((e) {
      final meta = metaByProductId[e.key] ?? {};
      return {
        "key": e.key,
        "qty": e.value,
        "orderCount": orderFreqByProductId[e.key] ?? 0,
        ...meta,
      };
    }).toList();

    //6 month revenue
    final now = DateTime(_dashYear, _dashMonth, 1);
    final months = List.generate(
      6,
          (i) => DateTime(now.year, now.month - (5 - i), 1),
    );

    final List<Map<String, dynamic>> trend = [];

    for (final m in months) {
      final start = DateTime(m.year, m.month, 1);
      final end = DateTime(m.year, m.month + 1, 1);

      final snap = await _tenantOrdersRef(tenantId)
          .where("isExported", isEqualTo: true)
          .where(
        "exportedAt",
        isGreaterThanOrEqualTo: Timestamp.fromDate(start),
      )
          .where("exportedAt", isLessThan: Timestamp.fromDate(end))
          .get();

      double totalRevenue = 0;

      for (final o in snap.docs) {
        final itemsSnap = await o.reference.collection("items").get();

        for (final it in itemsSnap.docs) {
          final x = it.data();
          final qty = (x["qty"] is num)
              ? (x["qty"] as num).toDouble()
              : double.tryParse("${x["qty"]}") ?? 0;

          final productId = (x["productId"] ?? "").toString();
          if (productId.isEmpty) continue;

          final retail =
          await _getPrice(_firestore, tenantId, productId, "retail");
          totalRevenue += retail * qty;
        }
      }

      trend.add({
        "label": "${_monthNames[m.month - 1]} ${m.year}",
        "revenue": totalRevenue,
      });
    }

    return {
      "fastMovingTop10": fastMovingTop10,
      "top5": top5,
      "trend": trend,
      "orderCount": orders.length,
    };
  }

  //fetch price
  Future<double> _getPrice(
      FirebaseFirestore fs,
      String tenantId,
      String productId,
      String type,
      ) async {
    try {
      final productRef = fs
          .collection("tenants")
          .doc(tenantId)
          .collection("products")
          .doc(productId);

      final doc = await productRef.collection("prices").doc(type).get();
      if (doc.exists) {
        final d = doc.data() ?? {};
        final key = type == "retail"
            ? "retailPrice"
            : type == "wholesale"
            ? "wholesalePrice"
            : "costPrice";
        final raw = d[key];
        if (raw is num) return raw.toDouble();
        return double.tryParse("$raw") ?? 0.0;
      }

      final pDoc = await productRef.get();
      final p = pDoc.data() ?? {};
      final raw = type == "retail"
          ? p["retailPrice"]
          : type == "wholesale"
          ? p["wholesalePrice"]
          : p["costPrice"];

      if (raw is num) return raw.toDouble();
      return double.tryParse("$raw") ?? 0.0;
    } catch (_) {
      return 0.0; //default if error
    }
  }

  //excel style helpers
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

  //convert raw errors
  String _friendlyExportError(Object e) {
    if (e is FirebaseException) {
      if (e.code == "permission-denied") {
        return "You don’t have permission to export this data. Please contact an admin.";
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
      return "Couldn’t open the share menu. Please try again.";
    }

    return "Something went wrong while exporting. $msg";
  }

  //setter for export state
  void _setExportState({
    required bool exporting,
    required bool profit,
    required bool stock,
  }) {
    if (!mounted) return;
    setState(() {
      _exporting = exporting;
      _exportingProfit = profit;
      _exportingStock = stock;
    });
  }

  //profit excel export
  Future<void> _exportProfitXlsx() async {
    //validation
    final tenantId = _tenantId;
    if (_exporting || tenantId == null || tenantId.trim().isEmpty) return;

    //internet check
    final canExport = await _ensureInternetForExport();
    if (!canExport) return;

    _setExportState(exporting: true, profit: true, stock: false);

    try {
      final fs = _firestore;

      final yearStart = DateTime(_exportYear, 1, 1);
      final yearEnd = DateTime(_exportYear + 1, 1, 1);

      //order query
      Query<Map<String, dynamic>> q = _tenantOrdersRef(tenantId)
          .where("isExported", isEqualTo: true)
          .where(
        "exportedAt",
        isGreaterThanOrEqualTo: Timestamp.fromDate(yearStart),
      )
          .where("exportedAt", isLessThan: Timestamp.fromDate(yearEnd));

      if ((_exportShopId ?? "").isNotEmpty) {
        q = q.where("shopId", isEqualTo: _exportShopId);
      }

      final ordersSnap = await q.get();

      final Map<String, double> qtyByProductId = {};

      //count quantity sold per item
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

      //info toast for no data
      if (qtyByProductId.isEmpty) {
        _setExportState(exporting: false, profit: false, stock: false);
        if (mounted) {
          TopToast.info(
            context,
            "No exported sales found for $_exportShopName in $_exportYear.",
          );
        }
        return;
      }

      final productIds = qtyByProductId.keys.toList();
      final productDocs = await Future.wait(
        productIds.map((id) => _tenantProductsRef(tenantId).doc(id).get()),
      );

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

      //profit mode
      switch (_profitExportType) {
        case "storage":
          colDHeader = "Cost price";
          colEHeader = "Wholesale price";
          profitItemFormula = (row) => "=E$row-D$row";
          break;
        case "shop":
          colDHeader = "Wholesale price";
          colEHeader = "Retail price";
          profitItemFormula = (row) => "=E$row-D$row";
          break;
        case "total":
        default:
          colDHeader = "Cost price";
          colEHeader = "Retail price";
          profitItemFormula = (row) => "=E$row-D$row";
          break;
      }

      //create workbook and sheet
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
        final costUnit = await _getPrice(fs, tenantId, productId, "cost");
        final wholesaleUnit =
        await _getPrice(fs, tenantId, productId, "wholesale");
        final retailUnit = await _getPrice(fs, tenantId, productId, "retail");

        double colDValue = costUnit;
        double colEValue = retailUnit;
        double profitItem = retailUnit - costUnit;

        switch (_profitExportType) {
          case "storage":
            colDValue = costUnit;
            colEValue = wholesaleUnit;
            profitItem = colEValue - colDValue;
            break;
          case "shop":
            colDValue = wholesaleUnit;
            colEValue = retailUnit;
            profitItem = colEValue - colDValue;
            break;
          case "total":
          default:
            colDValue = costUnit;
            colEValue = retailUnit;
            profitItem = colEValue - colDValue;
            break;
        }

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

      final bytes = workbook.saveAsStream();
      workbook.dispose();

      final safeShop =
      _exportShopName.trim().isEmpty ? "All" : _exportShopName.trim();
      final safeShopFile = safeShop.replaceAll(RegExp(r'[\\/:*?"<>|]'), "_");
      final safeTypeFile = (_profitExportTypeLabels[_profitExportType] ?? "Total")
          .replaceAll(" ", "_")
          .toLowerCase();
      //filename of profit export
      final filename = "profit_${safeTypeFile}_${safeShopFile}_$_exportYear.xlsx";

      await _shareFile(
        filename: filename,
        bytes: bytes,
        shareText:
        "Profit export (${_profitExportTypeLabels[_profitExportType] ?? "Total"} • $safeShop • $_exportYear)",
      );

      _setExportState(exporting: false, profit: false, stock: false);
      if (mounted) {
        TopToast.success(context, "Profit export successful.");
      }
    } catch (e) {
      _setExportState(exporting: false, profit: false, stock: false);
      if (mounted) {
        TopToast.error(context, _friendlyExportError(e));
      }
    }
  }

  //stock excel export
  Future<void> _exportStockXlsx() async {
    final tenantId = _tenantId;
    if (_exporting || tenantId == null || tenantId.trim().isEmpty) return;

    final canExport = await _ensureInternetForExport();
    if (!canExport) return;

    _setExportState(exporting: true, profit: false, stock: true);

    try {
      final fs = _firestore;

      final yearStart = DateTime(_exportYear, 1, 1);
      final yearEnd = DateTime(_exportYear + 1, 1, 1);

      final productsSnap = await _tenantProductsRef(tenantId).get();
      final products = productsSnap.docs;

      if (products.isEmpty) {
        _setExportState(exporting: false, profit: false, stock: false);
        if (mounted) {
          TopToast.info(
            context,
            "There are no products to export yet.",
          );
        }
        return;
      }

      //preload product images
      for (final p in products) {
        final data = p.data();
        final imageUrl = (data["imageUrl"] ?? "").toString().trim();
        if (imageUrl.isNotEmpty) {
          await _downloadImageBytes(imageUrl);
        }
      }

      Query<Map<String, dynamic>> oq = _tenantOrdersRef(tenantId)
          .where("isExported", isEqualTo: true)
          .where(
        "exportedAt",
        isGreaterThanOrEqualTo: Timestamp.fromDate(yearStart),
      )
          .where("exportedAt", isLessThan: Timestamp.fromDate(yearEnd));

      if ((_exportShopId ?? "").isNotEmpty) {
        oq = oq.where("shopId", isEqualTo: _exportShopId);
      }

      final ordersSnap = await oq.get();

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

          final bool isTshirt = (x["isTshirt"] ?? false) == true;
          final sizeRaw = (x["size"] ?? "").toString().trim().toUpperCase();

          if (isTshirt && sizeRaw.isNotEmpty) {
            //key format for t-shirts
            final key = "$productId|$sizeRaw";
            soldByProductSize[key] = (soldByProductSize[key] ?? 0) + qty;
          } else {
            soldByProduct[productId] = (soldByProduct[productId] ?? 0) + qty;
          }
        }
      }

      final Map<String, double> addedByProduct = {};
      final Map<String, double> addedByProductSize = {};

      //read stock movements (add,adjust,undo)
      Future<void> readProductMovements(String productId, bool isTshirt) async {
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

          if (!isTshirt) {
            final delta = (m["delta"] is num)
                ? (m["delta"] as num).toDouble()
                : double.tryParse("${m["delta"]}") ?? 0.0;

            if (delta == 0) continue;
            addedByProduct[productId] = (addedByProduct[productId] ?? 0) + delta;
          } else {
            final sizeDeltaRaw = (m["sizeDelta"] as Map?)?.cast<String, dynamic>();
            if (sizeDeltaRaw != null && sizeDeltaRaw.isNotEmpty) {
              for (final entry in sizeDeltaRaw.entries) {
                final sz = entry.key.toString().trim().toUpperCase();
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
      }

      for (final p in products) {
        final pd = p.data();
        final isTshirt = (pd["isTshirt"] ?? false) == true;
        await readProductMovements(p.id, isTshirt);
      }

      final Map<String, double> openingByProduct = {};
      final Map<String, double> openingByProductSize = {};

      //get opening stock
      Future<void> readOpening(String productId, bool isTshirt) async {
        final yDoc = await _firestore
            .collection("tenants")
            .doc(tenantId)
            .collection("products")
            .doc(productId)
            .collection("stock_years")
            .doc(_exportYear.toString())
            .get();

        if (!yDoc.exists) {
          openingByProduct[productId] = 0;
          return;
        }

        final y = yDoc.data() ?? {};
        final init = (y["initialStock"] is num)
            ? (y["initialStock"] as num).toDouble()
            : double.tryParse("${y["initialStock"]}") ?? 0.0;

        openingByProduct[productId] = init;

        if (isTshirt) {
          final initSizeRaw =
          (y["initialSizeStock"] as Map?)?.cast<String, dynamic>();
          if (initSizeRaw != null && initSizeRaw.isNotEmpty) {
            for (final entry in initSizeRaw.entries) {
              final sz = entry.key.toString().trim().toUpperCase();
              final v = entry.value;
              final d =
              (v is num) ? v.toDouble() : double.tryParse("$v") ?? 0.0;
              final key = "$productId|$sz";
              openingByProductSize[key] = d;
            }
          }
        }
      }

      for (final p in products) {
        final pd = p.data();
        final isTshirt = (pd["isTshirt"] ?? false) == true;
        await readOpening(p.id, isTshirt);
      }

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

      for (final p in products) {
        final pd = p.data();
        final productId = p.id;
        final code = (pd["code"] ?? productId).toString().trim();
        final isTshirt = (pd["isTshirt"] ?? false) == true;
        final imageUrl = (pd["imageUrl"] ?? "").toString().trim();

        final cost = await _getPrice(fs, tenantId, productId, "cost");
        final wholesale = await _getPrice(fs, tenantId, productId, "wholesale");

        if (!isTshirt) {
          final opening = openingByProduct[productId] ?? 0;
          final added = addedByProduct[productId] ?? 0;
          final sold = soldByProduct[productId] ?? 0;
          final closing = opening + added - sold;

          rows.add({
            "isTshirt": false,
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
          });
        } else {
          for (final sz in _sizes) {
            final key = "$productId|$sz";

            final openingSz = openingByProductSize[key] ?? 0.0;
            final addedSz = addedByProductSize[key] ?? 0.0;
            final soldSz = soldByProductSize[key] ?? 0.0;
            final closingSz = openingSz + addedSz - soldSz;

            rows.add({
              "isTshirt": true,
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
            });
          }
        }
      }

      //sort with code
      rows.sort((a, b) => (a["code"] as String).compareTo(b["code"] as String));

      int row = 2;
      int i = 0;
      final productEndRows = <int>[];

      while (i < rows.length) {
        final r = rows[i];
        final bool isTshirt = r["isTshirt"] == true;

        if (!isTshirt) {
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

        //tshirt block
        final productId = (r["productId"] ?? "").toString();
        final startRow = row;

        final block = <Map<String, dynamic>>[];
        while (i < rows.length) {
          final rr = rows[i];
          if (rr["isTshirt"] != true) break;
          if ((rr["productId"] ?? "").toString() != productId) break;
          block.add(rr);
          i++;
        }

        final endRow = startRow + block.length - 1;

        for (int rr = startRow; rr <= endRow; rr++) {
          sheet.getRangeByIndex(rr, 1).rowHeight = _tshirtRowH;
        }

        final imgRange = sheet.getRangeByIndex(startRow, 1, endRow, 1)..merge();
        final codeRange = sheet.getRangeByIndex(startRow, 2, endRow, 2)..merge();
        final costRange = sheet.getRangeByIndex(startRow, 8, endRow, 8)..merge();
        final whRange = sheet.getRangeByIndex(startRow, 9, endRow, 9)..merge();
        final totalCostRange =
        sheet.getRangeByIndex(startRow, 10, endRow, 10)..merge();
        final totalWhRange =
        sheet.getRangeByIndex(startRow, 11, endRow, 11)..merge();

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

      final bytes = workbook.saveAsStream();
      workbook.dispose();

      final safeShop =
      _exportShopName.trim().isEmpty ? "All" : _exportShopName.trim();
      final safeShopFile = safeShop.replaceAll(RegExp(r'[\\/:*?"<>|]'), "_");
      final filename = "stock_${safeShopFile}_$_exportYear.xlsx";

      await _shareFile(
        filename: filename,
        bytes: bytes,
        shareText: "Stock export ($safeShop • $_exportYear)",
      );

      _setExportState(exporting: false, profit: false, stock: false);
      if (mounted) {
        TopToast.success(context, "Stock export successful.");
      }
    } catch (e) {
      _setExportState(exporting: false, profit: false, stock: false);
      if (mounted) {
        TopToast.error(context, _friendlyExportError(e));
      }
    }
  }

  //dashboard widget for month and year picker - used for insights
  Widget _dashMonthYearPicker() {
    final years = List.generate(8, (i) => DateTime.now().year - 5 + i);

    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<int>(
            value: _dashMonth,
            decoration: const InputDecoration(
              labelText: "Month",
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: List.generate(12, (i) {
              final m = i + 1;
              return DropdownMenuItem(value: m, child: Text(_monthNames[i]));
            }),
            onChanged: (v) => setState(() => _dashMonth = v ?? _dashMonth),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<int>(
            value: _dashYear,
            decoration: const InputDecoration(
              labelText: "Year",
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: years
                .map(
                  (y) => DropdownMenuItem(
                value: y,
                child: Text(y.toString()),
              ),
            )
                .toList(),
            onChanged: (v) => setState(() => _dashYear = v ?? _dashYear),
          ),
        ),
      ],
    );
  }

  //export widget for shop,year,profit picker
  Widget _exportsShopYearPicker() {
    final nowYear = DateTime.now().year;
    final years = List.generate(6, (i) => nowYear - 5 + i);

    final shopItems = <DropdownMenuItem<String?>>[
      const DropdownMenuItem<String?>(
        value: null,
        child: Text("All"),
      ),
      ..._shops.map((d) {
        final name = (d.data()["name"] ?? d.id).toString();
        return DropdownMenuItem<String?>(
          value: d.id,
          child: Text(name),
        );
      }),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String?>(
          value: _exportShopId,
          decoration: const InputDecoration(
            labelText: "Shop",
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: shopItems,
          onChanged: (v) {
            if (v == null) {
              setState(() {
                _exportShopId = null;
                _exportShopName = "All";
              });
              return;
            }

            final match = _shops.where((s) => s.id == v).toList();
            final name = match.isEmpty
                ? ""
                : (match.first.data()["name"] ?? "").toString().trim();

            setState(() {
              _exportShopId = v;
              _exportShopName = name.isEmpty ? "All" : name;
            });
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          value: _exportYear,
          decoration: const InputDecoration(
            labelText: "Export Year",
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: years
              .map(
                (y) => DropdownMenuItem(
              value: y,
              child: Text(y.toString()),
            ),
          )
              .toList(),
          onChanged: (v) => setState(() => _exportYear = v ?? _exportYear),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _profitExportType,
          decoration: const InputDecoration(
            labelText: "Profit",
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: _profitExportTypeLabels.entries
              .map(
                (e) => DropdownMenuItem<String>(
              value: e.key,
              child: Text(e.value),
            ),
          )
              .toList(),
          onChanged: (v) {
            if (v == null) return;
            setState(() => _profitExportType = v);
          },
        ),
      ],
    );
  }

  //UI helper used for exports, movement history and insights
  Widget _sectionCard({
    required String title,
    required Widget child,
    List<Widget>? actions,
  }) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (actions != null) ...actions,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Future<Map<String, String>> _fetchUserNames(Set<String> uids) async {
    final Map<String, String> out = {};

    for (final uid in uids) {
      if (_userNameCache.containsKey(uid)) {
        out[uid] = _userNameCache[uid]!;
        continue;
      }

      try {
        final cacheDoc = await _firestore
            .collection("users")
            .doc(uid)
            .get(const GetOptions(source: Source.cache))
            .timeout(const Duration(milliseconds: 400));

        final cacheData = cacheDoc.data() ?? {};
        final cacheName = (cacheData["name"] ?? "").toString().trim();
        if (cacheName.isNotEmpty) {
          _userNameCache[uid] = cacheName;
          out[uid] = cacheName;
          continue;
        }
      } catch (_) {}

      try {
        final doc = await _firestore
            .collection("users")
            .doc(uid)
            .get()
            .timeout(const Duration(milliseconds: 1200));
        final data = doc.data() ?? {};
        final name = (data["name"] ?? "").toString().trim();
        final resolved = name.isEmpty ? uid : name;
        _userNameCache[uid] = resolved;
        out[uid] = resolved;
      } catch (_) {
        _userNameCache[uid] = uid;
        out[uid] = uid;
      }
    }

    return out;
  }

  //widget for movement history preview
  Widget _movementHistoryPreview() {
    final tenantId = _tenantId;
    if (tenantId == null || tenantId.trim().isEmpty) {
      return const Text("No tenant loaded.");
    }

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _tenantMovementHistoryRef(tenantId)
          .orderBy("movedAt", descending: true)
          .limit(2)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return const Text("Could not load movement history right now.");
        }

        if (!snap.hasData) {
          return const SizedBox(
            height: 80,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text("Loading movement history..."),
            ),
          );
        }

        final docs = snap.data!.docs;
        if (docs.isEmpty) return const Text("No movement records yet.");

        final needUids = <String>{};
        for (final d in docs) {
          final data = d.data();
          final movedBy = (data["movedBy"] ?? "").toString();
          final movedByName = (data["movedByName"] ?? "").toString().trim();
          if (movedBy.isNotEmpty && movedByName.isEmpty) {
            needUids.add(movedBy);
          }
        }

        if (needUids.isEmpty) {
          return Column(
            children: docs.map((d) {
              final data = d.data();
              final type = (data["type"] ?? "").toString();
              final titleName = (data["name"] ?? "").toString().trim();
              final movedByNameStored =
              (data["movedByName"] ?? "").toString().trim();
              final movedAt = data["movedAt"] as Timestamp?;

              final oldLine = (type == "product")
                  ? _foldersOnlyFromPath(data["oldPathNames"])
                  : _formatPathNames(data["oldPathNames"]);

              final newLine = (type == "product")
                  ? _foldersOnlyFromPath(data["newPathNames"])
                  : _formatPathNames(data["newPathNames"]);

              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading:
                Icon(type == "folder" ? Icons.folder : Icons.inventory_2),
                title: Text(titleName.isEmpty ? "(unnamed)" : titleName),
                subtitle: Text(
                  "$oldLine\n→ $newLine"
                      "${movedByNameStored.isEmpty ? "" : "\nby $movedByNameStored"}"
                      "${movedAt == null ? "" : "\n${_formatTime(movedAt)}"}",
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }).toList(),
          );
        }

        //listen to live updates
        return FutureBuilder<Map<String, String>>(
          future: _fetchUserNames(needUids),
          builder: (context, namesSnap) {
            if (namesSnap.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 80,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text("Loading movement history..."),
                ),
              );
            }

            final nameMap = namesSnap.data ?? {};

            return Column(
              children: docs.map((d) {
                final data = d.data();
                final type = (data["type"] ?? "").toString();
                final titleName = (data["name"] ?? "").toString().trim();

                final movedByUid = (data["movedBy"] ?? "").toString();
                final movedByNameStored =
                (data["movedByName"] ?? "").toString().trim();
                final movedByName = movedByNameStored.isNotEmpty
                    ? movedByNameStored
                    : (nameMap[movedByUid] ?? movedByUid);

                final movedAt = data["movedAt"] as Timestamp?;

                final oldLine = (type == "product")
                    ? _foldersOnlyFromPath(data["oldPathNames"])
                    : _formatPathNames(data["oldPathNames"]);

                final newLine = (type == "product")
                    ? _foldersOnlyFromPath(data["newPathNames"])
                    : _formatPathNames(data["newPathNames"]);

                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading:
                  Icon(type == "folder" ? Icons.folder : Icons.inventory_2),
                  title: Text(titleName.isEmpty ? "(unnamed)" : titleName),
                  subtitle: Text(
                    "$oldLine\n→ $newLine"
                        "${movedByName.isEmpty ? "" : "\nby $movedByName"}"
                        "${movedAt == null ? "" : "\n${_formatTime(movedAt)}"}",
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
            );
          },
        );
      },
    );
  }

  //insight widget
  Widget _insights() {
    final tenantId = _tenantId;
    if (tenantId == null || tenantId.trim().isEmpty) {
      return const Text("No tenant loaded.");
    }

    //error, loading, no data states
    return FutureBuilder<Map<String, dynamic>>(
      future: _computeInsights(tenantId),
      builder: (context, snap) {
        if (snap.hasError) {
          return const Text("Could not load insights right now.");
        }

        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 80,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text("Loading insights..."),
            ),
          );
        }

        if (!snap.hasData) return const Text("No data.");

        //result data
        final data = snap.data!;
        final fast = (data["fastMovingTop10"] as List?) ?? [];
        final top5 = (data["top5"] as List?) ?? [];
        final trend = (data["trend"] as List?) ?? [];
        final orderCount = data["orderCount"] ?? 0;

        Widget listBlock(String label, List items, int max) {
          if (items.isEmpty) return Text("$label: No sales in this month.");

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              ...items.take(max).map((x) {
                final m = (x as Map).cast<String, dynamic>();
                final code = (m["code"] ?? "").toString();
                final key = (m["productId"] ?? m["key"] ?? "").toString();
                final qty = m["qty"] ?? 0;
                final folderPath = _formatPathNames(m["folderPathNames"]);
                final labelName = code.isNotEmpty ? code : key;
                final orderCount = m["orderCount"] ?? 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    label.contains("Fast-Moving")
                        ? "• $labelName — in $orderCount orders, $qty sold  ($folderPath)"
                        : "• $labelName — $qty sold, in $orderCount orders  ($folderPath)",
                  ),
                );
              }),
            ],
          );
        }

        Widget trendBlock() {
          if (trend.isEmpty) return const Text("Trend: No data.");

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Monthly Sales Trend (Revenue)",
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              ...trend.map((t) {
                final m = (t as Map).cast<String, dynamic>();
                final label = (m["label"] ?? "").toString();
                final revenue =
                (m["revenue"] is num) ? (m["revenue"] as num).toDouble() : 0.0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text("• $label — €${revenue.toStringAsFixed(2)}"),
                );
              }),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Orders in month: $orderCount"),
            const SizedBox(height: 10),
            listBlock("Fast-Moving Products (Top 10)", fast, 10),
            const SizedBox(height: 12),
            listBlock("Top 5 Best Sellers", top5, 5),
            const SizedBox(height: 12),
            trendBlock(),
          ],
        );
      },
    );
  }

  //app bar
  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xff0B1E40),
      centerTitle: false,
      titleSpacing: 16,
      automaticallyImplyLeading: false,
      leadingWidth: 0,
      title: const Text("Home", style: TextStyle(color: Colors.white)),
    );
  }

  //center state widget for special cases
  Widget _buildCenteredState({
    required IconData icon,
    required String title,
    required String message,
    String? buttonText,
    VoidCallback? onPressed,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
            ),
            if (buttonText != null && onPressed != null) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.folder),
                label: Text(buttonText),
                onPressed: onPressed,
              ),
            ],
          ],
        ),
      ),
    );
  }

  //decide what screen body show
  Widget _buildHomeBody() {
    //tenant loading
    if (_loadingTenant) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    //no tenant
    if (_tenantId == null || _tenantId!.trim().isEmpty) {
      return _buildCenteredState(
        icon: Icons.cloud_off,
        title: "Unable to load Home",
        message: "The dashboard could not load tenant information right now.",
        buttonText: "Go to Files",
        onPressed: () {
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => const FilesScreen(),
            ),
          );
        },
      );
    }

    //not admin
    if (!_isAdmin) {
      return _buildCenteredState(
        icon: Icons.lock,
        title: "Admins only",
        message: "You don’t have permission to access the Home dashboard.",
        buttonText: "Go to Files",
        onPressed: () {
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => const FilesScreen(),
            ),
          );
        },
      );
    }

    //valid admin dashboard
    return ListView(
      padding: const EdgeInsets.only(bottom: 90),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: _dashMonthYearPicker(),
        ),
        _sectionCard(
          title: "Exports",
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.share),
              label: Text(_exportingProfit ? "Exporting..." : "Profit"),
              onPressed: _exporting ? null : _exportProfitXlsx,
            ),
            const SizedBox(width: 6),
            TextButton.icon(
              icon: const Icon(Icons.inventory_2),
              label: Text(_exportingStock ? "Exporting..." : "Stock"),
              onPressed: _exporting ? null : _exportStockXlsx,
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _exportsShopYearPicker(),
              const SizedBox(height: 12),
            ],
          ),
        ),
        _sectionCard(
          title: "Movement History",
          actions: [
            TextButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const MovementHistoryScreen(),
                  ),
                );
              },
              child: const Text("See all"),
            ),
          ],
          child: _movementHistoryPreview(),
        ),
        _sectionCard(
          title: "Insights",
          child: _insights(),
        ),
      ],
    );
  }
  //final screen structure
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, //prevent back navigation
      child: Scaffold(
        appBar: _buildAppBar(),
        bottomNavigationBar: const BottomNav(
          currentIndex: 0,
          hasFab: false,
          isRootScreen: true,
        ),
        body: _buildHomeBody(),
      ),
    );
  }
}