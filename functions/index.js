const functions = require("firebase-functions");
const admin = require("firebase-admin");
admin.initializeApp();

const db = admin.firestore();

const ALLOWED_ROLES = [
  "admin",
  "manager",
  "accountant",
  "storage_manager",
  "staff",
  "reseller",
];

const OUT_OF_STOCK_SYSTEM_TYPE = "out_of_stock";

function normalizeString(value) {
  return String(value || "").trim();
}

function normalizeEmail(value) {
  return normalizeString(value).toLowerCase();
}

function normalizeRole(value) {
  return String(value ?? "staff").trim().toLowerCase();
}

function toNumber(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function validatePassword(password) {
  const value = String(password || "");

  if (!value) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Password is required."
    );
  }

  if (value.length < 8) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Password must be at least 8 characters long."
    );
  }

  if (!/[A-Z]/.test(value)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Password must include at least 1 uppercase letter."
    );
  }

  if (!/[a-z]/.test(value)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Password must include at least 1 lowercase letter."
    );
  }

  if (!/[0-9]/.test(value)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Password must include at least 1 number."
    );
  }
}

async function assertAdmin(context) {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "You must be logged in."
    );
  }

  const callerUid = context.auth.uid;

  const callerDoc = await db.collection("users").doc(callerUid).get();

  if (!callerDoc.exists) {
    throw new functions.https.HttpsError(
      "not-found",
      "Caller profile not found."
    );
  }

  const callerRole = callerDoc.data()?.role ?? null;

  if (callerRole !== "admin") {
    throw new functions.https.HttpsError(
      "permission-denied",
      "Admins only."
    );
  }

  return callerUid;
}

async function getUserTenantId(uid) {
  const userDoc = await db.collection("users").doc(uid).get();

  if (!userDoc.exists) {
    throw new functions.https.HttpsError(
      "not-found",
      "User profile not found."
    );
  }

  const tenantId = normalizeString(userDoc.data()?.tenantId);

  if (!tenantId) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "User is not assigned to a tenant."
    );
  }

  return tenantId;
}

async function assertAdminInTenant(context, requestedTenantId) {
  const callerUid = await assertAdmin(context);
  const callerTenantId = await getUserTenantId(callerUid);

  if (callerTenantId !== requestedTenantId) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "You can only manage users in your own tenant."
    );
  }

  return callerUid;
}

async function assertSignedInAndGetTenant(context, requestedTenantId) {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "You must be logged in."
    );
  }

  const callerUid = context.auth.uid;
  const callerTenantId = await getUserTenantId(callerUid);

  if (requestedTenantId && callerTenantId !== requestedTenantId) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "You can only access your own tenant."
    );
  }

  return {
    uid: callerUid,
    tenantId: callerTenantId,
  };
}

async function getFolderDoc(tenantId, folderId) {
  const safeFolderId = normalizeString(folderId);
  if (!safeFolderId) return null;

  const snap = await db
    .collection("tenants")
    .doc(tenantId)
    .collection("folders")
    .doc(safeFolderId)
    .get();

  return snap.exists ? snap : null;
}

function isOutOfStockFolderData(data) {
  return (
    data?.isSystemFolder === true &&
    normalizeString(data?.systemType) === OUT_OF_STOCK_SYSTEM_TYPE
  );
}

async function getChildOutOfStockFolderDoc(tenantId, parentFolderId) {
  const safeParentFolderId = normalizeString(parentFolderId);
  if (!safeParentFolderId) return null;

  const foldersRef = db.collection("tenants").doc(tenantId).collection("folders");

  const snapshot = await foldersRef
    .where("parentId", "==", safeParentFolderId)
    .where("systemType", "==", OUT_OF_STOCK_SYSTEM_TYPE)
    .limit(1)
    .get();

  if (snapshot.empty) {
    return null;
  }

  return snapshot.docs[0];
}

