// verovio.dart's place on the web, where there is no engine: a page shows a score engraved
// beforehand (see EngravingData), so nothing here is called.
import '../engraving.dart';

String verovioVersion() => '';

Map<String, Object?> availableOptions(String resourceDirectory) => throw UnsupportedError('No engraver on the web');

EngravingData engrave(String musicXML, String resourceDirectory, String optionsJson) =>
    throw UnsupportedError('No engraver on the web');

({int upm, List<({double x, double y, double w, double h, double advance})?> glyphs})? measureFont(
  String path,
  int face, {
  required List<int> codes,
}) => null;
