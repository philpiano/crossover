# Audio Angel

A native Mac audio router for music lessons over Zoom: Swift/SwiftUI app, real-time
engine in plain C. Read `README.md` first: how it's used, how it works, and the checks.

## Rules

- **This is its own repository.** Piano Magic (`the_software`) and Music Zoom live
  elsewhere and are not imported. When another project needs Audio Angel code, copy the
  parts it needs out of here; nothing here depends on them.
- **Branches:** `test` is the playground, `dev` is staging for final adjustments, `main`
  is shipped. New work is committed to `test`; it goes to `dev` when it's finished and
  tested, and `dev` goes to `main` only when Philip says so.
- **Two GitHub repos.** `origin` is the private `philpiano/Audio_Angel` (all branches).
  `public` is `philpiano/audio-angel`: only shipped versions go there, on Philip's say-so.
  Philip edits the public README on GitHub, so pull it and diff before publishing.
- **Build and test with `./build.sh`** (Command Line Tools only). It runs the engine
  self-test first and won't build if a test fails. `./build.sh test` runs the tests alone.
- **The audio thread is sacred.** Nothing in `Sources/RouterCore` may allocate, lock, log
  or call into Swift. Test dynamics on realistic signals, not DC: see the
  realistic-signal tests in `Sources/RouterCoreSelfTest/main.c`.
- **Bump `CFBundleVersion` in `build.sh`** for every build handed to Philip, so About
  tells builds apart.