async function getOrCreateChildOutOfStockFolder(tenantId, parentFolderId) {
  const safeParentFolderId = normalizeString(parentFolderId);
  if (!safeParentFolderId) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "A valid parent folder is required."
    );
  }

  const foldersRef = db.collection("tenants").doc(tenantId).collection("folders");

  const parentFolderSnap = await getFolderDoc(tenantId, safeParentFolderId);
  if (!parentFolderSnap) {
    throw new functions.https.HttpsError(
      "not-found",
      "Parent folder not found."
    );
  }

  const parentFolderData = parentFolderSnap.data() || {};
  if (isOutOfStockFolderData(parentFolderData)) {
    return parentFolderSnap.id;
  }

  const existingDoc = await getChildOutOfStockFolderDoc(tenantId, safeParentFolderId);
  if (existingDoc) {
    return existingDoc.id;
  }

  const folderRef = foldersRef.doc();

  await folderRef.set({
    name: "Out of stock",
    isSystemFolder: true,
    systemType: OUT_OF_STOCK_SYSTEM_TYPE,
    parentId: safeParentFolderId,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return folderRef.id;
}

function buildMoveToOutOfStockUpdate({
  currentFolderId,
  originalFolderId,
  outOfStockFolderId,
  newStock,
}) {
  const safeCurrentFolderId = normalizeString(currentFolderId);
  const safeOriginalFolderId = normalizeString(originalFolderId);
  const safeOutOfStockFolderId = normalizeString(outOfStockFolderId);

  const restoreFolderId =
    safeCurrentFolderId &&
    safeCurrentFolderId !== safeOutOfStockFolderId
      ? safeCurrentFolderId
      : (
          safeOriginalFolderId &&
          safeOriginalFolderId !== safeOutOfStockFolderId
            ? safeOriginalFolderId
            : ""
        );

  const updateData = {
    stockQuantity: newStock,
    folderId: safeOutOfStockFolderId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  if (restoreFolderId) {
    updateData.originalFolderId = restoreFolderId;
  }

  return updateData;
}

function buildRestoreFromOutOfStockUpdate({
  currentFolderId,
  originalFolderId,
  outOfStockFolderId,
  newStock,
}) {
  const safeCurrentFolderId = normalizeString(currentFolderId);
  const safeOriginalFolderId = normalizeString(originalFolderId);
  const safeOutOfStockFolderId = normalizeString(outOfStockFolderId);

  const updateData = {
    stockQuantity: newStock,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  if (
    safeCurrentFolderId === safeOutOfStockFolderId &&
    safeOriginalFolderId &&
    safeOriginalFolderId !== safeOutOfStockFolderId
  ) {
    updateData.folderId = safeOriginalFolderId;
    updateData.originalFolderId = admin.firestore.FieldValue.delete();
  }

  return updateData;
}

async function writeStockMovement({
  tenantId,
  productId,
  productName,
  previousStock,
  newStock,
  quantityChanged,
  changedBy,
  type,
}) {
  const movementRef = db
    .collection("tenants")
    .doc(tenantId)
    .collection("movement_history")
    .doc();

  await movementRef.set({
    type,
    productId,
    productName: normalizeString(productName),
    previousStock: toNumber(previousStock, 0),
    newStock: toNumber(newStock, 0),
    quantityChanged: toNumber(quantityChanged, 0),
    changedBy: normalizeString(changedBy),
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

// ============================================================
// DELETE USER
// ============================================================
exports.deleteAuthUser = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    try {
      const tenantId = normalizeString(data?.tenantId);
      const uidToDelete = normalizeString(data?.uid);

      if (!tenantId) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "tenantId is required."
        );
      }

      if (!uidToDelete) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "uid is required."
        );
      }

      const callerUid = await assertAdminInTenant(context, tenantId);

      if (uidToDelete === callerUid) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "You cannot delete yourself."
        );
      }

      const rootUserRef = db.collection("users").doc(uidToDelete);
      const tenantUserRef = db
        .collection("tenants")
        .doc(tenantId)
        .collection("users")
        .doc(uidToDelete);

      const rootUserDoc = await rootUserRef.get();

      if (rootUserDoc.exists) {
        const userTenantId = normalizeString(rootUserDoc.data()?.tenantId);
        if (userTenantId && userTenantId !== tenantId) {
          throw new functions.https.HttpsError(
            "permission-denied",
            "User does not belong to this tenant."
          );
        }
      }

      try {
        await admin.auth().deleteUser(uidToDelete);
      } catch (err) {
        const code = err?.code || "";
        const message = (err?.message || "").toLowerCase();

        if (
          code === "auth/user-not-found" ||
          message.includes("user not found")
        ) {
          throw new functions.https.HttpsError(
            "not-found",
            "User not found."
          );
        }

        throw err;
      }

      const batch = db.batch();
      batch.delete(rootUserRef);
      batch.delete(tenantUserRef);
      await batch.commit();

      console.log(`Deleted user ${uidToDelete} from tenant ${tenantId}`);
      return { ok: true };
    } catch (err) {
      console.error("deleteAuthUser failed", err);

      if (err instanceof functions.https.HttpsError) throw err;

      throw new functions.https.HttpsError(
        "internal",
        "Unexpected error while deleting user."
      );
    }
  });

