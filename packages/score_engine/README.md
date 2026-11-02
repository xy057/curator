# score_engine

The engine behind Curator: engraves MusicXML with [Verovio](https://www.verovio.org)
into one endless system, records the drawing per staff, maps playback time to the scroll,
plans the vertical layout of the curated staves, and draws frames from cached tiles; it also
lines a recording up with the score (Align) and finds a melody in it (Find Phrase). See
[docs/architecture.md](../../docs/architecture.md).

Verovio is fetched and patched by `make setup` at the repository root, and built with CMake by
`hook/build.dart` whenever the package is built or tested.

```bash
flutter test      # from packages/score_engine/: the engine tests, on the app's demo score
```

Bundled: the SMuFL music fonts Bravura, Leland, Petaluma, Leipzig and Gootville, and the text
font Academico (SIL Open Font License, see `assets/fonts/*-OFL.txt`), with Verovio's metrics
for them in `assets/verovio/`.
