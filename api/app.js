import { createClient } from "@supabase/supabase-js";
import { buildRevenueReportPayload } from "./_lib/reporting.js";

const BRANDING_IMAGES_BUCKET = "branding-assets";
const BRANDING_IMAGE_OBJECT = "app-logo";
const PRODUCT_IMAGES_BUCKET = "product-images";
const PRODUCT_IMAGE_MAX_BYTES = 600 * 1024;
const PRODUCT_IMAGE_ALLOWED_MIME = new Set([
  "image/png",
  "image/jpeg",
  "image/webp",
  "image/gif",
  "image/svg+xml",
]);

function json(res, status, body) {
  res.status(status).setHeader("Content-Type", "application/json");
  res.send(JSON.stringify(body));
}

function setCacheHeaders(res, value) {
  res.setHeader("Cache-Control", value);
  res.setHeader("CDN-Cache-Control", value);
  res.setHeader("Vercel-CDN-Cache-Control", value);
}

function getServiceClient() {
  const url = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceKey) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
  }
  return createClient(url, serviceKey, { auth: { persistSession: false } });
}

function extractBearerToken(req) {
  const auth = req.headers.authorization || "";
  if (!auth.startsWith("Bearer ")) return null;
  return auth.slice(7).trim() || null;
}

async function stampBookingDeviceTrace(supabase, txId, deviceId) {
  if (!txId || !deviceId) return null;

  const { error: txError } = await supabase
    .from("transactions")
    .update({
      device_id: deviceId,
      device_id_snapshot: deviceId,
    })
    .eq("id", txId);
  if (txError) return txError;

  const { error: moveError } = await supabase
    .from("inventory_movements")
    .update({
      device_id: deviceId,
      device_id_snapshot: deviceId,
    })
    .eq("transaction_id", txId)
    .eq("reason", "sale")
    .is("device_id", null);
  if (moveError) return moveError;

  return null;
}

async function loadMemberPinMap(supabase, memberIds) {
  const ids = Array.isArray(memberIds) ? memberIds.filter(Boolean) : [];
  if (!ids.length) return new Map();

  const { data, error } = await supabase
    .from("member_pins")
    .select("member_id, pin_plain")
    .in("member_id", ids);
  if (error) throw error;

  return new Map(
    (data ?? []).map((row) => [
      row.member_id,
      String(row.pin_plain ?? "").trim().length > 0,
    ]),
  );
}

async function readRevenueRowsPaginated(supabase, token, start, end, options = {}) {
  const pageSize = Math.max(1, Math.min(5000, Number(options.pageSize ?? 1000)));
  const maxPages = Math.max(1, Math.min(500, Number(options.maxPages ?? 200)));
  const rows = [];
  let offset = 0;
  let truncated = false;

  for (let page = 0; page < maxPages; page += 1) {
    const { data, error } = await supabase.rpc("api_admin_get_revenue_report_period", {
      p_token: token,
      p_start: start,
      p_end: end,
      p_limit: pageSize,
      p_offset: offset,
    });
    if (error) throw error;

    const batch = Array.isArray(data) ? data : [];
    rows.push(...batch);
    if (batch.length < pageSize) {
      return { rows, truncated: false };
    }
    offset += pageSize;
  }

  truncated = true;
  return { rows, truncated };
}

async function verifyDevice(req) {
  const token = extractBearerToken(req);
  if (!token) return { ok: false, status: 401, error: "Missing bearer token" };

  const supabase = getServiceClient();
  const { data: sessionRows, error: sessionError } = await supabase.rpc("app_apply_session", {
    p_token: token,
  });
  const session = Array.isArray(sessionRows) ? sessionRows[0] : null;
  if (sessionError || !session || session.role !== "device" || session.actor_type !== "device") {
    return { ok: false, status: 403, error: "Invalid device session" };
  }

  const { data: device, error: deviceError } = await supabase
    .from("kiosk_devices")
    .select("id, active")
    .eq("id", session.actor_id)
    .eq("active", true)
    .maybeSingle();

  if (deviceError || !device) return { ok: false, status: 403, error: "Unauthorized device" };
  return { ok: true, deviceId: device.id };
}

function normalizePin(v) {
  return String(v || "").replace(/[^A-Za-z0-9]/g, "").slice(0, 4);
}

function getProductImageObjectPath(productId) {
  return `products/${String(productId ?? "").trim()}`;
}

function buildProductImageUrl(supabase, row) {
  const path = String(row?.product_image_path ?? "").trim();
  if (path) {
    const { data } = supabase.storage.from(PRODUCT_IMAGES_BUCKET).getPublicUrl(path);
    const base = data?.publicUrl ?? null;
    if (!base) return null;
    const version = row?.product_image_version ?? null;
    return version ? `${base}?v=${encodeURIComponent(String(version))}` : base;
  }

  const raw = String(row?.product_image_data_url ?? "").trim();
  return raw || null;
}

function buildBrandingImageUrl(supabase, bustToken = null) {
  const { data } = supabase.storage.from(BRANDING_IMAGES_BUCKET).getPublicUrl(BRANDING_IMAGE_OBJECT);
  const base = data?.publicUrl ?? null;
  if (!base) return null;
  return bustToken ? `${base}?v=${encodeURIComponent(String(bustToken))}` : base;
}

async function verifyAdminSession(req) {
  const token = extractBearerToken(req);
  if (!token) return { ok: false, status: 401, error: "Unauthorized" };

  const supabase = getServiceClient();
  const { data: rows, error } = await supabase.rpc("app_apply_session", { p_token: token });
  const ctx = Array.isArray(rows) ? rows[0] : null;
  if (error || !ctx || ctx.role !== "admin") {
    return { ok: false, status: 403, error: "Forbidden" };
  }
  return { ok: true, token };
}