// ============================================================
// CREATE USER
// ============================================================
exports.createAuthUser = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    try {
      const tenantId = normalizeString(data?.tenantId);
      const name = normalizeString(data?.name);
      const email = normalizeEmail(data?.email);
      const password = String(data?.password || "");
      const role = normalizeRole(data?.role);

      if (!tenantId) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "tenantId is required."
        );
      }

      const callerUid = await assertAdminInTenant(context, tenantId);

      if (!name) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "name is required."
        );
      }

      if (!email) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "email is required."
        );
      }

      validatePassword(password);

      if (!ALLOWED_ROLES.includes(role)) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          `role must be one of: ${ALLOWED_ROLES.join(", ")}`
        );
      }

      const tenantDoc = await db.collection("tenants").doc(tenantId).get();

      if (!tenantDoc.exists) {
        throw new functions.https.HttpsError(
          "not-found",
          "Tenant not found."
        );
      }

      const userRecord = await admin.auth().createUser({
        email,
        password,
        displayName: name,
      });

      const uid = userRecord.uid;
      const now = admin.firestore.FieldValue.serverTimestamp();

      const rootUserData = {
        name,
        email,
        role,
        tenantId,
        isActive: true,
        created_at: now,
      };

      const tenantUserData = {
        uid,
        name,
        email,
        role,
        tenantId,
        isActive: true,
        created_at: now,
        created_by: callerUid,
      };

      const batch = db.batch();

      batch.set(db.collection("users").doc(uid), rootUserData);

      batch.set(
        db.collection("tenants").doc(tenantId).collection("users").doc(uid),
        tenantUserData
      );

      await batch.commit();

      console.log(`Created auth user: ${uid} (${email}) in tenant ${tenantId}`);
      return { ok: true, uid };
    } catch (err) {
      console.error("createAuthUser failed", err);

      if (err instanceof functions.https.HttpsError) throw err;

      const code = err?.code || "";
      const message = (err?.message || "").toLowerCase();

      if (
        code === "auth/email-already-exists" ||
        (message.includes("email") &&
          (message.includes("already") || message.includes("exists")))
      ) {
        throw new functions.https.HttpsError(
          "already-exists",
          "Email already in use."
        );
      }

      if (
        code === "auth/invalid-password" ||
        message.includes("password")
      ) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "Password does not meet the required policy."
        );
      }

      throw new functions.https.HttpsError(
        "internal",
        "Unexpected error while creating user."
      );
    }
  });

