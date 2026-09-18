# Crossover

A native Mac speaker splitter (repo folder: Audio_Split_Angel): one audio input, split by a four-band crossover
(Low / Mid / Mid-High / High) and sent to four outputs. Swift/SwiftUI app,
real-time engine in plain C. Read `README.md` first.

## Rules

- **This is its own repository.** It started as a copy of Audio Angel
  (`../audio_angel`), which is finished: never modify, build in or commit to that
  folder. Copy code out of it if something is needed.
- **Branches:** `test` is the playground, `dev` is staging for final adjustments, `main`
  is shipped. New work is committed to `test`; it goes to `dev` when it's finished and
  tested, and `dev` goes to `main` only when Philip says so.
- **Build and test with `./build.sh`** (Command Line Tools only). It runs the engine
  self-test first and won't build if a test fails. `./build.sh test` runs the tests alone.
- **The audio thread is sacred.** Nothing in `Sources/SplitCore` may allocate, lock, log
  or call into Swift.
- **The bands must sum flat.** The self-test checks the four bands add back up to the
  input at every slope; any change to the crossover tree must keep that passing. The
  display draws `sc_band_response_db`, which is checked against the running engine.
- **`build/Crossover.app/Contents/MacOS/Crossover --check-model`** checks undo/redo,
  presets and band deletion; run it after touching `SplitModel` or `SplitConfig`.
- **The icon** is drawn by `tools/make_icon.swift`; rerun it rather than editing `Resources/Logo.png`.
- **Bump `CFBundleVersion` in `build.sh`** for every build handed to Philip.
