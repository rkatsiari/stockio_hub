import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../services/tenant_context_service.dart';

class StockHistoryScreen extends StatefulWidget {
  final String productId;

  const StockHistoryScreen({
    super.key,
    required this.productId,
  });

  @override
  State<StockHistoryScreen> createState() => _StockHistoryScreenState();
}

class _StockHistoryScreenState extends State<StockHistoryScreen> {
  static const List<String> _sizes = [
    "XXS", "XS", "S", "M",
    "L", "XL", "2XL", "3XL",
  ];

  final TenantContextService _tenantContextService = TenantContextService();

  String _filter = "all";
  Future<String>? _tenantIdFuture;

  @override
  void initState() {
    super.initState();
    _tenantIdFuture = _tenantContextService.getTenantId();
  }

  String _normalizeType(dynamic v) {
    final t = (v ?? "").toString().trim().toLowerCase();
    if (t == "undo sale") return "undo_sale";
    return t;
  }

  bool _matchesFilter(Map<String, dynamic> m) {
    if (_filter == "all") return true;
    final type = _normalizeType(m["type"]);
    return type == _filter;
  }

  String _firstText(Map<String, dynamic> m, List<String> keys) {
    for (final key in keys) {
      final value = (m[key] ?? "").toString().trim();
      if (value.isNotEmpty) return value;
    }
    return "";
  }

  Future<Map<String, String>> _movementDisplayFallback({
    required String tenantId,
    required Map<String, dynamic> movement,
  }) async {
    String byName = _firstText(movement, [
      "byName",
      "userName",
      "createdByName",
      "adjustedByName",
      "addedByName",
      "undoByName",
      "exportedByName",
    ]);

    String shopName = _firstText(movement, [
      "shopName",
      "orderShopName",
      "soldShopName",
      "undoShopName",
      "shop",
    ]);

    final orderId = (movement["orderId"] ?? "").toString().trim();
    if (shopName.isEmpty && orderId.isNotEmpty) {
      try {
        final orderSnap = await FirebaseFirestore.instance
            .collection("tenants")
            .doc(tenantId)
            .collection("orders")
            .doc(orderId)
            .get();

        final orderData = orderSnap.data() ?? <String, dynamic>{};
        shopName = _firstText(orderData, [
          "shopName",
          "orderShopName",
          "soldShopName",
          "undoShopName",
          "shop",
          "name",
        ]);
      } catch (_) {}
    }

    final uid = (movement["by"] ??
        movement["userId"] ??
        movement["createdBy"] ??
        movement["adjustedBy"] ??
        movement["addedBy"] ??
        movement["undoBy"] ??
        movement["exportedBy"])
        .toString()
        .trim();

    if (byName.isEmpty && uid.isNotEmpty) {
      try {
        final userSnap = await FirebaseFirestore.instance
            .collection("users")
            .doc(uid)
            .get();

        final userData = userSnap.data() ?? <String, dynamic>{};
        byName = _firstText(userData, [
          "name",
          "fullName",
          "displayName",
          "userName",
          "email",
        ]);
      } catch (_) {}
    }

    return {
      "byName": byName,
      "shopName": shopName,
    };
  }