// ============================================================
// UPDATE USER
// ============================================================
exports.updateAuthUser = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    try {
      const tenantId = normalizeString(data?.tenantId);
      const uid = normalizeString(data?.uid);
      const name = normalizeString(data?.name);
      const email = normalizeEmail(data?.email);
      const role = normalizeRole(data?.role);

      if (!tenantId) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "tenantId is required."
        );
      }

      const callerUid = await assertAdminInTenant(context, tenantId);

      if (!uid) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "uid is required."
        );
      }

      if (!name) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "name is required."
        );
      }

      if (!email) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "email is required."
        );
      }

      if (!ALLOWED_ROLES.includes(role)) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          `role must be one of: ${ALLOWED_ROLES.join(", ")}`
        );
      }

      const rootUserRef = db.collection("users").doc(uid);
      const rootUserDoc = await rootUserRef.get();

      if (!rootUserDoc.exists) {
        throw new functions.https.HttpsError(
          "not-found",
          "User profile not found."
        );
      }

      const existingTenantId = normalizeString(rootUserDoc.data()?.tenantId);

      if (!existingTenantId) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "User is not assigned to a tenant."
        );
      }

      if (existingTenantId !== tenantId) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "User does not belong to this tenant."
        );
      }

      await admin.auth().getUser(uid);

      await admin.auth().updateUser(uid, {
        email,
        displayName: name,
      });

      const now = admin.firestore.FieldValue.serverTimestamp();

      const batch = db.batch();

      batch.update(rootUserRef, {
        name,
        email,
        role,
        tenantId,
        isActive: true,
        updated_at: now,
        updated_by: callerUid,
      });

      const tenantUserRef = db
        .collection("tenants")
        .doc(tenantId)
        .collection("users")
        .doc(uid);

      batch.set(
        tenantUserRef,
        {
          uid,
          name,
          email,
          role,
          tenantId,
          isActive: true,
          updated_at: now,
          updated_by: callerUid,
        },
        { merge: true }
      );

      await batch.commit();

      console.log(`Updated user: ${uid} (${email}) role=${role} tenant=${tenantId}`);
      return { ok: true };
    } catch (err) {
      console.error("updateAuthUser failed", err);

      if (err instanceof functions.https.HttpsError) throw err;

      const code = err?.code || "";
      const message = (err?.message || "").toLowerCase();

      if (
        code === "auth/email-already-exists" ||
        (message.includes("email") &&
          (message.includes("already") || message.includes("exists")))
      ) {
        throw new functions.https.HttpsError(
          "already-exists",
          "Email already in use."
        );
      }

      if (
        code === "auth/user-not-found" ||
        message.includes("user not found")
      ) {
        throw new functions.https.HttpsError(
          "not-found",
          "User not found."
        );
      }

      throw new functions.https.HttpsError(
        "internal",
        "Unexpected error while updating user."
      );
    }
  });

// ============================================================
// CHECK + RESERVE STOCK BEFORE ORDER CREATION
// ============================================================
exports.checkAndReserveStockForOrder = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    try {
      const requestedTenantId = normalizeString(data?.tenantId);
      const items = Array.isArray(data?.items) ? data.items : [];

      if (!requestedTenantId) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "tenantId is required."
        );
      }

      if (!items.length) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "At least one item is required."
        );
      }

      const authInfo = await assertSignedInAndGetTenant(context, requestedTenantId);
      const tenantId = authInfo.tenantId;
      const callerUid = authInfo.uid;

      const productsCol = db.collection("tenants").doc(tenantId).collection("products");
      const movementCol = db.collection("tenants").doc(tenantId).collection("movement_history");

      const cleanedItems = items.map((item) => {
        const productId = normalizeString(item?.productId);
        const quantity = toNumber(item?.quantity, 0);

        if (!productId) {
          throw new functions.https.HttpsError(
            "invalid-argument",
            "Each item must include productId."
          );
        }

        if (!Number.isInteger(quantity) || quantity <= 0) {
          throw new functions.https.HttpsError(
            "invalid-argument",
            `Invalid quantity for product ${productId}.`
          );
        }

        return { productId, quantity };
      });

      const results = await db.runTransaction(async (tx) => {
        const output = [];

        for (const item of cleanedItems) {
          const productRef = productsCol.doc(item.productId);
          const snap = await tx.get(productRef);

          if (!snap.exists) {
            throw new functions.https.HttpsError(
              "not-found",
              `Product not found: ${item.productId}`
            );
          }

          const data = snap.data() || {};
          const productName =
            normalizeString(data.name) ||
            normalizeString(data.code) ||
            "Unnamed product";

          const currentStock = toNumber(data.stockQuantity, 0);
          const currentFolderId = normalizeString(data.folderId);
          const originalFolderId = normalizeString(data.originalFolderId);

          if (currentStock < item.quantity) {
            throw new functions.https.HttpsError(
              "failed-precondition",
              `${productName} does not have enough stock. Available: ${currentStock}, requested: ${item.quantity}.`
            );
          }

          const newStock = currentStock - item.quantity;

          let updateData = {
            stockQuantity: newStock,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          };

          let folderIdAfterUpdate = currentFolderId;

          if (newStock <= 0) {
            const outOfStockFolderId = await getOrCreateChildOutOfStockFolder(
              tenantId,
              currentFolderId
            );

            updateData = buildMoveToOutOfStockUpdate({
              currentFolderId,
              originalFolderId,
              outOfStockFolderId,
              newStock,
            });

            folderIdAfterUpdate = outOfStockFolderId;
          }

          tx.update(productRef, updateData);

          const movementRef = movementCol.doc();
          tx.set(movementRef, {
            type: "order_reservation",
            productId: item.productId,
            productName,
            previousStock: currentStock,
            newStock,
            quantityChanged: -item.quantity,
            changedBy: callerUid,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          output.push({
            productId: item.productId,
            productName,
            reservedQuantity: item.quantity,
            previousStock: currentStock,
            newStock,
            folderIdAfterUpdate,
          });
        }

        return output;
      });

      return {
        ok: true,
        tenantId,
        items: results,
      };
    } catch (err) {
      console.error("checkAndReserveStockForOrder failed", err);

      if (err instanceof functions.https.HttpsError) throw err;

      throw new functions.https.HttpsError(
        "internal",
        "Unexpected error while checking or reserving stock."
      );
    }
  });

