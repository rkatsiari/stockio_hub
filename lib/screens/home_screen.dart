//home dashboard screen
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/app_navigation.dart';
import '../services/export_service.dart';
import '../services/tenant_context_service.dart';
import '../utils/price_util.dart';
import '../widgets/bottom_nav.dart';
import 'files_screen.dart';
import 'movement_history_screen.dart';

//widget declaration
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

//RouteAware lets this screen tell ExportService when it's actually the
//visible/topmost screen vs. when it's covered by a pushed screen (e.g.
//Movement History), so the export share sheet only pops up when the user
//can actually see it.
class _HomeScreenState extends State<HomeScreen> with RouteAware {
  static final Map<String, Map<String, dynamic>> _insightsMemoryCache =
  <String, Map<String, dynamic>>{};

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

  //export options (selection state only - the export itself runs inside
  //ExportService, which lives for the lifetime of the app rather than this
  //screen, so navigating away no longer cancels it)
  int _exportYear = DateTime.now().year;

  String? _exportShopId;
  String _exportShopName = "All";
  String _profitExportType = "total";

  //maps internal export type values to text
  static const Map<String, String> _profitExportTypeLabels =
      ExportService.profitExportTypeLabels;

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _shops = [];

  //keeps insights from reloading when only export progress changes
  String? _insightsFutureKey;
  Future<Map<String, dynamic>>? _insightsFuture;
  Map<String, dynamic>? _lastInsightsData;

  //tracks when the current insights future was kicked off, so a cached
  //result for the same tenant/month can expire and refresh instead of
  //staying stale for the lifetime of the screen
  DateTime? _insightsFutureStartedAt;
  static const Duration _insightsCacheTtl = Duration(minutes: 2);

  //loading flags
  bool _loadingTenant = true;
  bool _isAdmin = false;

  String? _tenantId;
  StreamSubscription<User?>? _authSub;
  int _authLoadToken = 0;

  //cashes
  final Map<String, String> _userNameCache = {};

  @override
  void initState() {
    super.initState();
    _listenToAuth();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      AppNavigation.routeObserver.subscribe(this, route);
    }

    //Home is on top right now (first build, or navigated back to) - if an
    //export finished while we were elsewhere, this opens its share sheet.
    ExportService.instance.setHomeVisible(true);
  }

  @override
  void dispose() {
    AppNavigation.routeObserver.unsubscribe(this);
    ExportService.instance.setHomeVisible(false);
    _authSub?.cancel();
    super.dispose(); //avoid memory leaks
  }

  @override
  void didPushNext() {
    //another screen (e.g. Movement History) was pushed on top of Home -
    //Home is still mounted underneath but no longer visible.
    ExportService.instance.setHomeVisible(false);
  }

  @override
  void didPopNext() {
    //the screen that was covering Home was popped - Home is visible again.
    ExportService.instance.setHomeVisible(true);
  }

  //firestore helper methods to access tenant collections
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
          _insightsFutureKey = null;
          _insightsFuture = null;
          _insightsFutureStartedAt = null;
          _lastInsightsData = null;
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
        _insightsFutureKey = null;
        _insightsFuture = null;
        _insightsFutureStartedAt = null;
        _lastInsightsData = null;
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
          await PriceUtil.getPrice(_firestore, tenantId, productId, "retail");
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

  //export progress card - now a pure function of ExportService's state, so
  //it renders correctly whether this screen started the export or not.
  Widget _exportProgressIndicator(ExportJobState state) {
    if (!state.isExporting) return const SizedBox.shrink();

    final title = state.isProfit
        ? "Preparing profit export"
        : state.isStock
        ? "Preparing stock export"
        : "Preparing export";

    final progress = state.progress.clamp(0.0, 1.0);
    final percent = (progress * 100).round().clamp(0, 100);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xffF3F6FB),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                "$percent%",
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: progress),
          if (state.progressText.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              state.progressText,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ],
      ),
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

  Future<Map<String, dynamic>> _getInsightsFuture(String tenantId) {
    final key = "$tenantId|$_dashYear|$_dashMonth";

    final isStale = _insightsFutureStartedAt == null ||
        DateTime.now().difference(_insightsFutureStartedAt!) >
            _insightsCacheTtl;

    if (_insightsFutureKey != key || _insightsFuture == null || isStale) {
      _insightsFutureKey = key;
      _insightsFutureStartedAt = DateTime.now();

      final cached = _insightsMemoryCache[key];
      if (cached != null) {
        _lastInsightsData = cached;
      }

      _insightsFuture = _computeInsights(tenantId).then((data) {
        _insightsMemoryCache[key] = data;
        _lastInsightsData = data;
        return data;
      });
    }

    return _insightsFuture!;
  }

  Widget _buildInsightsContent(Map<String, dynamic> data) {
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
  }

  //insight widget
  Widget _insights() {
    final tenantId = _tenantId;
    if (tenantId == null || tenantId.trim().isEmpty) {
      return const Text("No tenant loaded.");
    }

    final future = _getInsightsFuture(tenantId);
    final initialInsightsData = _lastInsightsData;

    return FutureBuilder<Map<String, dynamic>>(
      future: future,
      initialData: initialInsightsData,
      builder: (context, snap) {
        if (snap.hasData) {
          return _buildInsightsContent(snap.data!);
        }

        if (snap.hasError) {
          return const Text("Could not load insights right now.");
        }

        return const SizedBox(
          height: 80,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text("Loading insights..."),
          ),
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

  //triggers the profit export via ExportService using the currently
  //selected shop/year/profit-type. Safe to call from anywhere - the
  //service itself guards against double-starts.
  void _startProfitExport() {
    final tenantId = _tenantId;
    if (tenantId == null || tenantId.trim().isEmpty) return;

    ExportService.instance.exportProfitXlsx(
      tenantId: tenantId,
      year: _exportYear,
      shopId: _exportShopId,
      shopName: _exportShopName,
      profitType: _profitExportType,
    );
  }

  //triggers the stock export via ExportService using the currently
  //selected shop/year.
  void _startStockExport() {
    final tenantId = _tenantId;
    if (tenantId == null || tenantId.trim().isEmpty) return;

    ExportService.instance.exportStockXlsx(
      tenantId: tenantId,
      year: _exportYear,
      shopId: _exportShopId,
      shopName: _exportShopName,
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
          title: "Insights",
          child: _insights(),
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
        //Exports section is wired to ExportService.instance.stateNotifier,
        //not local screen state, so the buttons/progress reflect reality
        //even if an export was started, or is still running, from a
        //previous visit to this screen.
        ValueListenableBuilder<ExportJobState>(
          valueListenable: ExportService.instance.stateNotifier,
          builder: (context, exportState, _) {
            return _sectionCard(
              title: "Exports",
              actions: [
                TextButton.icon(
                  icon: const Icon(Icons.share),
                  label: Text(
                    exportState.isExporting && exportState.isProfit
                        ? "Exporting..."
                        : "Profit",
                  ),
                  onPressed: exportState.isExporting ? null : _startProfitExport,
                ),
                const SizedBox(width: 6),
                TextButton.icon(
                  icon: const Icon(Icons.inventory_2),
                  label: Text(
                    exportState.isExporting && exportState.isStock
                        ? "Exporting..."
                        : "Stock",
                  ),
                  onPressed: exportState.isExporting ? null : _startStockExport,
                ),
              ],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _exportsShopYearPicker(),
                  const SizedBox(height: 12),
                  _exportProgressIndicator(exportState),
                ],
              ),
            );
          },
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