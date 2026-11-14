part of '../editor_controller.dart';

/// Images on the score: the files the project keeps, each drawn, the selection, and what the
/// user does to a picture (adding one, moving, resizing, cropping, removing), handed to the
/// extension that keeps where the pictures are (its `images` socket: Attach Image). Nothing
/// here works, and no image is drawn, while no such extension is on ([enabled]: Project
/// Settings ▸ Extensions); the pictures stay in the project.
class ImageEditing {
  ImageEditing._(this._editor);
  final EditorController _editor;

  /// Whether an extension that puts pictures on the score is on.
  bool get enabled => _editor.extensions.hasImages;

  /// On the score, bottom to top: as the extension lists them.
  List<ImagePatch> get patches => _editor.extensions.pictures;

  /// The extension the pictures are handed to, and its socket in its connector.
  ({ExtensionRuntime runtime, String node})? get _socket => switch (_editor.extensions._imager) {
        null => null,
        final runtime => (runtime: runtime, node: runtime.nodes('images').first.id),
      };

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
    if (!enabled || (index != null && (index < 0 || index >= patches.length))) index = null;
    final cropping = index != null && crop;
    if (index == _selected && cropping == _cropping) return;
    _selected = index;
    _cropping = cropping;
    if (index != null) _editor.spacers._selected = null;
    _editor._changed();
  }

  void _deselect() {
    _selected = null;
    _cropping = false;
  }

  /// The images as the scene draws them: none while the extension is off.
  List<ScenePatch> get _scenePatches => [
        if (enabled)
          for (final p in patches)
            if (_arts[p.image] case final art?)
              p.scene(art),
      ];

  void _show() => _editor._showSettings();

  /// Adds an image of [kind] from [bytes] (a file of type [extension]), its top-left corner
  /// at score quarter [quarter] and [top] staff spaces down, and selects it. One Undo step
  /// (the extension's: how big it comes in is its to say). Throws a [FormatException] when the
  /// bytes are not such an image.
  Future<void> add(ImageKind kind, Uint8List bytes, {required double quarter, required double top, String extension = ''}) async {
    if (!enabled || _editor._score == null) return;
    (:bytes, :extension) = await PatchImage.portable(bytes, extension);
    // The same file again is the same image: the project keeps it once.
    final same = _images.values.where((i) => i.kind == kind && _arts.containsKey(i.id) && listEquals(i.bytes, bytes)).firstOrNull;
    final image = same ?? PatchImage.create(kind, bytes, extension: extension), document = _documents.current;
    final art = same != null ? _arts[same.id]! : await image.decode();
    // Closed (another maybe opened) or switched off meanwhile: not for what is open now.
    final socket = _socket;
    if (!document.isLatest || socket == null || _editor._score == null) return same == null ? _dispose(art) : null;
    _images[image.id] = image;
    _arts[image.id] = art;
    _deselect();
    final index = socket.runtime.ask(socket.node, 'add', args: [image.id, quarter, top, art.size.width / art.size.height]);
    if (index is num && index >= 1 && index <= patches.length) _selected = index.toInt() - 1;
    _editor._changed();
  }

  /// Pastes the image on the clipboard (a PNG, SVG text, or a copied SVG / PNG / JPEG file)
  /// at score quarter [quarter] (by default the one under the pointer now) and [top] staff
  /// spaces down. False when there is no image to paste.
  Future<bool> paste({double? quarter, double top = 4}) async {
    final scene = _editor.scene;
    if (!enabled || scene == null) return false;
    final image = await readClipboardImage();
    if (image == null) return false;
    await add(image.kind, image.bytes,
        quarter: quarter ?? scene.axis.quarterAt(scene.scrollMap.xAt(_editor.playback.time.value)),
        top: top,
        extension: image.extension);
    return true;
  }

  /// Changes patch [index] (moving, resizing, cropping, its ink). Inside
  /// [EditorController.beginEdit] … [EditorController.endEdit], a whole drag is one Undo step.
  void update(int index, ImagePatch patch) {
    final all = patches, socket = _socket;
    if (socket == null || index < 0 || index >= all.length || all[index] == patch) return;
    socket.runtime.fire(socket.node, 'change', args: [index + 1, pictureTable(patch)]);
  }

  /// Removes patch [index] (the selected one by default).
  void remove([int? index]) {
    index ??= _selected;
    final socket = _socket;
    if (socket == null || index == null || index < 0 || index >= patches.length) return;
    _deselect();
    socket.runtime.fire(socket.node, 'remove', args: [LuaTable.list([index + 1])]);
    _editor._changed();
  }

  /// The image files the project keeps (those [patches] show), in the order first shown.
  List<PatchImage> get stored => _used.values.toList();

  /// The patches showing image [id] (indices into [patches]).
  List<int> usesOf(String id) => [
        for (final (i, p) in patches.indexed)
          if (p.image == id) i,
      ];

  PatchArt? artOfImage(String id) => _arts[id];

  /// The image files no picture shows: removed while the project is open, kept so Undo can
  /// bring them back. Never saved.
  List<PatchImage> get unused {
    final shown = _editor.extensions._imagesShown.toSet();
    return [
      for (final image in _images.values)
        if (!shown.contains(image.id)) image,
    ];
  }

  /// Lets go of [unused]: Undo no longer brings back the pictures that showed them (every
  /// other edit of those steps stays).
  void purgeUnused() {
    final gone = {for (final image in unused) image.id};
    if (gone.isEmpty) return;
    for (final id in gone) {
      _images.remove(id);
      if (_arts.remove(id) case final art?) _letGo(art);
    }
    _editor.extensions._withoutImages(gone);
    _editor._changed();
  }

  /// Removes every patch showing image [id]: one Undo step.
  void removeImage(String id) {
    final uses = usesOf(id), socket = _socket;
    if (socket == null || uses.isEmpty) return;
    _deselect();
    socket.runtime.fire(socket.node, 'remove', args: [LuaTable.list([for (final i in uses) i + 1])]);
    _editor._changed();
  }

  /// Shows patch [index]: moves the playhead to where its left edge reaches the pointer (its
  /// first pass) and selects it.
  void locate(int index) {
    if (!enabled || index < 0 || index >= patches.length) return;
    final timeline = _editor.timeline;
    final quarter = patches[index].quarter;
    final first = timeline.timesOf(quarter).firstOrNull;
    _editor.playback.seek(first?.seconds ?? timeline.secondsAtQuarter(quarter));
    select(index);
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
      throw const FormatException('Couldn’t read an image in the project.');
    }
    return arts;
  }

  void _load(Map<String, PatchImage> images, Map<String, PatchArt> arts) {
    _images.addAll(images);
    _arts.addAll(arts);
    _deselect();
  }

  /// After Undo / Redo.
  void _restore() {
    _deselect();
    _show();
  }

  /// The image files [patches] show.
  Map<String, PatchImage> get _used => {
        for (final p in patches) p.image: ?_images[p.image],
      };

  /// The image files every extension's pictures show, for saving.
  Map<String, PatchImage> get _kept => {
        for (final id in _editor.extensions._imagesShown) id: ?_images[id],
      };

  /// A turn per document, so an image decoded for one isn't added to the next.
  final _documents = Latest();

  void _reset() {
    _documents.cancel();
    _deselect();
    _images.clear();
    _arts.values.forEach(_letGo);
    _arts.clear();
  }

  /// Disposes [art], or after the last [hold] while one is held.
  void _letGo(PatchArt art) => _holds > 0 ? _released.add(art) : _dispose(art);

  /// Keeps every image drawn now from being let go (a video export draws them while the
  /// project may be closed or another opened) until the returned function is called.
  VoidCallback hold() {
    _holds++;
    var held = true;
    return () {
      if (!held) return;
      held = false;
      if (--_holds == 0) {
        _released.forEach(_dispose);
        _released.clear();
      }
    };
  }

  int _holds = 0;

  /// Closed with their project while held: let go when nothing holds them.
  final _released = <PatchArt>[];

  static void _dispose(PatchArt art) => switch (art) {
        RasterArt() => art.dispose(),
        VectorArt() => art.dispose(),
        _ => null,
      };
}