// ============================================================
// RESTORE STOCK AFTER ORDER CANCEL / REVERT
// ============================================================
exports.restoreStockForCancelledOrder = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    try {
      const requestedTenantId = normalizeString(data?.tenantId);
      const items = Array.isArray(data?.items) ? data.items : [];

      if (!requestedTenantId) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "tenantId is required."
        );
      }

      if (!items.length) {
        throw new functions.https.HttpsError(
          "invalid-argument",
          "At least one item is required."
        );
      }

      const authInfo = await assertSignedInAndGetTenant(context, requestedTenantId);
      const tenantId = authInfo.tenantId;
      const callerUid = authInfo.uid;

      const productsCol = db.collection("tenants").doc(tenantId).collection("products");
      const movementCol = db.collection("tenants").doc(tenantId).collection("movement_history");

      const cleanedItems = items.map((item) => {
        const productId = normalizeString(item?.productId);
        const quantity = toNumber(item?.quantity, 0);

        if (!productId) {
          throw new functions.https.HttpsError(
            "invalid-argument",
            "Each item must include productId."
          );
        }

        if (!Number.isInteger(quantity) || quantity <= 0) {
          throw new functions.https.HttpsError(
            "invalid-argument",
            `Invalid quantity for product ${productId}.`
          );
        }

        return { productId, quantity };
      });

      const results = await db.runTransaction(async (tx) => {
        const output = [];

        for (const item of cleanedItems) {
          const productRef = productsCol.doc(item.productId);
          const snap = await tx.get(productRef);

          if (!snap.exists) {
            throw new functions.https.HttpsError(
              "not-found",
              `Product not found: ${item.productId}`
            );
          }

          const data = snap.data() || {};
          const productName =
            normalizeString(data.name) ||
            normalizeString(data.code) ||
            "Unnamed product";

          const currentStock = toNumber(data.stockQuantity, 0);
          const currentFolderId = normalizeString(data.folderId);
          const originalFolderId = normalizeString(data.originalFolderId);

          const currentFolderSnap = await getFolderDoc(tenantId, currentFolderId);
          const currentFolderData = currentFolderSnap?.data() || {};
          const currentIsOutOfStock = isOutOfStockFolderData(currentFolderData);

          let outOfStockFolderId = "";
          if (currentIsOutOfStock) {
            outOfStockFolderId = currentFolderId;
          } else if (originalFolderId) {
            const possibleChild = await getChildOutOfStockFolderDoc(
              tenantId,
              originalFolderId
            );
            if (possibleChild) {
              outOfStockFolderId = possibleChild.id;
            }
          }

          const newStock = currentStock + item.quantity;

          const updateData = buildRestoreFromOutOfStockUpdate({
            currentFolderId,
            originalFolderId,
            outOfStockFolderId,
            newStock,
          });

          tx.update(productRef, updateData);

          const movementRef = movementCol.doc();
          tx.set(movementRef, {
            type: "order_cancellation_restore",
            productId: item.productId,
            productName,
            previousStock: currentStock,
            newStock,
            quantityChanged: item.quantity,
            changedBy: callerUid,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          output.push({
            productId: item.productId,
            productName,
            restoredQuantity: item.quantity,
            previousStock: currentStock,
            newStock,
            folderIdAfterUpdate:
              currentFolderId === outOfStockFolderId &&
              originalFolderId &&
              originalFolderId !== outOfStockFolderId
                ? originalFolderId
                : currentFolderId,
          });
        }

        return output;
      });

      return {
        ok: true,
        tenantId,
        items: results,
      };
    } catch (err) {
      console.error("restoreStockForCancelledOrder failed", err);

      if (err instanceof functions.https.HttpsError) throw err;

      throw new functions.https.HttpsError(
        "internal",
        "Unexpected error while restoring stock."
      );
    }
  });