function parseImageDataUrl(dataUrl) {
  const raw = String(dataUrl ?? "");
  const m = raw.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,([A-Za-z0-9+/=]+)$/);
  if (!m) throw new Error("Ungueltiges Bildformat");
  const mime = m[1].toLowerCase();
  if (!PRODUCT_IMAGE_ALLOWED_MIME.has(mime)) {
    throw new Error("Dateityp nicht erlaubt");
  }
  const bytes = Buffer.from(m[2], "base64");
  if (!bytes.length) throw new Error("Leeres Bild");
  if (bytes.length > PRODUCT_IMAGE_MAX_BYTES) {
    throw new Error("Bild ist zu gross (max 600 KB)");
  }
  return { bytes, mime };
}

async function ensureBrandingImageBucket(supabase) {
  const { data } = await supabase.storage.getBucket(BRANDING_IMAGES_BUCKET);
  if (data) return;
  const { error } = await supabase.storage.createBucket(BRANDING_IMAGES_BUCKET, {
    public: true,
    fileSizeLimit: PRODUCT_IMAGE_MAX_BYTES,
  });
  if (error && !String(error.message || "").toLowerCase().includes("already exists")) {
    throw error;
  }
}

async function ensureProductImageBucket(supabase) {
  const { data } = await supabase.storage.getBucket(PRODUCT_IMAGES_BUCKET);
  if (data) return;
  const { error } = await supabase.storage.createBucket(PRODUCT_IMAGES_BUCKET, {
    public: true,
    fileSizeLimit: PRODUCT_IMAGE_MAX_BYTES,
  });
  if (error && !String(error.message || "").toLowerCase().includes("already exists")) {
    throw error;
  }
}

async function persistProductImageAsset(supabase, productId, imageDataUrl) {
  const { bytes, mime } = parseImageDataUrl(imageDataUrl);
  await ensureProductImageBucket(supabase);

  const objectPath = getProductImageObjectPath(productId);
  const version = Date.now();
  const { error: uploadError } = await supabase.storage
    .from(PRODUCT_IMAGES_BUCKET)
    .upload(objectPath, bytes, {
      contentType: mime,
      upsert: true,
      cacheControl: "31536000",
    });
  if (uploadError) {
    throw new Error(uploadError.message || "Upload failed");
  }

  const { error: updateError } = await supabase
    .from("products")
    .update({
      product_image_path: objectPath,
      product_image_version: version,
      product_image_data_url: null,
    })
    .eq("id", productId);
  if (updateError) {
    throw new Error(updateError.message || "Save failed");
  }

  return {
    product_image_path: objectPath,
    product_image_version: version,
    product_image_data_url: null,
    image_url: buildProductImageUrl(supabase, {
      product_image_path: objectPath,
      product_image_version: version,
    }),
  };
}

async function migrateLegacyProductImage(supabase, row) {
  if (!row?.id) return row;
  const hasStoragePath = String(row.product_image_path ?? "").trim().length > 0;
  const legacyDataUrl = String(row.product_image_data_url ?? "").trim();
  if (hasStoragePath || !legacyDataUrl) {
    return row;
  }

  try {
    const migrated = await persistProductImageAsset(supabase, row.id, legacyDataUrl);
    return {
      ...row,
      ...migrated,
    };
  } catch (error) {
    console.error("[migrateLegacyProductImage]", row.id, error);
    return row;
  }
}

async function migrateLegacyProductImages(supabase, rows) {
  const list = Array.isArray(rows) ? rows : [];
  const migrated = [];
  for (const row of list) {
    migrated.push(await migrateLegacyProductImage(supabase, row));
  }
  return migrated;
}

