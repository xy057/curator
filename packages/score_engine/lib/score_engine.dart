/// Curated-score engine: Verovio engraving (SMuFL), time → scroll mapping, and a
/// tile-cached renderer for smooth animated staves.
library;

export 'src/auto_curate.dart';
export 'src/beat_grid.dart';
export 'src/condensing.dart';
export 'src/curated_scene.dart';
export 'src/curation.dart';
export 'src/display_list.dart' show RenderStyle;
export 'src/engraving.dart'
    show ClefShape, ClefSignature, EngraveException, EngravingData, KeySignature, MeasureLayout, Signature, StaffInfo, TimeSignature, verovioVersion;
export 'src/engraving_options.dart';
export 'src/font_files.dart';
export 'src/frozen_zone.dart';
export 'src/midi_tempo.dart';
export 'src/score_metadata.dart';
export 'src/score_fonts.dart';
export 'src/score_patch.dart';
export 'src/score_text.dart';
export 'src/scroll_map.dart';
export 'src/spacing_plan.dart';
export 'src/staff_stack.dart';
export 'src/sync_map.dart';
export 'src/zip_entries.dart';
