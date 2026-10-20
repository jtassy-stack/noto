#!/usr/bin/env node
// asc-profile.mjs — regenerates an App Store provisioning profile through the
// App Store Connect API, so it picks up the App ID's current capabilities
// (iCloud for the family sync, phase 9), and prints it base64-encoded on
// stdout. With `--set-secret <owner/repo>` it also writes it to the GitHub
// secret the TestFlight workflow installs, only once the profile is in hand:
//
//   node ci_scripts/asc-profile.mjs fr.noto.app --set-secret jtassy-stack/noto
//
// (No `| gh secret set` pipe: without pipefail, a failure here would store an
// empty secret.) The profile name and secret come from .claude/asc/config.json
// (`provisioningProfiles`). The new profile keeps the old one's certificates.
// Idempotent: a profile that already carries `--require <text>` (default:
// the iCloud container) is printed as is, not regenerated. Logs go to stderr.
//
// The API cannot create an iCloud container or attach it to the App ID:
// do that in the developer portal first, or the new profile won't carry it.

import { execFileSync } from "node:child_process";
import { clientFromEnv, loadAscConfig } from "./asc.mjs";

const args = process.argv.slice(2);
const option = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const optionValues = new Set(["--require", "--set-secret"].map(option));
const bundleId = args.find((a) => !a.startsWith("--") && !optionValues.has(a)) ?? loadAscConfig()?.bundleId;
const required = option("--require") ?? "iCloud.fr.noto.app";
const secretRepo = option("--set-secret");
const log = (...m) => console.error(...m);

const config = loadAscConfig();
const entry = config?.provisioningProfiles?.[bundleId];
if (!entry) {
  log(`No provisioningProfiles entry for ${bundleId} in .claude/asc/config.json`);
  process.exit(1);
}

const asc = clientFromEnv();
const decoded = (b64) => Buffer.from(b64, "base64").toString("latin1");

// Only ever called with a profile in hand: an empty or failed run never reaches the secret.
function publish(content) {
  if (!content) {
    log("Empty profile: nothing written.");
    process.exit(1);
  }
  if (secretRepo) {
    execFileSync("gh", ["secret", "set", entry.secret, "--repo", secretRepo], {
      input: content,
      stdio: ["pipe", "inherit", "inherit"],
    });
    log(`${entry.secret} updated on ${secretRepo}.`);
  } else {
    process.stdout.write(content);
  }
}

const bundles = await asc.getAll(`/v1/bundleIds?filter[identifier]=${encodeURIComponent(bundleId)}&limit=200`);
const bundle = bundles.find((b) => b.attributes.identifier === bundleId);
if (!bundle) {
  log(`No App ID ${bundleId}`);
  process.exit(1);
}

const profiles = (await asc.getAll(`/v1/bundleIds/${bundle.id}/profiles?limit=200`))
  .filter((p) => p.attributes.name === entry.name);
const current = profiles.find((p) => p.attributes.profileState === "ACTIVE") ?? profiles[0];
if (!current) {
  log(`No profile named « ${entry.name} » for ${bundleId}`);
  process.exit(1);
}

if (current.attributes.profileState === "ACTIVE" && required
    && decoded(current.attributes.profileContent).includes(required)) {
  log(`« ${entry.name} » already carries ${required}: unchanged.`);
  publish(current.attributes.profileContent);
  process.exit(0);
}

const certificates = (await asc.get(`/v1/profiles/${current.id}/relationships/certificates?limit=200`)).data;
if (!certificates?.length) {
  log(`« ${entry.name} » has no certificate to carry over`);
  process.exit(1);
}

// Profile names are unique per team: the old ones go first.
for (const profile of profiles) {
  const r = await asc.call("DELETE", `/v1/profiles/${profile.id}`);
  if (!r.ok && r.status !== 404) {
    log(`Deleting « ${entry.name} » (${profile.id}) → ${r.status}\n${r.text}`);
    process.exit(1);
  }
}

const created = await asc.call("POST", "/v1/profiles", {
  data: {
    type: "profiles",
    attributes: { name: entry.name, profileType: current.attributes.profileType },
    relationships: {
      bundleId: { data: { type: "bundleIds", id: bundle.id } },
      certificates: { data: certificates.map((c) => ({ type: "certificates", id: c.id })) },
    },
  },
});
if (!created.ok) {
  log(`Creating « ${entry.name} » → ${created.status}\n${created.text}`);
  log(`The old profile is deleted: rerun this script once the cause is fixed.`);
  process.exit(1);
}

const content = created.json.data.attributes.profileContent;
if (required && !decoded(content).includes(required)) {
  log(`Warning: the new « ${entry.name} » does not carry ${required}. `
    + `Is the container attached to ${bundleId} in the developer portal?`);
}
log(`« ${entry.name} » regenerated (${created.json.data.id}), valid until `
  + `${created.json.data.attributes.expirationDate}.`);
publish(content);
