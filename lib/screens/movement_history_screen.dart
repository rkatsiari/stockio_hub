//show movement history
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/tenant_context_service.dart';

class MovementHistoryScreen extends StatefulWidget {
  const MovementHistoryScreen({super.key});

  @override
  State<MovementHistoryScreen> createState() => _MovementHistoryScreenState();
}

class _MovementHistoryScreenState extends State<MovementHistoryScreen> {
  late final Future<String> _tenantIdFuture;

  final FirebaseAuth _auth = FirebaseAuth.instance;
  StreamSubscription<User?>? _authSub;

  final Map<String, String> _userNameCache = <String, String>{};
  final Set<String> _uidsBeingFetched = <String>{};

  bool _handledSignedOut = false;

  @override
  void initState() {
    super.initState();
    _tenantIdFuture = TenantContextService().getTenantIdOrThrow();
    _listenToAuthChanges();
  }

  void _listenToAuthChanges() {
    _authSub = _auth.authStateChanges().listen((user) {
      if (!mounted || _handledSignedOut) return;

      if (user == null) {
        _handledSignedOut = true;
        _unfocusSafely();

        final navigator = Navigator.maybeOf(context);

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (navigator != null && navigator.canPop()) {
            navigator.pop();
          }
        });
      }
    });
  }

  void _unfocusSafely() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  bool _canUseContext() => mounted && !_handledSignedOut;

  Future<void> _safePop() async {
    if (!_canUseContext()) return;

    final navigator = Navigator.maybeOf(context);
    if (navigator == null) return;

    _unfocusSafely();
    await Future<void>.delayed(Duration.zero);

    if (!mounted || _handledSignedOut) return;

    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  String _cleanErr(Object e) =>
      e.toString().replaceFirst("Exception: ", "").trim();

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  //convert dynamic value to string list
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

  //convert firestore timestamp into readable string
  String _formatTime(Timestamp? ts) {
    if (ts == null) return "";
    final d = ts.toDate();
    return "${d.year}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")} "
        "${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}";
  }

  Future<void> _ensureNamesLoaded(String tenantId, Set<String> uids) async {
    final missing = uids
        .where(
          (uid) =>
      uid.trim().isNotEmpty &&
          !_userNameCache.containsKey(uid) &&
          !_uidsBeingFetched.contains(uid),
    )
        .toList();

    if (missing.isEmpty) return;

    _uidsBeingFetched.addAll(missing);

    final fs = FirebaseFirestore.instance;
    bool changed = false;

    try {
      for (final uid in missing) {
        try {
          final doc = await fs
              .collection("tenants")
              .doc(tenantId)
              .collection("users")
              .doc(uid)
              .get();

          final data = doc.data() ?? <String, dynamic>{};
          final name = (data["name"] ?? "").toString().trim();

          _userNameCache[uid] = name.isEmpty ? uid : name;
          changed = true;
        } catch (_) {
          _userNameCache[uid] = uid;
          changed = true;
        } finally {
          _uidsBeingFetched.remove(uid);
        }
      }
    } catch (_) {
      for (final uid in missing) {
        _uidsBeingFetched.remove(uid);
        _userNameCache.putIfAbsent(uid, () => uid);
      }
      changed = true;
    }

    if (changed && mounted && !_handledSignedOut) {
      setState(() {});
    }
  }

  String _resolveMovedByName(Map<String, dynamic> data) {
    final movedByUid = (data["movedBy"] ?? "").toString().trim();
    final movedByNameStored = (data["movedByName"] ?? "").toString().trim();

    if (movedByNameStored.isNotEmpty) return movedByNameStored;
    if (movedByUid.isEmpty) return "";
    return _userNameCache[movedByUid] ?? movedByUid;
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xff0B1E40),
      title: const Text(
        "Movement History",
        style: TextStyle(color: Colors.white),
      ),
      iconTheme: const IconThemeData(color: Colors.white),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: _safePop,
      ),
    );
  }

  Widget _buildTenantError(Object? error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          error != null ? _cleanErr(error) : "Failed to load tenant.",
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  //builds the main scrolling list of movement history records
  Widget _buildHistoryList(
      String tenantId,
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
      ) {
    //scans all movement documents and collects UIDs
    final needUids = <String>{};
    for (final d in docs) {
      final m = d.data();
      final movedBy = (m["movedBy"] ?? "").toString().trim();
      final movedByName = (m["movedByName"] ?? "").toString().trim();
      if (movedBy.isNotEmpty && movedByName.isEmpty) {
        needUids.add(movedBy);
      }
    }

    //fetches missing usernames after the frame is drawn
    if (needUids.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _handledSignedOut) return;
        _ensureNamesLoaded(tenantId, needUids);
      });
    }

    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: docs.length,
      separatorBuilder: (_, __) => const Divider(height: 1), //separator between items
      itemBuilder: (context, i) {
        final data = docs[i].data();
        final type = (data["type"] ?? "").toString();

        final titleName = (data["name"] ?? "").toString().trim();
        final movedByName = _resolveMovedByName(data);
        final movedAt = data["movedAt"] as Timestamp?;

        final oldLine = type == "product"
            ? _foldersOnlyFromPath(data["oldPathNames"])
            : _formatPathNames(data["oldPathNames"]);

        final newLine = type == "product"
            ? _foldersOnlyFromPath(data["newPathNames"])
            : _formatPathNames(data["newPathNames"]);

        return ListTile(
          leading: Icon(
            type == "folder" ? Icons.folder : Icons.inventory_2,
          ),
          title: Text(titleName.isEmpty ? "(unnamed)" : titleName),
          subtitle: Text(
            "$oldLine\n→ $newLine"
                "${movedByName.isEmpty ? "" : "\nby $movedByName"}"
                "${movedAt == null ? "" : "\n${_formatTime(movedAt)}"}",
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final fs = FirebaseFirestore.instance;

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
            body: _buildTenantError(tenantSnap.error),
          );
        }

        final tenantId = tenantSnap.data!;

        return Scaffold(
          appBar: _buildAppBar(),
          body: SafeArea(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: fs
                  .collection("tenants")
                  .doc(tenantId)
                  .collection("movement_history")
                  .orderBy("movedAt", descending: true)
                  .limit(200)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return const Center(
                    child: Text("Error loading movement history"),
                  );
                }

                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snap.data!.docs;

                if (docs.isEmpty) {
                  return const Center(
                    child: Text("No movement records yet."),
                  );
                }

                return _buildHistoryList(tenantId, docs);
              },
            ),
          ),
        );
      },
    );
  }
}