const ADMIN_RPC_ACTIONS = {
  get_inventory_snapshot: {
    fn: "api_admin_get_inventory_snapshot",
    args: (token) => ({ p_token: token }),
  },
  apply_inventory_count: {
    fn: "api_admin_apply_inventory_count",
    args: (token, p) => ({ p_token: token, p_items: p.items ?? [], p_note: p.note ?? null }),
  },
  get_inventory_adjustments_period: {
    fn: "api_admin_get_inventory_adjustments_period",
    args: (token, p) => ({ p_token: token, p_start: p.start, p_end: p.end }),
  },
  get_fridge_refills_period: {
    fn: "api_admin_get_fridge_refills_period",
    args: (token, p) => ({ p_token: token, p_start: p.start, p_end: p.end }),
  },
  get_all_bookings_grouped: {
    fn: "api_admin_get_all_bookings_grouped",
    args: (token, p) => ({ p_token: token, p_start: p.start, p_end: p.end }),
  },
  get_cancellations_report_period: {
    fn: "api_admin_get_cancellations_report_period",
    args: (token, p) => ({ p_token: token, p_start: p.start, p_end: p.end }),
  },
  get_settlements_report_period: {
    fn: "api_admin_get_settlements_report_period",
    args: (token, p) => ({ p_token: token, p_start: p.start, p_end: p.end }),
  },
  get_revenue_report_period: {
    fn: "api_admin_get_revenue_report_period",
    args: (token, p) => ({
      p_token: token,
      p_start: p.start,
      p_end: p.end,
      p_limit: p.limit ?? null,
      p_offset: p.offset ?? 0,
    }),
  },
  get_branding_settings: {
    fn: "api_admin_get_branding_settings",
    args: (token) => ({ p_token: token }),
  },
  upsert_branding_settings: {
    fn: "api_admin_upsert_branding_settings",
    args: (token, p) => ({
      p_token: token,
      p_app_title: p.app_title ?? null,
      p_logo_url: p.logo_url ?? null,
    }),
  },
  list_app_users: {
    fn: "api_admin_list_app_users",
    args: (token) => ({ p_token: token }),
  },
  create_app_user: {
    fn: "api_admin_create_app_user",
    args: (token, p) => ({
      p_token: token,
      p_username: p.username,
      p_password: p.password,
      p_is_admin: p.is_admin ?? true,
      p_active: p.active ?? true,
    }),
  },
  update_app_user: {
    fn: "api_admin_update_app_user",
    args: (token, p) => ({
      p_token: token,
      p_user_id: p.user_id,
      p_username: p.username ?? null,
      p_password: p.password ?? null,
      p_is_admin: p.is_admin ?? null,
      p_active: p.active ?? null,
    }),
  },
  list_kiosk_devices: {
    fn: "api_admin_list_kiosk_devices",
    args: (token) => ({ p_token: token }),
  },
  create_kiosk_device: {
    fn: "api_admin_create_kiosk_device",
    args: (token, p) => ({
      p_token: token,
      p_name: p.name,
      p_device_key: p.device_key,
      p_active: p.active ?? true,
    }),
  },
  create_device_pairing_code: {
    fn: "api_admin_create_device_pairing_code",
    args: (token, p) => ({
      p_token: token,
      p_device_id: p.device_id,
      p_ttl_minutes: p.ttl_minutes ?? 5,
    }),
  },
  cancel_transaction: {
    fn: "api_admin_cancel_transaction",
    args: (token, p) => ({
      p_token: token,
      p_cancel_tx_id: p.cancel_tx_id ?? null,
      p_member_id: p.member_id ?? null,
      p_product_id: p.product_id ?? null,
      p_note: p.note ?? null,
    }),
  },
  book_free_amount: {
    fn: "api_admin_book_free_amount",
    args: (token, p) => ({
      p_token: token,
      p_member_id: p.member_id,
      p_amount_cents: p.amount_cents,
      p_note: p.note ?? null,
    }),
  },
  perform_monthly_settlement: {
    fn: "api_admin_perform_monthly_settlement",
    args: (token) => ({ p_token: token }),
  },
  list_members_balances: {
    fn: "api_admin_list_members_balances",
    args: (token) => ({ p_token: token }),
  },
  list_member_pins: {
    fn: "api_admin_list_member_pins",
    args: (token) => ({ p_token: token }),
  },
  upsert_member_pin: {
    fn: "api_admin_upsert_member_pin",
    args: (token, p) => ({ p_token: token, p_member_id: p.member_id, p_pin_plain: p.pin_plain }),
  },
  delete_member_pin: {
    fn: "api_admin_delete_member_pin",
    args: (token, p) => ({ p_token: token, p_member_id: p.member_id }),
  },
  stats_sales_trend: {
    fn: "api_admin_stats_sales_trend",
    args: (token, p) => ({ p_token: token, p_range: p.range ?? "30d" }),
  },
  stats_top_products_period: {
    fn: "api_admin_stats_top_products_period",
    args: (token, p) => ({ p_token: token, p_range: p.range ?? "30d" }),
  },
  stats_activity_heatmap_period: {
    fn: "api_admin_stats_activity_heatmap_period",
    args: (token, p) => ({ p_token: token, p_range: p.range ?? "30d" }),
  },
  stats_active_members_period: {
    fn: "api_admin_stats_active_members_period",
    args: (token, p) => ({ p_token: token, p_range: p.range ?? "30d" }),
  },
};

