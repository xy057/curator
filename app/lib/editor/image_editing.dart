part of '../editor_controller.dart';

/// Images on the score (the Attach Image extension): adding them, the selection, moving,
/// resizing, cropping and removing. Nothing here works, and no image is drawn, while
/// [enabled] is off (Settings ▸ Extension ▸ Attach Image); the images stay in the project.
class ImageEditing {
  ImageEditing._(this._c);
  final EditorController _c;

  /// The extension's switch.
  bool get enabled => _enabled;
  bool _enabled = false;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    if (!value) _deselect();
    _show();
    _c._changed();
  }

  /// On the score, bottom to top.
  List<ImagePatch> get patches => _patches;
  List<ImagePatch> _patches = const [];

  /// Every image file added while the project is open (Undo can bring a removed one back),
  /// and each drawn.
  final _images = <String, PatchImage>{};
  final _arts = <String, PatchArt>{};

  PatchArt? artOf(ImagePatch patch) => _arts[patch.image];

  /// The selected patch (an index into [patches]); null: none.
  int? get selected => _selected;
  int? _selected;

  /// Whether the selected patch's handles crop it instead of resizing it.
  bool get cropping => _cropping;
  bool _cropping = false;

  void select(int? index, {bool crop = false}) {
    if (!_enabled || (index != null && (index < 0 || index >= _patches.length))) index = null;
    final cropping = index != null && crop;
    if (index == _selected && cropping == _cropping) return;
    _selected = index;
    _cropping = cropping;
    _c._changed();
  }

  void _deselect() {
    _selected = null;
    _cropping = false;
  }

  /// The images as the scene draws them: none while the extension is off.
  List<ScenePatch> get _scenePatches => [
        if (_enabled)
          for (final p in _patches)
            if (_arts[p.image] case final art?)
              ScenePatch(quarter: p.quarter, top: p.top, width: p.width, height: p.height, crop: p.crop, art: art),
      ];

  void _show() => _c._scene?.patches = _scenePatches;

  /// How big a new image comes in: [defaultHeight] staff spaces high (narrower than
  /// [maxWidth]), its own shape.
  static const defaultHeight = 12.0, maxWidth = 40.0;

  /// Adds an image of [kind] from [bytes], its top-left corner at score quarter [quarter] and
  /// [top] staff spaces down, and selects it. One Undo step. Throws a [FormatException]
  /// when the bytes are not such an image.
  Future<void> add(ImageKind kind, Uint8List bytes, {required double quarter, required double top, String extension = ''}) async {
    if (!_enabled || _c._score == null) return;
    final image = PatchImage.create(kind, bytes, extension: extension), document = _document;
    final art = await image.decode();
    // Closed (another maybe opened) or switched off meanwhile: not for what is open now.
    if (document != _document || !_enabled || _c._score == null) return _dispose(art);
    _images[image.id] = image;
    _arts[image.id] = art;
    final aspect = art.size.width / art.size.height;
    final height = math.min(defaultHeight, maxWidth / aspect);
    _patches = [..._patches, ImagePatch(image: image.id, quarter: quarter, top: top, width: height * aspect, height: height)];
    _deselect();
    _selected = _patches.length - 1;
    _show();
    _c._edited();
    _c._changed();
  }

  /// Pastes the image on the clipboard (a PNG, SVG text, or a copied SVG / PNG / JPEG file)
  /// at score quarter [quarter] (by default the one under the pointer now) and [top] staff
  /// spaces down. False when there is no image to paste.
  Future<bool> paste({double? quarter, double top = 4}) async {
    final scene = _c._scene;
    if (!_enabled || scene == null) return false;
    final image = await readClipboardImage();
    if (image == null) return false;
    await add(image.kind, image.bytes,
        quarter: quarter ?? scene.axis.quarterAt(scene.scrollMap.xAt(_c.playback.time.value)),
        top: top,
        extension: image.extension);
    return true;
  }

  /// Changes patch [index] (moving, resizing, cropping). Inside [EditorController.beginEdit]
  /// … [EditorController.endEdit], a whole drag is one Undo step.
  void update(int index, ImagePatch patch) {
    if (!_enabled || index < 0 || index >= _patches.length || _patches[index] == patch) return;
    _patches = [..._patches]..[index] = patch;
    _show();
    _c._edited();
    _c._changed();
  }

  /// Removes patch [index] (the selected one by default).
  void remove([int? index]) {
    index ??= _selected;
    if (!_enabled || index == null || index < 0 || index >= _patches.length) return;
    _patches = [..._patches]..removeAt(index);
    _deselect();
    _show();
    _c._edited();
    _c._changed();
  }

  /// Opens a project's images: every one is drawn before anything is replaced.
  static Future<Map<String, PatchArt>> _decodeAll(Map<String, PatchImage> images) async {
    final arts = <String, PatchArt>{};
    try {
      for (final image in images.values) {
        arts[image.id] = await image.decode();
      }
    } catch (_) {
      arts.values.forEach(_dispose);
      throw const FormatException('An image in the project could not be read.');
    }
    return arts;
  }

  void _load(List<ImagePatch> patches, Map<String, PatchImage> images, Map<String, PatchArt> arts) {
    _images.addAll(images);
    _arts.addAll(arts);
    _patches = List.unmodifiable(patches.where((p) => _arts.containsKey(p.image)));
    _deselect();
  }

  /// After Undo / Redo.
  void _restore(List<ImagePatch> patches) {
    _patches = patches;
    _deselect();
    _show();
  }

  /// The image files [patches] show, for saving.
  Map<String, PatchImage> get _used => {
        for (final p in _patches) p.image: ?_images[p.image],
      };

  /// Counts the documents closed, so an image decoded for one isn't added to the next.
  int _document = 0;

  void _reset() {
    _document++;
    _patches = const [];
    _deselect();
    _images.clear();
    _arts.values.forEach(_dispose);
    _arts.clear();
  }

  static void _dispose(PatchArt art) => switch (art) {
        RasterArt() => art.dispose(),
        VectorArt() => art.dispose(),
        _ => null,
      };
}
