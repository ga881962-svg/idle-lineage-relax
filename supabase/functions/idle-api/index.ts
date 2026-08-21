import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
  "Content-Type": "application/json; charset=utf-8",
};

type Input = Record<string, unknown> & { action?: string };
const reply = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: corsHeaders });
const isRecord = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
const int = (value: unknown, fallback = 0) => {
  const number = Math.floor(Number(value));
  return Number.isFinite(number) ? number : fallback;
};
const uuid = (value: unknown) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value ?? ""));
const jsonClone = <T>(value: T): T => JSON.parse(JSON.stringify(value));

function nameOf(value: unknown) {
  const name = String(value ?? "").trim();
  return name.length >= 1 && name.length <= 20 ? name : null;
}
function accountEmail(value: unknown) {
  const account = String(value ?? "").trim().toLowerCase();
  return /^[a-z0-9_]{3,20}$/.test(account) ? `${account}@players.idle-lineage.local` : null;
}
function inventoryCount(value: unknown) {
  return Array.isArray(value) ? value.reduce((sum, item) => sum + (isRecord(item) ? Math.max(0, Math.min(1000000, int(item.cnt))) : 0), 0) : 0;
}
function duplicateUids(value: unknown) {
  if (!Array.isArray(value)) return false;
  const seen = new Set<string>();
  return value.some((item) => {
    const id = isRecord(item) ? String(item.uid || "") : "";
    if (!id) return false;
    if (seen.has(id)) return true;
    seen.add(id);
    return false;
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return reply({ error: "POST_ONLY" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !service) return reply({ error: "SERVER_CONFIGURATION_ERROR" }, 503);

  const authorization = request.headers.get("Authorization") || "";
  const auth = createClient(url, anon, { global: { headers: { Authorization: authorization } } });
  const { data: authData, error: authError } = await auth.auth.getUser();
  if (authError || !authData.user) return reply({ error: "AUTH_REQUIRED" }, 401);
  const user = authData.user;
  let input: Input;
  try { input = await request.json(); } catch { return reply({ error: "INVALID_JSON" }, 400); }
  const admin = createClient(url, service, { auth: { persistSession: false } });
  const nowIso = new Date().toISOString();

  const getRole = async () => {
    const { data } = await admin.from("player_profiles").select("role").eq("id", user.id).maybeSingle();
    return data?.role === "admin" || data?.role === "gm" ? data.role : null;
  };
  const sessionOk = async () => {
    const token = String(input.sessionToken || "");
    if (!uuid(token)) return false;
    const expiresAt = new Date(Date.now() + 15 * 60 * 1000).toISOString();
    const { data, error } = await admin.from("game_account_sessions")
      .update({ last_seen_at: nowIso, expires_at: expiresAt })
      .eq("user_id", user.id)
      .eq("session_token", token)
      .is("invalidated_at", null)
      .gt("expires_at", nowIso)
      .select("session_token")
      .maybeSingle();
    return !error && !!data;
  };
  const requireSession = async () => (await sessionOk()) ? null : reply({ error: "SESSION_REPLACED" }, 409);
  const ownCharacter = async (characterId: unknown) => {
    const { data } = await admin.from("player_characters").select("id,user_id,name").eq("id", String(characterId || "")).eq("user_id", user.id).maybeSingle();
    return data;
  };
  const findAccount = async (account: unknown) => {
    const email = accountEmail(account);
    if (!email) return null;
    const { data, error } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
    if (error) throw error;
    return (data.users || []).find((candidate) => String(candidate.email || "").toLowerCase() === email) || null;
  };
  const getCheckpoint = async (characterId: string) =>
    await admin.from("character_checkpoints").select("revision,state,saved_at").eq("character_id", characterId).maybeSingle();
  if (input.action === "session.open") {
    if (!uuid(input.deviceId)) return reply({ error: "INVALID_DEVICE" }, 400);
    const deviceId = String(input.deviceId);
    // Do not limit a household/network to one account. Exclusivity is per
    // authenticated account only. A repeated open from the same browser device
    // must retain its still-valid token, otherwise a late heartbeat from the
    // previous page lifecycle would incorrectly kick that same device out.
    const ipHash = null;
    const expiresAt = new Date(Date.now() + 15 * 60 * 1000).toISOString();
    const { data: existing, error: existingError } = await admin.from("game_account_sessions")
      .select("session_token")
      .eq("user_id", user.id)
      .eq("device_id", deviceId)
      .is("invalidated_at", null)
      .gt("expires_at", nowIso)
      .maybeSingle();
    if (existingError) return reply({ error: "SESSION_OPEN_FAILED" }, 500);
    if (existing?.session_token) {
      const { data: refreshed, error: refreshError } = await admin.from("game_account_sessions")
        .update({ last_seen_at: nowIso, expires_at: expiresAt })
        .eq("user_id", user.id)
        .eq("device_id", deviceId)
        .eq("session_token", existing.session_token)
        .is("invalidated_at", null)
        .select("session_token")
        .maybeSingle();
      if (refreshError || !refreshed?.session_token) return reply({ error: "SESSION_OPEN_FAILED" }, 500);
      return reply({ sessionToken: refreshed.session_token, expiresInSeconds: 900, reused: true });
    }
    // A different device (or an expired/invalidated old session) takes over
    // this account's single active session.
    const sessionToken = crypto.randomUUID();
    const { error } = await admin.from("game_account_sessions").upsert({ user_id: user.id, session_token: sessionToken, device_id: deviceId, ip_hash: ipHash, issued_at: nowIso, last_seen_at: nowIso, expires_at: expiresAt, invalidated_at: null }, { onConflict: "user_id" });
    return error ? reply({ error: "SESSION_OPEN_FAILED" }, 500) : reply({ sessionToken, expiresInSeconds: 900 });
  }
  if (input.action === "session.heartbeat") return (await sessionOk()) ? reply({ ok: true }) : reply({ error: "SESSION_REPLACED" }, 409);
  if (input.action === "session.close") {
    const denied = await requireSession(); if (denied) return denied;
    const { data: closed } = await admin.from("game_account_sessions")
      .update({ invalidated_at: nowIso })
      .eq("user_id", user.id).eq("session_token", String(input.sessionToken))
      .is("invalidated_at", null)
      .select("user_id")
      .maybeSingle();
    return reply({ ok: true });
  }

  if (["characters.list", "characters.create"].includes(String(input.action))) {
    const denied = await requireSession(); if (denied) return denied;
  }
  if (input.action === "characters.list") {
    const { data, error } = await admin.from("player_characters").select("id,slot,name,class_id,level,created_at,updated_at").eq("user_id", user.id).order("slot", { ascending: true });
    if (error) return reply({ error: "CHARACTER_LIST_FAILED" }, 500);
    const characters = data || [];
    const ids = characters.map((character) => character.id);
    const { data: checkpoints, error: checkpointError } = ids.length
      ? await admin.from("character_checkpoints").select("character_id,state").in("character_id", ids)
      : { data: [], error: null };
    if (checkpointError) return reply({ error: "CHARACTER_LIST_CHECKPOINT_FAILED" }, 500);
    const byCharacter = new Map((checkpoints || []).map((checkpoint) => [checkpoint.character_id, checkpoint.state]));
    return reply({ characters: characters.map((character) => {
      const state = byCharacter.get(character.id);
      const savedPlayer = isRecord(state) && isRecord(state.p) ? state.p : null;
      const savedLevel = savedPlayer ? int(savedPlayer.lv ?? savedPlayer.level, 0) : 0;
      return { ...character, level: savedLevel > 0 ? savedLevel : character.level };
    }) });
  }
  if (input.action === "characters.create") {
    const slot = int(input.slot, -1); const name = nameOf(input.name); const classId = String(input.classId || "");
    const classes = new Set(["prince","knight","elf","wizard","darkelf","dragonknight","illusionist","warrior"]);
    if (slot < 1 || slot > 8 || !name || !classes.has(classId)) return reply({ error: "INVALID_CHARACTER" }, 400);
    const { data: exists } = await admin.from("player_characters").select("id").eq("user_id", user.id).eq("slot", slot).maybeSingle();
    if (exists) return reply({ error: "SLOT_OCCUPIED" }, 409);
    const { data, error } = await admin.from("player_characters").insert({ user_id: user.id, slot, name, class_id: classId, level: 1, state: {} }).select("id,slot,name,class_id,level,created_at,updated_at").single();
    return error ? reply({ error: "CHARACTER_CREATE_FAILED" }, 500) : reply({ character: data }, 201);
  }

  const protectedActions = new Set(["gm.status","checkpoint.read","checkpoint.write","world.send","character.rename","leaderboard.online","sponsor.pass.status","sponsor.pass.purchase","offline.pass.purchase","offline.status","offline.arm","offline.disarm","offline.settle","offline.ack","offline.return.check","offline.return","map.entry","gm.wallet.grant","gm.player.wallet.grant","gm.player.inventory.grant","gm.character.apply","gm.inventory.grant","gm.skills.learn","gm.collections.complete"]);
  if (protectedActions.has(String(input.action))) { const denied = await requireSession(); if (denied) return denied; }
  if (input.action === "gm.status") { const role = await getRole(); return reply({ allowed: !!role, role: role || "player" }); }

  if (input.action === "character.rename") {
    const character = await ownCharacter(input.characterId);
    const nextName = nameOf(input.name);
    if (!character) return reply({ error: "CHARACTER_NOT_FOUND" }, 404);
    if (!nextName || !uuid(input.requestId)) return reply({ error: "INVALID_CHARACTER_NAME" }, 400);
    const { data, error } = await auth.rpc("character_rename", {
      p_session_token: String(input.sessionToken), p_character_id: character.id,
      p_new_name: nextName, p_request_id: String(input.requestId),
    });
    if (error) {
      const detail = `${error.message || ""} ${error.details || ""}`;
      if (/CHARACTER_NAME_TAKEN/i.test(detail)) return reply({ error: "CHARACTER_NAME_TAKEN" }, 409);
      if (/CHARACTER_NAME_UNCHANGED/i.test(detail)) return reply({ error: "CHARACTER_NAME_UNCHANGED" }, 409);
      if (/INVALID_CHARACTER_NAME/i.test(detail)) return reply({ error: "INVALID_CHARACTER_NAME" }, 400);
      if (/INSUFFICIENT_SPONSOR_DIAMONDS/i.test(detail)) return reply({ error: "INSUFFICIENT_SPONSOR_DIAMONDS" }, 409);
      if (/REQUEST_ID_PAYLOAD_MISMATCH/i.test(detail)) return reply({ error: "REQUEST_ID_PAYLOAD_MISMATCH" }, 409);
      if (/SESSION_(REPLACED|REQUIRED|EXPIRED)|INVALID_SESSION/i.test(detail)) return reply({ error: "SESSION_REPLACED" }, 409);
      return reply({ error: "CHARACTER_RENAME_FAILED" }, 500);
    }
    return reply(isRecord(data) ? data : {});
  }

  if (input.action === "leaderboard.online") {
    const character = await ownCharacter(input.characterId);
    if (!character) return reply({ error: "CHARACTER_NOT_FOUND" }, 404);
    const { data, error } = await auth.rpc("online_leaderboard", { p_session_token: String(input.sessionToken) });
    return error ? reply({ error: "LEADERBOARD_READ_FAILED" }, 500) : reply(isRecord(data) ? data : {});
  }

  // Sponsor passes are a server purchase: the browser only asks for a status
  // or submits an idempotent request id. It never supplies a price, balance or
  // expiry timestamp.
  if (String(input.action).startsWith("sponsor.")) {
    const character = await ownCharacter(input.characterId);
    if (!character) return reply({ error: "CHARACTER_NOT_FOUND" }, 404);
    if (input.action === "sponsor.pass.status") {
      const { data, error } = await auth.rpc("sponsor_pass_status", {
        p_session_token: String(input.sessionToken), p_character_id: character.id,
      });
      return error ? reply({ error: "SPONSOR_STATUS_FAILED" }, 500) : reply(isRecord(data) ? data : {});
    }
    if (input.action === "sponsor.pass.purchase") {
      const kind = String(input.kind || "");
      if (!uuid(input.requestId) || !["exp", "gold", "drop"].includes(kind)) return reply({ error: "INVALID_SPONSOR_PURCHASE" }, 400);
      const { data, error } = await auth.rpc("sponsor_pass_purchase", {
        p_session_token: String(input.sessionToken), p_character_id: character.id,
        p_pass_kind: kind, p_request_id: String(input.requestId),
      });
      if (error) {
        const detail = `${error.message || ""} ${error.details || ""}`;
        if (/INSUFFICIENT_SPONSOR_DIAMONDS/i.test(detail)) return reply({ error: "INSUFFICIENT_SPONSOR_DIAMONDS" }, 409);
        if (/REQUEST_ID_PAYLOAD_MISMATCH/i.test(detail)) return reply({ error: "REQUEST_ID_PAYLOAD_MISMATCH" }, 409);
        if (/SESSION_(REPLACED|REQUIRED|EXPIRED)|INVALID_SESSION/i.test(detail)) return reply({ error: "SESSION_REPLACED" }, 409);
        return reply({ error: "SPONSOR_PURCHASE_FAILED" }, 500);
      }
      return reply(isRecord(data) ? data : {});
    }
  }

  // Offline hunting and map return are RPC-only. No reward, duration, map
  // eligibility or expiry input is accepted from the browser.
  if (String(input.action).startsWith("offline.") || input.action === "map.entry") {
    const character = await ownCharacter(input.characterId);
    if (!character) return reply({ error: "CHARACTER_NOT_FOUND" }, 404);
    const rpc = async (name: string, args: Record<string, unknown>) => {
      const { data, error } = await auth.rpc(name, args);
      if (!error) {
        const result = isRecord(data) ? data : {};
        if (result.rejected === true && result.error === "OFFLINE_SNAPSHOT_REJECTED") return reply(result, 409);
        return reply(result);
      }
      const detail = `${error.message || ""} ${error.details || ""}`;
      const known = ["CHECKPOINT_CONFLICT","OFFLINE_PASS_REQUIRED","OFFLINE_CATALOG_CHANGED","OFFLINE_SNAPSHOT_REJECTED","MAP_UNAVAILABLE","MISSING_KEY","MISSING_SCROLL","SHIP_REQUIRED","LEVEL_REQUIRED","QUEST_REQUIRED","PASS_REQUIRED","PVP_RETURN_DISABLED","REQUEST_ID_PAYLOAD_MISMATCH","INSUFFICIENT_SPONSOR_DIAMONDS","SESSION_REPLACED"];
      const errorCode = known.find((code) => detail.includes(code)) || "OFFLINE_ACTION_FAILED";
      return reply({ error: errorCode, detail }, errorCode === "CHECKPOINT_CONFLICT" || errorCode === "REQUEST_ID_PAYLOAD_MISMATCH" ? 409 : 400);
    };
    const token = String(input.sessionToken || "");
    if (input.action === "offline.pass.purchase") {
      if (!uuid(input.requestId)) return reply({ error: "INVALID_OFFLINE_PASS_PURCHASE" }, 400);
      return rpc("offline_pass_purchase", { p_session_token: token, p_character_id: character.id, p_request_id: String(input.requestId) });
    }
    if (input.action === "offline.status") return rpc("offline_hunt_status", { p_session_token: token, p_character_id: character.id });
    if (input.action === "offline.arm") {
      if (!uuid(input.requestId) || !String(input.mapId || "")) return reply({ error: "INVALID_OFFLINE_ARM" }, 400);
      if (!isRecord(input.recentRate)) return reply({ error: "INVALID_OFFLINE_RATE" }, 400);
      return rpc("offline_hunt_arm", { p_session_token: token, p_character_id: character.id, p_map_id: String(input.mapId), p_recent_rate: input.recentRate, p_request_id: String(input.requestId) });
    }
    if (input.action === "offline.disarm") return rpc("offline_hunt_disarm", { p_session_token: token, p_character_id: character.id, p_reason: String(input.reason || "not_in_combat") });
    if (input.action === "offline.settle") {
      if (!uuid(input.requestId)) return reply({ error: "INVALID_SETTLEMENT_REQUEST" }, 400);
      return rpc("offline_hunt_settle", { p_session_token: token, p_character_id: character.id, p_request_id: String(input.requestId) });
    }
    if (input.action === "offline.ack") {
      if (!uuid(input.settlementId)) return reply({ error: "INVALID_SETTLEMENT_ACK" }, 400);
      return rpc("offline_hunt_ack", { p_session_token: token, p_character_id: character.id, p_settlement_id: String(input.settlementId) });
    }
    if (input.action === "offline.return.check") return rpc("offline_hunt_return_check", { p_session_token: token, p_character_id: character.id });
    if (input.action === "offline.return" || input.action === "map.entry") {
      const mapId = String(input.mapId || "");
      const context = input.action === "offline.return" ? "offline_return" : String(input.context || "normal_enter");
      if (!mapId || !uuid(input.requestId) || int(input.revision, -1) < 0) return reply({ error: "INVALID_MAP_ENTRY" }, 400);
      return rpc("map_entry_validate_and_apply", { p_session_token: token, p_character_id: character.id, p_map_id: mapId, p_context: context, p_request_id: String(input.requestId), p_expected_revision: int(input.revision) });
    }
    return reply({ error: "OFFLINE_ACTION_NOT_AVAILABLE" }, 400);
  }

  if (input.action === "checkpoint.read") {
    const character = await ownCharacter(input.characterId); if (!character) return reply({ error: "CHARACTER_NOT_FOUND" }, 404);
    const { data, error } = await getCheckpoint(character.id);
    return error ? reply({ error: "CHECKPOINT_READ_FAILED" }, 500) : reply({ checkpoint: data || null });
  }
  if (input.action === "checkpoint.write") {
    const character = await ownCharacter(input.characterId);
    const givenRevision = int(input.revision, -1);
    if (!character || givenRevision < 0 || !uuid(input.requestId) || !isRecord(input.state)) return reply({ error: "INVALID_CHECKPOINT" }, 400);
    const state = jsonClone(input.state); const p = isRecord(state.p) ? state.p : null;
    if (p && duplicateUids(p.inv)) return reply({ error: "DUPLICATE_ITEM_UID" }, 409);
    const bytes = JSON.stringify(state).length;
    if (bytes > 1500000) return reply({ error: "CHECKPOINT_TOO_LARGE" }, 413);
    const { data: previous, error: previousError } = await getCheckpoint(character.id);
    if (previousError) return reply({ error: "CHECKPOINT_READ_FAILED" }, 500);
    const revision = int(previous?.revision);
    if (previous && givenRevision !== revision) return reply({ error: "CHECKPOINT_CONFLICT", revision }, 409);
    if (previous?.saved_at && Date.now() - Date.parse(String(previous.saved_at)) < 2500) return reply({ error: "SAVE_TOO_FAST" }, 429);
    const oldP = isRecord(previous?.state) && isRecord((previous.state as Record<string, unknown>).p) ? (previous.state as Record<string, unknown>).p as Record<string, unknown> : null;
    if (oldP && p) {
      const elapsed = Math.max(1, Math.min(86400, Math.floor((Date.now() - Date.parse(String(previous?.saved_at || nowIso))) / 1000)));
      const goldGain = Math.max(0, int(p.gold) - int(oldP.gold));
      const expGain = Math.max(0, int(p.exp) - int(oldP.exp));
      const itemGain = Math.max(0, inventoryCount(p.inv) - inventoryCount(oldP.inv));
      if (goldGain > elapsed * 2000000 || expGain > elapsed * 5000000 || itemGain > elapsed * 200) return reply({ error: "SAVE_LIMIT_EXCEEDED" }, 409);
    }
    // The SQL RPC re-validates the authenticated user, active session token and
    // revision while holding the checkpoint row lock. This prevents a replaced
    // device from committing a stale final save over the new device.
    const { data: committed, error: commitError } = await auth.rpc("secure_save_character_checkpoint", {
      p_session_token: String(input.sessionToken),
      p_character_id: character.id,
      p_revision: givenRevision,
      p_state: state,
      p_request_id: String(input.requestId),
    });
    if (commitError) {
      const detail = `${commitError.message || ""} ${commitError.details || ""}`;
      if (/SESSION_(REPLACED|REQUIRED|EXPIRED)|INVALID_SESSION/i.test(detail)) return reply({ error: "SESSION_REPLACED" }, 409);
      const conflict = detail.match(/CHECKPOINT_CONFLICT:?(\d+)?/i);
      if (conflict) return reply({ error: "CHECKPOINT_CONFLICT", revision: int(conflict[1], revision) }, 409);
      return reply({ error: "CHECKPOINT_WRITE_FAILED" }, 500);
    }
    const nextRevision = int((committed as Record<string, unknown> | null)?.revision, revision + 1);
    return reply({ revision: nextRevision });
  }

  if (input.action === "world.send") {
    const character = await ownCharacter(input.characterId);
    const content = String(input.content || "").trim();
    if (!character) return reply({ error: "CHARACTER_NOT_FOUND" }, 404);
    if (content.length < 1 || content.length > 120) return reply({ error: "INVALID_CHAT_MESSAGE" }, 400);
    // The database stores only a short per-account cooldown timestamp, never
    // message text. The RPC updates it atomically to prevent rapid retries.
    // Use the caller-scoped client here. The RPC deliberately checks auth.uid()
    // so a service-role call cannot impersonate a player when consuming a chat
    // cooldown slot.
    const { data: allowed, error: cooldownError } = await auth.rpc("consume_world_chat_cooldown", { p_user_id: user.id });
    if (cooldownError) return reply({ error: "CHAT_COOLDOWN_CHECK_FAILED" }, 500);
    if (!allowed) return reply({ error: "CHAT_COOLDOWN" }, 429);
    const event = { id: crypto.randomUUID(), characterId:character.id, name:character.name, content, sentAt:nowIso };
    const broadcast = await fetch(`${url}/realtime/v1/api/broadcast/world%3Aglobal/events/world_message?private=true`, {
      method: "POST",
      headers: { apikey:service, Authorization:`Bearer ${service}`, "Content-Type":"application/json" },
      body: JSON.stringify(event),
    });
    if (!broadcast.ok) return reply({ error: "CHAT_BROADCAST_FAILED" }, 502);
    return reply({ ok:true, messageId:event.id });
  }

  const requireGm = async () => (await getRole()) ? null : reply({ error: "GM_REQUIRED" }, 403);
  const grantWallet = async (targetUserId: string, amount: unknown) => {
    const add = int(amount, -1); if (add < 1 || add > 1000000000) return { error: "INVALID_AMOUNT" };
    const { data: wallet } = await admin.from("account_wallets").select("sponsor_diamonds").eq("user_id", targetUserId).maybeSingle();
    const balance = Math.max(0, int(wallet?.sponsor_diamonds)) + add;
    const { error } = await admin.from("account_wallets").upsert({ user_id: targetUserId, sponsor_diamonds: balance, updated_at: nowIso }, { onConflict: "user_id" });
    return error ? { error: "WALLET_WRITE_FAILED" } : { balance };
  };
  if (input.action === "gm.wallet.grant") {
    const denied = await requireGm(); if (denied) return denied;
    const { data: character } = await admin.from("player_characters").select("id,user_id").eq("id", String(input.characterId || "")).maybeSingle();
    if (!character) return reply({ error: "CHARACTER_NOT_FOUND" }, 404);
    const result = await grantWallet(character.user_id, input.amount); return result.error ? reply(result, 400) : reply(result);
  }
  if (input.action === "gm.player.wallet.grant") {
    const denied = await requireGm(); if (denied) return denied;
    const target = await findAccount(input.targetAccount); if (!target) return reply({ error: "TARGET_ACCOUNT_NOT_FOUND" }, 404);
    const result = await grantWallet(target.id, input.amount); return result.error ? reply(result, 400) : reply({ ...result, targetAccount: String(input.targetAccount || "") });
  }

  if (["gm.character.apply","gm.inventory.grant","gm.player.inventory.grant","gm.skills.learn","gm.collections.complete"].includes(String(input.action))) {
    const denied = await requireGm(); if (denied) return denied;
    let characterId = String(input.characterId || "");
    if (input.action === "gm.player.inventory.grant") {
      const target = await findAccount(input.targetAccount); const targetName = nameOf(input.targetCharacterName);
      if (!target || !targetName) return reply({ error: "TARGET_CHARACTER_NOT_FOUND" }, 404);
      const { data } = await admin.from("player_characters").select("id").eq("user_id", target.id).eq("name", targetName).maybeSingle();
      if (!data) return reply({ error: "TARGET_CHARACTER_NOT_FOUND" }, 404); characterId = data.id;
    }
    const { data: character } = await admin.from("player_characters").select("id,name").eq("id", characterId).maybeSingle();
    if (!character) return reply({ error: "CHARACTER_NOT_FOUND" }, 404);
    const { data: checkpoint } = await getCheckpoint(character.id);
    if (!checkpoint || !isRecord(checkpoint.state) || !isRecord(checkpoint.state.p)) return reply({ error: "CHARACTER_NEEDS_FIRST_SAVE" }, 409);
    const state = jsonClone(checkpoint.state) as Record<string, unknown>; const p = state.p as Record<string, unknown>;
    if (input.action === "gm.character.apply") {
      if (!isRecord(input.base) || int(input.level, -1) < 1 || int(input.level) > 99 || int(input.gold, -1) < 0) return reply({ error: "INVALID_CHARACTER_VALUES" }, 400);
      const base: Record<string, number> = {}; for (const key of ["str","dex","con","int","wis","cha"]) { const value = int(input.base[key], -1); if (value < 0 || value > 99) return reply({ error: "INVALID_STATS" }, 400); base[key] = value; }
      p.gold = int(input.gold); p.lv = int(input.level); p.exp = 0; p.base = base;
    }
    if (input.action === "gm.inventory.grant" || input.action === "gm.player.inventory.grant") {
      if (!isRecord(input.item)) return reply({ error: "INVALID_ITEM" }, 400);
      const id = String(input.item.id || "").trim(); const cnt = int(input.item.cnt, -1); const en = int(input.item.en, 0);
      if (!id || id.length > 100 || cnt < 1 || cnt > 99999 || en < 0 || en > 20) return reply({ error: "INVALID_ITEM" }, 400);
      const inv = Array.isArray(p.inv) ? p.inv : []; inv.push({ id, cnt, en, bless: !!input.item.bless, anc: !!input.item.anc, attr: !!input.item.attr, seteff: !!input.item.seteff, lock: false, junk: false, uid: `gm-${crypto.randomUUID()}` }); p.inv = inv;
    }
    if (input.action === "gm.skills.learn") { if (!Array.isArray(input.skills)) return reply({ error: "INVALID_SKILLS" }, 400); p.skills = [...new Set(input.skills.filter((skill) => typeof skill === "string" && skill.length <= 100))]; }
    if (input.action === "gm.collections.complete") { if (!isRecord(input.collections)) return reply({ error: "INVALID_COLLECTIONS" }, 400); for (const key of ["equipDex","miscDex","cardDex","relicDex"]) if (isRecord(input.collections[key])) p[key] = input.collections[key]; }
    const nextRevision = int(checkpoint.revision) + 1;
    const { error } = await admin.from("character_checkpoints").upsert({ character_id: character.id, revision: nextRevision, state, saved_at: nowIso }, { onConflict: "character_id" });
    if (error) return reply({ error: "GM_WRITE_FAILED" }, 500);
    await admin.from("gm_audit_log").insert({ actor_id: user.id, character_id: character.id, action: String(input.action), details: { character_name: character.name } });
    return reply({ revision: nextRevision });
  }
  return reply({ error: "UNKNOWN_ACTION" }, 400);
});