  Widget _filterBar() {
    ChoiceChip chip(String label, String value) {
      return ChoiceChip(
        label: Text(label),
        selected: _filter == value,
        onSelected: (_) {
          if (!mounted) return;
          setState(() => _filter = value);
        },
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          chip("All", "all"),
          const SizedBox(width: 8),
          chip("Added", "add"),
          const SizedBox(width: 8),
          chip("Adjusted", "adjust"),
          const SizedBox(width: 8),
          chip("Sold", "sale"),
          const SizedBox(width: 8),
          chip("Undo", "undo_sale"),
        ],
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xff0B1E40),
      title: const Text(
        "Stock History",
        style: TextStyle(color: Colors.white),
      ),
      iconTheme: const IconThemeData(color: Colors.white),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          alignment: Alignment.centerLeft,
          child: _filterBar(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _tenantIdFuture,
      builder: (context, tenantSnap) {
        if (tenantSnap.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: _buildAppBar(),
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        if (tenantSnap.hasError || !tenantSnap.hasData) {
          return Scaffold(
            appBar: _buildAppBar(),
            body: const Center(
              child: Text("Unable to load stock history."),
            ),
          );
        }

        final tenantId = tenantSnap.data!.trim();
        if (tenantId.isEmpty) {
          return Scaffold(
            appBar: _buildAppBar(),
            body: const Center(
              child: Text("Unable to resolve tenant."),
            ),
          );
        }

        final docRef = FirebaseFirestore.instance
            .collection("tenants")
            .doc(tenantId)
            .collection("products")
            .doc(widget.productId);

        final stockMovesCol = docRef.collection("stock_movements");

        return Scaffold(
          appBar: _buildAppBar(),
          body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: stockMovesCol.orderBy("at", descending: true).snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting &&
                  !snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snap.hasError) {
                return const Center(
                  child: Text("Failed to load stock history."),
                );
              }

              final allDocs = snap.data?.docs ?? const [];

              final docs = allDocs.where((d) {
                final m = d.data();
                return _matchesFilter(m);
              }).toList();

              if (docs.isEmpty) {
                return const Center(
                  child: Text("No movements for this filter."),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _movementTile(docs[i], tenantId),
              );
            },
          ),
        );
      },
    );
  }

  Widget _movementTile(
      QueryDocumentSnapshot<Map<String, dynamic>> doc,
      String tenantId,
      ) {
    final m = doc.data();
    final type = _normalizeType(m["type"]);
    final note = (m["note"] ?? "").toString().trim();
    final byName = _firstText(m, [
      "byName",
      "userName",
      "createdByName",
      "adjustedByName",
      "addedByName",
      "undoByName",
      "exportedByName",
    ]);

    final shopName = _firstText(m, [
      "shopName",
      "orderShopName",
      "soldShopName",
      "undoShopName",
      "shop",
    ]);

    final deltaRaw = m["delta"];
    final delta =
    (deltaRaw is num) ? deltaRaw.toInt() : int.tryParse("$deltaRaw") ?? 0;

    final Map<String, dynamic> sizeDeltaRaw =
        (m["sizeDelta"] as Map?)?.cast<String, dynamic>() ?? {};

    final Map<String, int> sizeDelta = {
      for (final s in _sizes)
        if (sizeDeltaRaw.containsKey(s))
          s: (sizeDeltaRaw[s] is int)
              ? sizeDeltaRaw[s] as int
              : int.tryParse("${sizeDeltaRaw[s]}") ?? 0,
    };

    final nonZero = <String>[];
    for (final s in _sizes) {
      final v = sizeDelta[s] ?? 0;
      if (v != 0) {
        nonZero.add("$s:${v >= 0 ? "+" : ""}$v");
      }
    }
    final sizesLine = nonZero.join("  ");

    DateTime? dt;
    final ts = m["at"];
    if (ts is Timestamp) {
      dt = ts.toDate();
    }

    final when = dt == null
        ? "—"
        : "${dt.year.toString().padLeft(4, '0')}-"
        "${dt.month.toString().padLeft(2, '0')}-"
        "${dt.day.toString().padLeft(2, '0')} "
        "${dt.hour.toString().padLeft(2, '0')}:"
        "${dt.minute.toString().padLeft(2, '0')}";

    String title;
    IconData icon;

    if (type == "add") {
      title = "Stock Added";
      icon = Icons.add_circle_outline;
    } else if (type == "sale") {
      title = "Sold";
      icon = Icons.shopping_bag_outlined;
    } else if (type == "adjust") {
      title = "Adjusted";
      icon = Icons.tune;
    } else if (type == "undo_sale") {
      title = "Undo sale";
      icon = Icons.undo;
    } else {
      title = type.isEmpty ? "Movement" : type;
      icon = Icons.swap_vert;
    }

    final sign = delta >= 0 ? "+" : "";

    Widget buildTile({
      required String resolvedByName,
      required String resolvedShopName,
    }) {
      final details = <String>[when];

      if ((type == "add" || type == "adjust") &&
          resolvedByName.isNotEmpty) {
        details.add(resolvedByName);
      }

      if (type == "sale" && resolvedShopName.isNotEmpty) {
        details.add(resolvedShopName);
      }

      if (type == "undo_sale") {
        if (resolvedShopName.isNotEmpty) details.add(resolvedShopName);
        if (resolvedByName.isNotEmpty) details.add(resolvedByName);
      }

      final detailsLine = details.join(" • ");

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey.shade200),
          color: Colors.white,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: Colors.grey.shade700),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detailsLine,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  if (sizesLine.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      sizesLine,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.grey.shade800,
                      ),
                    ),
                  ],
                  if (note.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      note,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade800,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              "$sign$delta",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: delta >= 0 ? Colors.green : Colors.red,
              ),
            ),
          ],
        ),
      );
    }

    final needsByName =
        (type == "add" || type == "adjust" || type == "undo_sale") &&
            byName.isEmpty;
    final needsShopName =
        (type == "sale" || type == "undo_sale") && shopName.isEmpty;

    if (!needsByName && !needsShopName) {
      return buildTile(
        resolvedByName: byName,
        resolvedShopName: shopName,
      );
    }

    return FutureBuilder<Map<String, String>>(
      future: _movementDisplayFallback(tenantId: tenantId, movement: m),
      builder: (context, snap) {
        final fallback = snap.data ?? const <String, String>{};
        return buildTile(
          resolvedByName: byName.isNotEmpty
              ? byName
              : (fallback["byName"] ?? ""),
          resolvedShopName: shopName.isNotEmpty
              ? shopName
              : (fallback["shopName"] ?? ""),
        );
      },
    );
  }
}