# pawnote bundle

`Noto/Resources/pawnote-bundle.js` is `@niicojs/pawnote` plus the Swift ↔ JS
bridge (`Noto/Resources/pawnote-bridge.js`), bundled with esbuild and executed
in JavaScriptCore by `PawnoteBridge.swift`.

The bundle is a build artefact, committed so the Xcode build needs no Node.
It is never edited by hand:

```bash
tools/pawnote-bundle/build.sh   # npm ci + esbuild + node --check
```

Versions are pinned in `package.json` / `package-lock.json`. The CI workflow
`.github/workflows/pawnote-bundle.yml` rebuilds the bundle and fails when the
committed file differs from the build.

Lesson contents (cahier de textes, onglet 89) go through pawnote's public
`resourcesFromIntervals`; the earlier hand patch of the bundle is gone.

One patch remains, applied to pawnote's source at build time by `build.mjs`
(never to the bundle): pawnote's identification / authentication internals
are exported as `__noto_*` so the bridge can run `loginENT`, the CAS login
used by the TestFlight builds for MonLycée. Each internal is checked against
a signature of pawnote 1.6.2 and the build fails if one is missing, so a
version bump must re-check them.
