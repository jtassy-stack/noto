// asc.mjs — THE App Store Connect API client for every jtassy iOS repo.
//
// Zero dependencies: Node crypto signs the ES256 JWT, global fetch calls the
// REST API. This file replaces the five hand-rolled copies that used to live
// in treve (ci_scripts/assign_to_festival_group.mjs, scripts/testflight-*.mjs),
// keskonfe (scripts/testflight-release.mjs, Fastfile asc_get/post/patch) and
// the testflight-feedback plugin. Any script that mints its own ASC JWT is a
// migration candidate — see core/RULES.md rule 10.
//
// ECDSA gotcha (the reason this must not be re-derived from scratch): ASC
// rejects DER-encoded signatures with HTTP 401. Node's
// `createSign(...).sign({ dsaEncoding: "ieee-p1363" })` is the right
// primitive — the `openssl dgst` CLI defaults to DER and silently breaks.

import { readFileSync, existsSync } from "node:fs";
import { createSign } from "node:crypto";
import { join } from "node:path";

const API = "https://api.appstoreconnect.apple.com";

// ── Env loading ─────────────────────────────────────────────────────────
// process.env wins (CI); then project dotenvs, first hit per key wins.
// scripts/.env.testflight is the legacy location (treve + testflight-feedback
// already share it) — kept as a fallback so migration is zero-friction.
export function loadAscEnv(cwd = process.cwd()) {
  const env = { ...process.env };
  const candidates = [
    join(cwd, ".claude/asc/.env"),
    join(cwd, "scripts/.env.testflight"),
  ];
  for (const path of candidates) {
    if (!existsSync(path)) continue;
    for (const line of readFileSync(path, "utf8").split("\n")) {
      const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/);
      if (m && !env[m[1]]) env[m[1]] = m[2];
    }
  }
  return env;
}

// Reads .claude/asc/config.json (committed, non-secret per-project config).
export function loadAscConfig(cwd = process.cwd()) {
  const path = join(cwd, ".claude/asc/config.json");
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, "utf8"));
}