async function handleRoute(route, req, res) {
  const supabase = getServiceClient();
  const body = req.body || {};

  if (route === "admin-login") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const { username, password } = body;
    if (!username || !password) return json(res, 400, { error: "username and password are required" });
    const debugAuth = String(req.headers["x-debug-auth"] ?? "").trim() === "1";

    const { data: token, error: loginError } = await supabase.rpc("app_login_user", {
      p_username: String(username),
      p_password: String(password),
      p_ttl_hours: 12,
    });
    if (loginError || !token) {
      return json(res, 401, {
        error: "Unauthorized",
        details: loginError?.message ?? null,
        code: loginError?.code ?? null,
      });
    }

    const { data: ctxRows, error: ctxError } = await supabase.rpc("app_apply_session", {
      p_token: token,
    });
    const ctx = Array.isArray(ctxRows) ? ctxRows[0] : null;
    if (ctxError || !ctx || ctx.role !== "admin") {
      await supabase.rpc("app_logout", { p_token: token });
      const reason = ctxError
        ? "APP_APPLY_SESSION_ERROR"
        : !ctx
          ? "NO_SESSION_CONTEXT"
          : "ROLE_NOT_ADMIN";
      return json(res, 403, {
        error: "Forbidden",
        reason,
        ...(debugAuth
          ? {
            debug: {
              username: String(username),
              ctx: ctx ?? null,
              ctx_error: ctxError
                ? {
                  message: ctxError.message ?? null,
                  code: ctxError.code ?? null,
                  details: ctxError.details ?? null,
                  hint: ctxError.hint ?? null,
                }
                : null,
            },
          }
          : {}),
      });
    }

    return json(res, 200, {
      token,
      actor_type: ctx.actor_type,
      actor_id: ctx.actor_id,
      role: ctx.role,
    });
  }

  if (route === "admin-logout") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const token = extractBearerToken(req);
    if (!token) return json(res, 200, { success: true });
    await supabase.rpc("app_logout", { p_token: token });
    return json(res, 200, { success: true });
  }

  if (route === "admin-members") {
    const token = extractBearerToken(req);
    if (!token) return json(res, 401, { error: "Unauthorized" });

    if (req.method === "GET") {
      const { data, error } = await supabase.rpc("api_admin_list_members_token", { p_token: token });
      if (error) return json(res, 403, { error: error.message || "Forbidden" });
      return json(res, 200, data ?? []);
    }
    if (req.method === "POST") {
      if (!body.firstname || !body.lastname) return json(res, 400, { error: "Missing firstname/lastname" });
      const { data, error } = await supabase.rpc("api_admin_create_member", {
        p_token: token,
        p_firstname: body.firstname,
        p_lastname: body.lastname,
      });
      if (error) return json(res, 403, { error: error.message || "Forbidden" });
      return json(res, 201, data);
    }
    if (req.method === "PATCH") {
      if (!body.id) return json(res, 400, { error: "Missing id" });
      const { data, error } = await supabase.rpc("api_admin_update_member", {
        p_token: token,
        p_id: body.id,
        p_firstname: body.firstname ?? null,
        p_lastname: body.lastname ?? null,
        p_balance: body.balance ?? null,
        p_active: body.active ?? null,
      });
      if (error) return json(res, 403, { error: error.message || "Forbidden" });
      return json(res, 200, data);
    }
    if (req.method === "DELETE") {
      if (!body.id) return json(res, 400, { error: "Missing id" });
      const { error } = await supabase.rpc("api_admin_delete_member", {
        p_token: token,
        p_member_id: body.id,
        p_force: body.force ?? false,
      });
      if (error) return json(res, 403, { error: error.message || "Forbidden" });
      return res.status(204).end();
    }
    return json(res, 405, { error: "Method not allowed" });
  }

  if (route === "admin-products") {
    const token = extractBearerToken(req);
    if (!token) return json(res, 401, { error: "Unauthorized" });

    if (req.method === "GET") {
      const { data, error } = await supabase.rpc("api_admin_list_products", { p_token: token });
      if (error) return json(res, 403, { error: error.message || "Forbidden" });
      const baseRows = Array.isArray(data) ? data : [];
      const ids = baseRows.map((p) => p.id).filter(Boolean);
      let imageById = new Map();
      if (ids.length) {
        const { data: imageRows, error: imageError } = await supabase
          .from("products")
          .select("id,product_image_data_url,product_image_path,product_image_version")
          .in("id", ids);
        if (imageError) return json(res, 500, { error: imageError.message || "Image query failed" });
        const hydratedRows = await migrateLegacyProductImages(supabase, imageRows ?? []);
        imageById = new Map(hydratedRows.map((r) => [r.id, r]));
      }
      const rows = baseRows.map((p) => ({
        ...p,
        image_url: buildProductImageUrl(supabase, imageById.get(p.id)),
      }));
      return json(res, 200, rows);
    }
    if (req.method === "POST") {
      const { data, error } = await supabase.rpc("api_admin_create_product", {
        p_token: token,
        p_name: body.name ?? "Neu",
        p_price: body.price ?? 0,
        p_guest_price: body.guest_price ?? 0,
        p_category: body.category ?? "Sonstiges",
        p_active: body.active ?? true,
        p_inventoried: body.inventoried ?? true,
        p_last_purchase_price_cents: body.last_purchase_price_cents ?? 0,
      });
      if (error) return json(res, 403, { error: error.message || "Forbidden" });
      return json(res, 201, data);
    }
    if (req.method === "PATCH") {
      if (!body.id) return json(res, 400, { error: "Missing id" });
      const { data, error } = await supabase.rpc("api_admin_update_product", {
        p_token: token,
        p_id: body.id,
        p_name: body.name ?? null,
        p_price: body.price ?? null,
        p_guest_price: body.guest_price ?? null,
        p_category: body.category ?? null,
        p_active: body.active ?? null,
        p_inventoried: body.inventoried ?? null,
        p_last_purchase_price_cents: body.last_purchase_price_cents ?? null,
      });
      if (error) return json(res, 403, { error: error.message || "Forbidden" });
      return json(res, 200, data);
    }
    if (req.method === "DELETE") {
      if (!body.id) return json(res, 400, { error: "Missing id" });
      const { error } = await supabase.rpc("api_admin_delete_product", {
        p_token: token,
        p_product_id: body.id,
        p_force: body.force ?? false,
      });
      if (error) return json(res, 403, { error: error.message || "Forbidden" });
      return res.status(204).end();
    }
    return json(res, 405, { error: "Method not allowed" });
  }

  if (route === "admin-products-batch") {
    if (req.method !== "PATCH") return json(res, 405, { error: "Method not allowed" });
    const token = extractBearerToken(req);
    if (!token) return json(res, 401, { error: "Unauthorized" });
    const items = Array.isArray(body.items) ? body.items : [];
    if (!items.length) return json(res, 400, { error: "items are required" });

    const updatedItems = [];
    for (const item of items) {
      if (!item?.id) continue;
      const { data, error } = await supabase.rpc("api_admin_update_product", {
        p_token: token,
        p_id: item.id,
        p_name: item.name ?? null,
        p_price: item.price ?? null,
        p_guest_price: item.guest_price ?? null,
        p_category: item.category ?? null,
        p_active: item.active ?? null,
        p_inventoried: item.inventoried ?? null,
        p_last_purchase_price_cents: item.last_purchase_price_cents ?? null,
      });
      if (error) return json(res, 403, { error: error.message || "Forbidden" });
      updatedItems.push(data);
    }

    return json(res, 200, { items: updatedItems });
  }

  if (route === "admin-product-categories") {
    const token = extractBearerToken(req);
    if (!token) return json(res, 401, { error: "Unauthorized" });

    if (req.method === "GET") {
      const { data, error } = await supabase.rpc("api_admin_list_product_categories", {
        p_token: token,
      });
      if (error) return json(res, 403, { error: error.message || "Forbidden" });
      return json(res, 200, data ?? []);
    }

    if (req.method === "POST") {
      const name = String(body.name ?? "").trim();
      if (!name) return json(res, 400, { error: "Missing name" });
      const { data, error } = await supabase.rpc("api_admin_create_product_category", {
        p_token: token,
        p_name: name,
        p_active: body.active ?? true,
        p_sort_order: body.sort_order ?? 0,
      });
      if (error) return json(res, 403, { error: error.message || "Forbidden" });
      return json(res, 201, data);
    }

    if (req.method === "PATCH") {
      if (!body.id) return json(res, 400, { error: "Missing id" });
      const { data, error } = await supabase.rpc("api_admin_update_product_category", {
        p_token: token,
        p_id: body.id,
        p_name: body.name ?? null,
        p_active: body.active ?? null,
        p_sort_order: body.sort_order ?? null,
      });
      if (error) return json(res, 403, { error: error.message || "Forbidden" });
      return json(res, 200, data);
    }

    return json(res, 405, { error: "Method not allowed" });
  }

  if (route === "admin-product-image") {
    if (req.method !== "POST" && req.method !== "DELETE") {
      return json(res, 405, { error: "Method not allowed" });
    }
    const admin = await verifyAdminSession(req);
    if (!admin.ok) return json(res, admin.status, { error: admin.error });

    const productId = String(body.product_id ?? "").trim();
    if (!productId) return json(res, 400, { error: "product_id is required" });

    if (req.method === "DELETE") {
      const objectPath = getProductImageObjectPath(productId);
      await ensureProductImageBucket(supabase).catch(() => {});
      await supabase.storage.from(PRODUCT_IMAGES_BUCKET).remove([objectPath]).catch(() => {});
      const { data, error } = await supabase
        .from("products")
        .update({
          product_image_data_url: null,
          product_image_path: null,
          product_image_version: null,
        })
        .eq("id", productId);
      const { data: productRow, error: productError } = await supabase
        .from("products")
        .select("id,name,price,guest_price,category,active,inventoried,product_image_data_url,product_image_path,product_image_version")
        .eq("id", productId)
        .maybeSingle();
      if (error) return json(res, 500, { error: error.message || "Delete failed" });
      if (productError) return json(res, 500, { error: productError.message || "Product query failed" });
      return json(res, 200, {
        ...(productRow
          ? {
            id: productRow.id,
            name: productRow.name,
            price: productRow.price,
            guest_price: productRow.guest_price,
            category: productRow.category,
            active: productRow.active,
            inventoried: productRow.inventoried,
            image_url: buildProductImageUrl(supabase, productRow),
          }
          : {}),
      });
    }

    try {
      const imageDataUrl = String(body.image_data_url ?? "").trim();
      const saved = await persistProductImageAsset(supabase, productId, imageDataUrl);
      return json(res, 200, {
        success: true,
        image_url: saved.image_url,
      });
    } catch (err) {
      return json(res, 400, { error: err?.message || "Invalid image payload" });
    }
  }

  if (route === "admin-branding-logo") {
    if (req.method !== "POST" && req.method !== "DELETE") {
      return json(res, 405, { error: "Method not allowed" });
    }
    const admin = await verifyAdminSession(req);
    if (!admin.ok) return json(res, admin.status, { error: admin.error });

    try {
      await ensureBrandingImageBucket(supabase);

      if (req.method === "DELETE") {
        const { error: removeError } = await supabase.storage
          .from(BRANDING_IMAGES_BUCKET)
          .remove([BRANDING_IMAGE_OBJECT]);
        if (removeError) return json(res, 500, { error: removeError.message || "Delete failed" });

        const { error: saveError } = await supabase.rpc("api_admin_upsert_branding_settings", {
          p_token: admin.token,
          p_app_title: null,
          p_logo_url: "",
        });
        if (saveError) return json(res, 500, { error: saveError.message || "Save failed" });

        return json(res, 200, { data: { logo_url: null } });
      }

      const { bytes, mime } = parseImageDataUrl(body.image_data_url);
      const { error: uploadError } = await supabase.storage
        .from(BRANDING_IMAGES_BUCKET)
        .upload(BRANDING_IMAGE_OBJECT, bytes, {
          contentType: mime,
          upsert: true,
          cacheControl: "60",
        });
      if (uploadError) return json(res, 500, { error: uploadError.message || "Upload failed" });

      const nextLogoUrl = buildBrandingImageUrl(supabase, Date.now());
      const { error: saveError } = await supabase.rpc("api_admin_upsert_branding_settings", {
        p_token: admin.token,
        p_app_title: null,
        p_logo_url: nextLogoUrl,
      });
      if (saveError) return json(res, 500, { error: saveError.message || "Save failed" });

      return json(res, 200, { data: { logo_url: nextLogoUrl } });
    } catch (err) {
      return json(res, 400, { error: err?.message || "Invalid image payload" });
    }
  }

  if (route === "admin-storage") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const token = extractBearerToken(req);
    if (!token) return json(res, 401, { error: "Unauthorized" });
    const items = Array.isArray(body.items) ? body.items : [];
    if (!items.length) return json(res, 400, { error: "items are required" });

    for (const item of items) {
      const amount = Number(item.amount ?? 0);
      if (!item.product_id || !Number.isFinite(amount) || amount === 0) continue;
      const { error } = await supabase.rpc("api_admin_add_storage", {
        p_token: token,
        p_product_id: item.product_id,
        p_amount: amount,
        p_purchase_price_cents: item.purchase_price_cents ?? null,
      });
      if (error) return json(res, 403, { error: error.message || "Forbidden" });
    }
    return json(res, 200, { success: true });
  }

  if (route === "admin-report-summary") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const token = extractBearerToken(req);
    if (!token) return json(res, 401, { error: "Unauthorized" });

    const start = body?.start;
    const end = body?.end;
    if (!start || !end) return json(res, 400, { error: "start and end are required" });

    try {
      const { rows, truncated } = await readRevenueRowsPaginated(supabase, token, start, end, {
        pageSize: body?.page_size ?? 1000,
        maxPages: body?.max_pages ?? 200,
      });
      const payload = buildRevenueReportPayload(rows, {
        start,
        end,
        filters: body?.filters ?? {},
        heatAggregationMode: body?.heat_aggregation_mode ?? "trimmed_mean",
        recentEventsLimit: body?.recent_events_limit ?? 100,
      });
      return json(res, 200, { ...payload, truncated });
    } catch (error) {
      return json(res, 500, {
        error: error instanceof Error ? error.message : "Report summary failed",
      });
    }
  }

  if (route === "admin-rpc") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const token = extractBearerToken(req);
    if (!token) return json(res, 401, { error: "Unauthorized" });
    const spec = ADMIN_RPC_ACTIONS[body.action];
    if (!spec) return json(res, 400, { error: "Unknown action" });
    const { data, error } = await supabase.rpc(spec.fn, spec.args(token, body.payload || {}));
    if (error) return json(res, 403, { error: error.message || "Forbidden" });
    return json(res, 200, { data: data ?? null });
  }

  if (route === "catalog-products") {
    if (req.method !== "GET") return json(res, 405, { error: "Method not allowed" });
    setCacheHeaders(res, "public, s-maxage=300, stale-while-revalidate=3600");
    const { data, error } = await supabase
      .from("products")
      .select("id,name,price,guest_price,category,active,inventoried,product_image_data_url,product_image_path,product_image_version")
      .eq("active", true)
      .order("name", { ascending: true });
    if (error) return json(res, 500, { error: error.message || "Query failed" });
    const hydratedRows = await migrateLegacyProductImages(supabase, data ?? []);
    const rows = hydratedRows.map((p) => ({
      id: p.id,
      name: p.name,
      price: p.price,
      guest_price: p.guest_price,
      category: p.category,
      active: p.active,
      inventoried: p.inventoried,
      image_url: buildProductImageUrl(supabase, p),
    }));
    return json(res, 200, rows);
  }

  if (route === "device-login") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const key = String(body.key ?? "").trim();
    if (!key) return json(res, 400, { error: "Missing key" });
    const { data, error } = await supabase.rpc("app_login_device_key", {
      p_device_key: key,
      p_ttl_days: 180,
    });
    if (error || !Array.isArray(data) || !data[0]?.token) {
      return json(res, 401, {
        error: "Unauthorized",
        details: error?.message ?? null,
        code: error?.code ?? null,
      });
    }
    return json(res, 200, {
      token: data[0].token,
      device_name: data[0].device_name,
      device_id: data[0].device_id,
    });
  }

  if (route === "device-pair") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const pairCode = String(body.pair_code ?? "").trim();
    if (!pairCode) return json(res, 400, { error: "Missing pair_code" });
    const { data, error } = await supabase.rpc("app_login_device_pair_code", {
      p_pair_code: pairCode,
      p_ttl_days: 180,
    });
    if (error || !Array.isArray(data) || !data[0]?.token) {
      return json(res, 401, {
        error: "Unauthorized",
        details: error?.message ?? null,
        code: error?.code ?? null,
      });
    }
    return json(res, 200, {
      token: data[0].token,
      device_name: data[0].device_name,
      device_id: data[0].device_id,
    });
  }

  if (route === "ping") {
    setCacheHeaders(res, "no-store, max-age=0");
    return json(res, 200, { ok: true });
  }

  if (route === "branding") {
    if (req.method !== "GET") return json(res, 405, { error: "Method not allowed" });
    setCacheHeaders(res, "public, s-maxage=3600, stale-while-revalidate=86400");
    const { data, error } = await supabase.rpc("public_get_branding_settings");
    if (error) return json(res, 500, { error: error.message || "RPC failed" });
    const row = Array.isArray(data) ? data[0] : data;
    return json(res, 200, {
      data: {
        app_title: row?.app_title ?? "ClubCashBuddy",
        logo_url: row?.logo_url ?? null,
      },
    });
  }

  const v = await verifyDevice(req);
  if (!v.ok) return json(res, v.status, { error: v.error });

  if (route === "member-pin-status") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const memberId = body.member_id;
    if (!memberId) return json(res, 400, { error: "member_id is required" });
    const { data, error } = await supabase
      .from("member_pins")
      .select("pin_plain")
      .eq("member_id", memberId)
      .maybeSingle();
    if (error) return json(res, 500, { error: error.message || "Query failed" });
    return json(res, 200, { has_pin: String(data?.pin_plain ?? "").trim().length > 0 });
  }

  if (route === "member-pin-verify") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const memberId = body.member_id;
    const pin = normalizePin(body.pin);
    if (!memberId) return json(res, 400, { error: "member_id is required" });
    if (pin.length !== 4) return json(res, 400, { error: "pin must be 4 chars" });
    const { data, error } = await supabase
      .from("member_pins")
      .select("pin_plain")
      .eq("member_id", memberId)
      .maybeSingle();
    if (error) return json(res, 500, { error: error.message || "Query failed" });
    const stored = normalizePin(data?.pin_plain);
    if (!stored) return json(res, 200, { required: false, ok: true });
    return json(res, 200, { required: true, ok: stored === pin });
  }

  if (route === "get-members") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const { data, error } = await supabase.rpc("get_members_with_last_booking");
    if (error) return json(res, 500, { error: error.message || "RPC failed" });
    const rows = Array.isArray(data) ? data : [];
    const pinMap = await loadMemberPinMap(supabase, rows.map((m) => m.id));
    const formatted = rows.map((m) => {
      const last = m.is_guest ? `Gast: ${m.lastname ?? ""}` : m.lastname ?? "";
      return {
        id: m.id,
        name: [last, m.firstname].filter(Boolean).join(", "),
        active: Boolean(m.active),
        is_guest: Boolean(m.is_guest),
        settled: Boolean(m.settled),
        last_booking_at: m.last_booking_at ?? null,
        has_pin: Boolean(pinMap.get(m.id)),
      };
    });
    return json(res, 200, formatted);
  }

  if (route === "terminal-snapshot") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    let members = [];
    let products = [];
    const { data, error } = await supabase.rpc("get_terminal_snapshot_berlin");
    if (!error && Array.isArray(data)) {
      const pinMap = await loadMemberPinMap(supabase, data.map((m) => m.id));
      members = data.map((m) => {
        const last = m.is_guest ? `Gast: ${m.lastname ?? ""}` : m.lastname ?? "";
        return {
          id: m.id,
          name: [last, m.firstname].filter(Boolean).join(", "),
          active: Boolean(m.active),
          is_guest: Boolean(m.is_guest),
          settled: Boolean(m.settled),
          last_booking_at: m.last_booking_at ?? null,
          has_booked_today: Boolean(m.has_booked_today),
          has_pin: Boolean(pinMap.get(m.id)),
        };
      });
    } else {
      const [membersRes, bookedRes] = await Promise.all([
        supabase.rpc("get_members_with_last_booking"),
        supabase.rpc("get_booked_today_berlin"),
      ]);
      if (membersRes.error) return json(res, 400, { error: membersRes.error.message || "RPC failed" });
      if (bookedRes.error) return json(res, 400, { error: bookedRes.error.message || "RPC failed" });
      const bookedSet = new Set(
        Array.isArray(bookedRes.data) ? bookedRes.data.map((r) => r.member_id) : [],
      );
      const rows = Array.isArray(membersRes.data) ? membersRes.data : [];
      const pinMap = await loadMemberPinMap(supabase, rows.map((m) => m.id));
      members = rows.map((m) => {
        const last = m.is_guest ? `Gast: ${m.lastname ?? ""}` : m.lastname ?? "";
        return {
          id: m.id,
          name: [last, m.firstname].filter(Boolean).join(", "),
          active: Boolean(m.active),
          is_guest: Boolean(m.is_guest),
          settled: Boolean(m.settled),
          last_booking_at: m.last_booking_at ?? null,
          has_booked_today: bookedSet.has(m.id),
          has_pin: Boolean(pinMap.get(m.id)),
        };
      });
    }
    const { data: productRows, error: productError } = await supabase
      .from("products")
      .select("id,name,price,guest_price,category,active,inventoried,product_image_data_url,product_image_path,product_image_version")
      .eq("active", true)
      .order("name", { ascending: true });
    if (productError) return json(res, 500, { error: productError.message || "Product query failed" });
    const hydratedProductRows = await migrateLegacyProductImages(supabase, productRows ?? []);
    products = hydratedProductRows.map((p) => ({
      id: p.id,
      name: p.name,
      price: p.price,
      guest_price: p.guest_price,
      category: p.category,
      active: p.active,
      inventoried: p.inventoried,
      image_url: buildProductImageUrl(supabase, p),
    }));
    return json(res, 200, { success: true, members, products });
  }

  if (route === "get-member-bookings") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    if (!body.member_id) return json(res, 400, { error: "Missing member_id" });
    const { data, error } = await supabase.rpc("get_member_bookings_grouped", {
      p_member_id: body.member_id,
      p_start: body.start,
      p_end: body.end,
      p_exclude_settled: Boolean(body.exclude_settled),
    });
    if (error) return json(res, 400, { error: error.message || "RPC failed" });
    return json(res, 200, { success: true, data: data ?? [] });
  }

  if (route === "get-today-transactions") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    if (!body.member_id) return json(res, 400, { error: "Missing member_id" });
    const rawLimit = Number(body.limit ?? 200);
    const limit = Number.isFinite(rawLimit)
      ? Math.max(1, Math.min(1000, Math.floor(rawLimit)))
      : 200;
    let { data, error } = await supabase.rpc("get_today_transactions_berlin", {
      p_member: body.member_id,
      p_limit: limit,
    });
    if (error && String(error.message || "").toLowerCase().includes("p_limit")) {
      const fallback = await supabase.rpc("get_today_transactions_berlin", {
        p_member: body.member_id,
      });
      data = fallback.data;
      error = fallback.error;
    }
    if (error) return json(res, 400, { error: error.message || "RPC failed" });
    return json(res, 200, { success: true, data: data ?? [] });
  }

  if (route === "get-booked-today-members") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const { data, error } = await supabase.rpc("get_booked_today_berlin");
    if (error) return json(res, 400, { error: error.message || "RPC failed" });
    const ids = Array.isArray(data) ? data.map((r) => r.member_id) : [];
    return json(res, 200, { success: true, member_ids: ids });
  }

  if (route === "book-transaction") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const { data, error } = await supabase.rpc("book_transaction", {
      member_id: body.member_id ?? null,
      product_id: body.product_id ?? null,
      free_amount: body.free_amount ?? null,
      p_note: body.p_note ?? null,
      client_tx_id_param: body.client_tx_id_param ?? null,
      p_transaction_type: body.p_transaction_type ?? null,
    });
    if (error) return json(res, 400, { error: error.message || "Booking failed" });
    const traceError = await stampBookingDeviceTrace(supabase, data, v.deviceId);
    if (traceError) return json(res, 500, { error: traceError.message || "Trace update failed" });
    return json(res, 200, { success: true, data });
  }

  if (route === "book-transactions-batch") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const items = Array.isArray(body.items) ? body.items : [];
    if (!items.length) return json(res, 400, { error: "Missing items" });

    const maxItems = 100;
    const batch = items.slice(0, maxItems);
    const results = [];

    for (const item of batch) {
      const queueId = Number(item?.queue_id ?? 0);
      const clientTxId = item?.client_tx_id_param ?? null;
      try {
        const { data, error } = await supabase.rpc("book_transaction", {
          member_id: item?.member_id ?? null,
          product_id: item?.product_id ?? null,
          free_amount: item?.free_amount ?? null,
          p_note: item?.p_note ?? null,
          client_tx_id_param: clientTxId,
          p_transaction_type: item?.p_transaction_type ?? null,
        });
        if (error) {
          results.push({
            queue_id: Number.isFinite(queueId) && queueId > 0 ? queueId : null,
            client_tx_id_param: clientTxId,
            success: false,
            error: error.message || "Booking failed",
          });
          continue;
        }
        const traceError = await stampBookingDeviceTrace(supabase, data, v.deviceId);
        if (traceError) {
          results.push({
            queue_id: Number.isFinite(queueId) && queueId > 0 ? queueId : null,
            client_tx_id_param: clientTxId,
            success: false,
            error: traceError.message || "Trace update failed",
          });
          continue;
        }
        results.push({
          queue_id: Number.isFinite(queueId) && queueId > 0 ? queueId : null,
          client_tx_id_param: clientTxId,
          success: true,
          data: data ?? null,
        });
      } catch (err) {
        results.push({
          queue_id: Number.isFinite(queueId) && queueId > 0 ? queueId : null,
          client_tx_id_param: clientTxId,
          success: false,
          error: err instanceof Error ? err.message : "Booking failed",
        });
      }
    }

    return json(res, 200, { success: true, results });
  }

  if (route === "cancel-transaction") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const { data, error } = await supabase.rpc("cancel_transaction", {
      cancel_tx_id: body.cancel_tx_id ?? null,
      member_id: body.member_id ?? null,
      product_id: body.product_id ?? null,
      note: body.note ?? null,
      p_device_id: v.deviceId ?? null,
    });
    if (error) return json(res, 400, { error: error.message || "Cancellation failed" });
    return json(res, 200, { success: true, cancelled: data ?? body.cancel_tx_id ?? null });
  }

  if (route === "get-stock-info") {
    if (req.method !== "GET") return json(res, 405, { error: "Method not allowed" });
    const { data, error } = await supabase
      .from("products")
      .select("id, warehouse_stock, fridge_stock, last_restocked_at, inventoried")
      .eq("inventoried", true);
    if (error) return json(res, 500, { error: error.message || "Query failed" });
    const rows = (data ?? []).map((p) => ({
      product_id: p.id,
      warehouse_stock: Number(p.warehouse_stock ?? 0),
      fridge_stock: Number(p.fridge_stock ?? 0),
      current_stock: Number(p.warehouse_stock ?? 0) + Number(p.fridge_stock ?? 0),
      last_refill: p.last_restocked_at ?? null,
    }));
    return json(res, 200, rows);
  }

  if (route === "adjust-stock-batch") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const items = Array.isArray(body.items) ? body.items : [];
    const memberId = body.member_id ?? null;
    if (!memberId) return json(res, 400, { error: "member_id is required" });
    if (!items.length) return json(res, 400, { error: "Empty items" });

    const { data: member, error: memberError } = await supabase
      .from("members")
      .select("id, active, is_guest, firstname, lastname")
      .eq("id", memberId)
      .maybeSingle();
    if (memberError) return json(res, 500, { error: memberError.message || "Member lookup failed" });
    if (!member || !member.active || member.is_guest) return json(res, 400, { error: "Invalid refiller member" });

    const memberName = `${member.firstname ?? ""} ${member.lastname ?? ""}`.trim() || null;
    const inserts = items
      .map((i) => ({
        product_id: i.product_id,
        quantity: Number(i.quantity),
        device_id: v.deviceId,
        member_id: member.id,
        member_name_snapshot: memberName,
      }))
      .filter((r) => r.product_id && Number.isFinite(r.quantity) && r.quantity > 0);

    if (!inserts.length) return json(res, 400, { error: "No valid items" });
    const { error: insertError } = await supabase.from("stock_adjustments").insert(inserts);
    if (insertError) return json(res, 500, { error: insertError.message || "Insert failed" });
    return json(res, 200, { success: true, count: inserts.length });
  }

  if (route === "device-add-guest") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const firstname = String(body.firstname ?? "").trim();
    const lastname = String(body.lastname ?? "").trim();
    if (!firstname && !lastname) return json(res, 400, { error: "Missing guest name" });
    const { data, error } = await supabase
      .from("members")
      .insert({ firstname, lastname, is_guest: true, active: true })
      .select()
      .single();
    if (error) return json(res, 500, { error: error.message || "Insert failed" });
    return json(res, 201, { success: true, data });
  }

  if (route === "device-settle-guest") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    if (!body.member_id) return json(res, 400, { error: "Missing member_id" });
    const { error } = await supabase
      .from("members")
      .update({ settled: true, active: false })
      .eq("id", body.member_id)
      .eq("is_guest", true);
    if (error) return json(res, 500, { error: error.message || "Update failed" });
    return json(res, 200, { success: true });
  }

  if (route === "device-settle-guest-partial") {
    if (req.method !== "POST") return json(res, 405, { error: "Method not allowed" });
    const memberId = body.member_id;
    const transactionIds = Array.isArray(body.transaction_ids) ? body.transaction_ids : [];
    if (!memberId || !transactionIds.length) return json(res, 400, { error: "Missing parameters" });

    const { error } = await supabase
      .from("transactions")
      .update({ settled_at: new Date().toISOString() })
      .in("id", transactionIds)
      .eq("member_id", memberId);
    if (error) return json(res, 500, { error: error.message || "Update failed" });

    const { count, error: countError } = await supabase
      .from("transactions")
      .select("id", { count: "exact", head: true })
      .eq("member_id", memberId)
      .is("settled_at", null);
    if (countError) return json(res, 500, { error: countError.message || "Count failed" });

    return json(res, 200, { success: true, remaining_open_transactions: count ?? 0 });
  }

  return json(res, 404, { error: "Unknown route" });
}

export default async function handler(req, res) {
  const raw = req.query.route;
  const route = Array.isArray(raw) ? raw[0] : raw;
  if (!route) return json(res, 400, { error: "Missing route" });

  try {
    return await handleRoute(route, req, res);
  } catch (err) {
    console.error("[api/app]", route, err);
    return json(res, 500, { error: "Internal Server Error" });
  }
}