// ============================================================
// SAFETY NET ONLY:
// AUTO MOVE PRODUCT TO / FROM OUT OF STOCK FOLDER
// ============================================================
exports.onProductStockChangeMoveFolder = functions
  .region("us-central1")
  .firestore.document("tenants/{tenantId}/products/{productId}")
  .onWrite(async (change, context) => {
    const tenantId = normalizeString(context.params.tenantId);
    const productId = normalizeString(context.params.productId);

    if (!change.after.exists) {
      return null;
    }

    const beforeData = change.before.exists ? change.before.data() || {} : {};
    const afterData = change.after.data() || {};

    const beforeStock = toNumber(beforeData.stockQuantity, 0);
    const afterStock = toNumber(afterData.stockQuantity, 0);

    const beforeFolderId = normalizeString(beforeData.folderId);
    const currentFolderId = normalizeString(afterData.folderId);
    const originalFolderId = normalizeString(afterData.originalFolderId);
    const beforeOriginalFolderId = normalizeString(beforeData.originalFolderId);
    const productName =
      normalizeString(afterData.name) ||
      normalizeString(afterData.code) ||
      "Unnamed product";

    const noRelevantChange =
      beforeStock === afterStock &&
      beforeFolderId === currentFolderId &&
      beforeOriginalFolderId === originalFolderId;

    if (noRelevantChange) {
      return null;
    }

    const productRef = db
      .collection("tenants")
      .doc(tenantId)
      .collection("products")
      .doc(productId);

    const currentFolderSnap = await getFolderDoc(tenantId, currentFolderId);
    const currentFolderData = currentFolderSnap?.data() || {};
    const currentlyInOutOfStock = isOutOfStockFolderData(currentFolderData);

    if (afterStock <= 0) {
      if (currentlyInOutOfStock) {
        return null;
      }

      const outOfStockFolderId = await getOrCreateChildOutOfStockFolder(
        tenantId,
        currentFolderId
      );

      if (outOfStockFolderId === currentFolderId) {
        return null;
      }

      const updateData = buildMoveToOutOfStockUpdate({
        currentFolderId,
        originalFolderId,
        outOfStockFolderId,
        newStock: afterStock,
      });

      await productRef.update(updateData);

      await writeStockMovement({
        tenantId,
        productId,
        productName,
        previousStock: beforeStock,
        newStock: afterStock,
        quantityChanged: 0,
        changedBy: "system",
        type: "auto_moved_to_out_of_stock",
      });

      return null;
    }

    if (afterStock > 0) {
      if (!currentlyInOutOfStock) {
        return null;
      }

      if (!originalFolderId || originalFolderId === currentFolderId) {
        console.warn(
          `Product ${productId} is back in stock but has invalid originalFolderId.`
        );
        return null;
      }

      const updateData = buildRestoreFromOutOfStockUpdate({
        currentFolderId,
        originalFolderId,
        outOfStockFolderId: currentFolderId,
        newStock: afterStock,
      });

      if (!updateData.folderId) {
        return null;
      }

      await productRef.update(updateData);

      await writeStockMovement({
        tenantId,
        productId,
        productName,
        previousStock: beforeStock,
        newStock: afterStock,
        quantityChanged: 0,
        changedBy: "system",
        type: "auto_restored_from_out_of_stock",
      });

      return null;
    }

    return null;
  });