// ── Client ──────────────────────────────────────────────────────────────
// createClient({ keyId, issuerId, keyPath }) or ({ keyId, issuerId, key }).
export function createClient({ keyId, issuerId, keyPath, key }) {
  if (!keyId || !issuerId || !(keyPath || key)) {
    throw new Error("createClient needs keyId, issuerId and keyPath (or key PEM)");
  }
  const pem = key ?? readFileSync(keyPath, "utf8");

  // The ES256 JWT maxes out at 20 min, but callers may poll processing for
  // 25+ and walk dozens of builds — re-mint lazily before it goes stale.
  let token = "";
  let tokenExp = 0;
  function freshToken() {
    if (Date.now() < tokenExp - 60_000) return token;
    const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
    const now = Math.floor(Date.now() / 1000);
    const header = b64({ alg: "ES256", kid: keyId, typ: "JWT" });
    const payload = b64({ iss: issuerId, iat: now, exp: now + 20 * 60, aud: "appstoreconnect-v1" });
    const signer = createSign("SHA256");
    signer.update(`${header}.${payload}`);
    const sig = signer.sign({ key: pem, dsaEncoding: "ieee-p1363" }).toString("base64url");
    token = `${header}.${payload}.${sig}`;
    tokenExp = Date.now() + 20 * 60_000;
    return token;
  }

  async function call(method, path, body) {
    const url = path.startsWith("http") ? path : `${API}${path}`;
    const res = await fetch(url, {
      method,
      headers: {
        Authorization: `Bearer ${freshToken()}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON body */ }
    return { ok: res.ok, status: res.status, json, text };
  }

  // get throws on non-2xx; post/patch/del return {ok, status, json} so callers
  // can treat 409 ("already done") as success where that's the semantics.
  async function get(path) {
    const r = await call("GET", path);
    if (!r.ok) throw new Error(`GET ${path} → ${r.status}\n${r.text}`);
    return r.json;
  }

  // Follows links.next until exhausted. Use for lists that can exceed a page.
  async function getAll(path) {
    const out = [];
    let next = path;
    while (next) {
      const page = await get(next);
      out.push(...(page.data ?? []));
      next = page.links?.next ?? null;
    }
    return out;
  }

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // ── Domain helpers (the operations every repo needs) ──────────────────

  async function resolveAppId(bundleId) {
    const r = await get(`/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&fields[apps]=name,bundleId`);
    if (!r.data?.length) throw new Error(`No app for bundleId ${bundleId}`);
    return r.data[0].id;
  }

  async function listBuilds(appId, limit = 200) {
    const r = await get(
      `/v1/builds?filter[app]=${appId}&sort=-version&limit=${limit}` +
        `&fields[builds]=version,processingState,expired,uploadedDate`
    );
    return r.data ?? [];
  }

  // Waits for the uploaded build (by version, else newest) to reach VALID.
  // ASC indexes a fresh upload after ~30-120 s; full processing can take 25+.
  async function waitForBuild(appId, version, { timeoutMs = 25 * 60_000, pollMs = 30_000, log = console.log } = {}) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const builds = await listBuilds(appId);
      const target = version
        ? builds.find((b) => String(b.attributes.version) === String(version))
        : builds[0];
      if (target) {
        const state = target.attributes.processingState;
        if (state === "VALID") return target;
        if (state === "FAILED" || state === "INVALID") {
          throw new Error(`Build v${target.attributes.version} processing ${state}`);
        }
        log(`  build v${target.attributes.version} → ${state}, waiting…`);
      } else {
        log(`  build ${version ?? "(newest)"} not visible yet, waiting…`);
      }
      if (Date.now() > deadline) {
        throw new Error(
          `Timed out after ${timeoutMs / 60000} min waiting for build ${version ?? ""} to process. ` +
            `It is uploaded; rerun this step.`
        );
      }
      await sleep(pollMs);
    }
  }

  async function betaGroupId(appId, name) {
    const groups = await getAll(`/v1/apps/${appId}/betaGroups?limit=200&fields[betaGroups]=name,isInternalGroup`);
    const g = groups.find((x) => x.attributes.name === name);
    return g ? { id: g.id, isInternal: g.attributes.isInternalGroup } : null;
  }

  async function attachBuildToGroup(buildId, groupId) {
    const r = await call("POST", `/v1/builds/${buildId}/relationships/betaGroups`, {
      data: [{ type: "betaGroups", id: groupId }],
    });
    if (r.ok || r.status === 409) return; // 409 = already linked, fine
    // Internal groups created with "automatic distribution" enabled get every
    // new build assigned by Apple the moment it finishes processing — this
    // relationship endpoint then rejects a manual (redundant) attach with a
    // 422, not a 409. Same "already done" outcome, different status code.
    // Incident: actu-ios first real release (2026-07-29).
    if (r.status === 422 && /Cannot add internal group to a build/i.test(r.text)) return;
    throw new Error(`Attach group → ${r.status}\n${r.text}`);
  }

  async function submitBetaReview(buildId) {
    const r = await call("POST", `/v1/betaAppReviewSubmissions`, {
      data: { type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: buildId } } } },
    });
    if (r.ok) return "submitted";
    if (r.status === 409) return "already in review";
    throw new Error(`Beta review submit → ${r.status}\n${r.text}`);
  }

  // A distributed build can refuse expiry until detached from its groups —
  // fall back to detach + retry. Non-fatal by design (housekeeping).
  async function expireBuild(buildId, version, { log = console.error } = {}) {
    const patch = () =>
      call("PATCH", `/v1/builds/${buildId}`, {
        data: { type: "builds", id: buildId, attributes: { expired: true } },
      });
    let r = await patch();
    if (r.ok) return true;
    if (r.status === 409 || r.status === 422) {
      const rel = await get(`/v1/builds/${buildId}/relationships/betaGroups`);
      await call("DELETE", `/v1/builds/${buildId}/relationships/betaGroups`, { data: rel.data });
      r = await patch();
      if (r.ok) return true;
    }
    log(`  ! could not expire v${version} (${r.status}) — skipping, non-fatal`);
    return false;
  }

  return {
    call, get, getAll, sleep,
    resolveAppId, listBuilds, waitForBuild,
    betaGroupId, attachBuildToGroup, submitBetaReview, expireBuild,
  };
}

// Convenience: client straight from env (ASC_KEY_ID / ASC_ISSUER_ID +
// ASC_KEY_PATH or ASC_KEY_BASE64).
export function clientFromEnv(env = loadAscEnv()) {
  for (const k of ["ASC_KEY_ID", "ASC_ISSUER_ID"]) {
    if (!env[k]) throw new Error(`Missing ${k} (env, .claude/asc/.env or scripts/.env.testflight)`);
  }
  if (env.ASC_KEY_PATH) {
    return createClient({ keyId: env.ASC_KEY_ID, issuerId: env.ASC_ISSUER_ID, keyPath: env.ASC_KEY_PATH });
  }
  if (env.ASC_KEY_BASE64) {
    const key = Buffer.from(env.ASC_KEY_BASE64, "base64").toString("utf8");
    return createClient({ keyId: env.ASC_KEY_ID, issuerId: env.ASC_ISSUER_ID, key });
  }
  throw new Error("Missing ASC_KEY_PATH or ASC_KEY_BASE64");
}
