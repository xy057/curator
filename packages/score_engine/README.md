# score_engine

The engine behind Curated Score: engraves MusicXML with [Verovio](https://www.verovio.org)
into one endless system, records the drawing per staff, maps playback time to the scroll,
plans the vertical layout of the curated staves, and draws frames from cached tiles. See
[docs/architecture.md](../../docs/architecture.md).

Verovio is fetched and patched by `make setup` at the repository root, and built with CMake by
`hook/build.dart` whenever the package is built or tested.

```bash
flutter test      # from packages/score_engine/: the engine tests, on the app's demo score
SCORE_FILE=some.musicxml SNAPSHOT_DIR=/some/folder SNAPSHOT_TIMES=0,10 flutter test test/render_file_test.dart
```

The second renders any score to PNG frames for a visual check.

Bundled: Bravura and Academico (SIL Open Font License, see `assets/fonts/*-OFL.txt`), with
Verovio's metrics for them in `assets/verovio/`.
