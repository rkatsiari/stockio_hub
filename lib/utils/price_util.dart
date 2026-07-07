import 'package:cloud_firestore/cloud_firestore.dart';

/// Shared price lookup used by both the Home dashboard (insights) and
/// ExportService (profit/stock exports), so both stay in sync with how
/// prices are read from Firestore. Extracted verbatim from the old
/// _HomeScreenState._getPrice so behavior is unchanged.
class PriceUtil {
  PriceUtil._();

  static Future<double> getPrice(
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
}