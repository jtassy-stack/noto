// Reproducible build of Noto/Resources/pawnote-bundle.js (run by build.sh).
//
// One source patch is applied to the pinned pawnote while bundling, never to
// the bundle itself: pawnote's identification / authentication internals are
// exported under `__noto_*` names, so pawnote-bridge.js can run the ENT (CAS)
// login the TestFlight builds used (`loginENT`). pawnote has no public CAS
// login. Each internal is located by a signature string of pawnote 1.6.2;
// the build fails when one is missing (a version bump must re-check them).
import { build } from "esbuild";

const INTERNALS = {
  // name in pawnote's index.mjs → [exported as, signature that must be present]
  a: ["__noto_cleanURL", "var a=e=>{let s=new URL(e);"],
  ve: ["__noto_loginParams", " ve={fd:1,login:!0}"],
  W: ["__noto_parseSessionInformation", ",W=(e,s,t)=>{const i=!e.MR&&!e.ER"],
  me: ["__noto_instanceParameters", ",me=async(e,s=null)=>{const t=n.pki.rsa.setPublicKey("],
  he: ["__noto_identify", ',he=async(e,s)=>{const t=ne(e),n=new ae(e,"Identification"'],
  Ne: ["__noto_transformCredentials", ",Ne=(e,s,t)=>{1===t.modeCompLog&&"],
  Pe: ["__noto_createAuthKey", ',Pe=(e,s,t)=>{const i=n.md.sha256.create().update(e.alea??"")'],
  Se: ["__noto_solveChallenge", ",Se=(e,s,t)=>{const i=n.util.createBuffer(e.information.aesIV)"],
  fe: ["__noto_authenticate", ',fe=async(e,s)=>{const t=ne(e),n=new ae(e,"Authentification"'],
  Ie: ["__noto_switchToAuthKey", ",Ie=(e,s,t)=>{const i=n.util.createBuffer(e.information.aesIV),a=se.decrypt(s.cle,t,i)"],
  Le: ["__noto_hasDoubleAuth", ",Le=e=>Boolean(e.actionsDoubleAuth)"],
};

const exposeInternals = {
  name: "noto-pawnote-internals",
  setup(b) {
    b.onLoad({ filter: /@niicojs[\\/]pawnote[\\/]dist[\\/]index\.mjs$/ }, async ({ path }) => {
      const { readFile } = await import("node:fs/promises");
      let source = await readFile(path, "utf8");
      const missing = Object.entries(INTERNALS).filter(([, [, sig]]) => !source.includes(sig));
      if (missing.length) {
        throw new Error("pawnote internals not found (version changed?): " + missing.map(([n]) => n).join(", "));
      }
      const marker = "//# sourceMappingURL=";
      const at = source.lastIndexOf(marker);
      const extra = "export{" + Object.entries(INTERNALS).map(([n, [as]]) => `${n} as ${as}`).join(",") + "};\n";
      source = at >= 0 ? source.slice(0, at) + extra : source + "\n" + extra;
      return { contents: source, loader: "js" };
    });
  },
};

await build({
  entryPoints: ["../../Noto/Resources/pawnote-bridge.js"],
  bundle: true,
  format: "iife",
  platform: "browser",
  target: "es2020",
  outfile: "../../Noto/Resources/pawnote-bundle.js",
  nodePaths: ["./node_modules"],
  plugins: [exposeInternals],
  logLevel: "info",
});
