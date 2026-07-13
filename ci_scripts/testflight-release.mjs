#!/usr/bin/env node
// testflight-release.mjs — config-driven post-upload TestFlight distribution.
//
// Generalisation of keskonfe's scripts/testflight-release.mjs and treve's
// ci_scripts/assign_to_festival_group.mjs: both were the same operation with
// different parameters. Reads .claude/asc/config.json for the policy:
//
//   distribution.groups          → beta groups to attach the build to
//   distribution.betaReview      → submit a Beta App Review (needed the first
//                                  time an EXTERNAL group receives a version)
//   distribution.expireOldBuilds → expire every other non-expired build so
//                                  testers only ever see the latest
//
// Flow: wait for the uploaded build to reach VALID → attach groups →
// (optional) Beta App Review → (optional) expire the rest. Idempotent:
// already-linked builds and existing review submissions are treated as done.
//
// Usage (local or CI):
//   node testflight-release.mjs [--dry-run] [--version 845] [--project /path]
//
// Credentials: ASC_KEY_ID / ASC_ISSUER_ID + ASC_KEY_PATH or ASC_KEY_BASE64,
// from process.env (CI) or the project's .claude/asc/.env /
// scripts/.env.testflight (local). BUILD_VERSION env is honoured as the
// --version fallback (that's what the canonical workflow exports).

import { resolve } from "node:path";
import { loadAscEnv, loadAscConfig, clientFromEnv } from "./asc.mjs";

const args = process.argv.slice(2);
const DRY = args.includes("--dry-run");
const flag = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};

const cwd = resolve(flag("--project") ?? process.cwd());
const config = loadAscConfig(cwd);
if (!config) {
  console.error(`✗ No .claude/asc/config.json under ${cwd} — run /asc-init first.`);
  process.exit(1);
}
const env = loadAscEnv(cwd);
const version = flag("--version") ?? env.BUILD_VERSION ?? null;
const dist = config.distribution ?? {};
const groups = dist.groups ?? [];

const asc = clientFromEnv(env);
const appId = config.appId ?? (await asc.resolveAppId(config.bundleId));

console.log(`App ${appId} (${config.bundleId}) · waiting for build v${version ?? "(newest)"}…`);
const target = await asc.waitForBuild(appId, version);
console.log(`✓ build v${target.attributes.version} is VALID (${target.id})`);

const stale = dist.expireOldBuilds
  ? (await asc.listBuilds(appId)).filter((b) => b.id !== target.id && b.attributes.expired === false)
  : [];

if (DRY) {
  console.log(`\n[dry-run] would, for v${target.attributes.version}:`);
  for (const name of groups) console.log(`  • attach to "${name}"`);
  if (dist.betaReview) console.log(`  • submit Beta App Review`);
  if (dist.expireOldBuilds) {
    console.log(`  • expire ${stale.length} older build(s): ${stale.map((b) => `v${b.attributes.version}`).join(", ")}`);
  }
  console.log("[dry-run] no changes made\n");
  process.exit(0);
}

for (const name of groups) {
  const group = await asc.betaGroupId(appId, name);
  if (!group) {
    console.error(`::warning::TestFlight group "${name}" not found — skipped`);
    continue;
  }
  await asc.attachBuildToGroup(target.id, group.id);
  console.log(`✓ attached to "${name}"${group.isInternal ? " (internal)" : ""}`);
}

if (dist.betaReview) {
  const state = await asc.submitBetaReview(target.id);
  console.log(`✓ Beta App Review ${state}`);
}

if (dist.expireOldBuilds) {
  console.log(`Expiring ${stale.length} older build(s)…`);
  for (const b of stale) await asc.expireBuild(b.id, b.attributes.version);
  console.log(`✓ only v${target.attributes.version} remains active`);
}
