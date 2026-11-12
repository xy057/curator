import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ai_providers.dart';
import 'app_colors.dart';
import 'app_icons.dart';
import 'app_settings.dart';
import 'dialog_kit.dart';
import 'error_text.dart';
import 'lilypond_dialog.dart' show monospace;
import 'menu_kit.dart';
import 'ui_kit.dart';
import 'l10n/l10n.dart';

/// Settings ▸ Remote AI Provider: the providers at the left, searched by name, each on or off,
/// Add Provider… under them; the chosen one's credentials and models at the right
/// ([_ProviderPane]).
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key, required this.settings, required this.groupColor});
  final AppSettings settings;

  /// The fill of a group of rows on a settings page (its models' list).
  final Color Function(BuildContext) groupColor;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  static String? _lastChosen; // the page reopens on it
  final _search = TextEditingController();

  AppSettings get _settings => widget.settings;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _choose(String id) => setState(() => _lastChosen = id);

  Future<void> _add() async {
    final result = await showAppDialog<_ProviderEdit>(context: context, builder: (_) => const _ProviderDialog());
    if (result case _Changed(:final name, :final format)) {
      final provider = AiProvider.added(name, format);
      _settings.setAiProvider(provider);
      _search.clear();
      _choose(provider.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final providers = _settings.aiProviders;
    final chosen = providers.where((p) => p.id == _lastChosen).firstOrNull ?? providers.first;
    final q = _search.text.trim().toLowerCase();
    final shown = [
      for (final p in providers)
        if (q.isEmpty || p.name.toLowerCase().contains(q) || p.format.label.toLowerCase().contains(q)) p,
    ];
    final page = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: 176,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.fromLTRB(12, 14, 10, 10), child: _SearchField(controller: _search)),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              children: [
                for (final p in shown)
                  _ProviderTile(provider: p, selected: p.id == chosen.id, onTap: () => _choose(p.id)),
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Text('No matching providers'.tr,
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: colors.textMuted)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _add,
                icon: Icon(AppIcon.add.of(context), size: 16),
                label: Text('Add Provider…'.tr),
              ),
            ),
          ),
        ]),
      ),
      VerticalDivider(width: 1, color: colors.line),
      Expanded(
        child: _ProviderPane(
          key: ValueKey(chosen.id),
          settings: _settings,
          provider: chosen,
          groupColor: widget.groupColor,
          onRemoved: () => _choose(providers.first.id),
        ),
      ),
    ]);
    if (!_settings.aiHidden) return page;
    // AI hidden: the page under a cover, nothing on it reached; Hide AI features on the cover.
    return Stack(fit: StackFit.expand, children: [
      ExcludeSemantics(
        child: ExcludeFocus(child: IgnorePointer(child: Opacity(opacity: 0.3, child: page))),
      ),
      Center(child: _HiddenCover(settings: _settings, groupColor: widget.groupColor)),
    ]);
  }
}

/// Over Settings ▸ Remote AI Provider while AI is hidden ([AppSettings.aiHidden]): that it is,
/// and the switch (Settings ▸ General's own) to show it again from the next launch.
class _HiddenCover extends StatelessWidget {
  const _HiddenCover({required this.settings, required this.groupColor});
  final AppSettings settings;
  final Color Function(BuildContext) groupColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = AppStyle.of(context);
    final carbon = CarbonColors.maybeOf(context);
    return Container(
      key: const ValueKey('aiHidden'),
      width: 300,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      decoration: BoxDecoration(
        color: groupColor(context),
        borderRadius: style.radius(12),
        border: Border.all(color: carbon?.borderSubtle ?? colors.line),
        boxShadow: [if (carbon == null) BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(AppIcon.ai.of(context), size: 26, color: colors.textMuted),
        const SizedBox(height: 10),
        Text('AI features are hidden'.tr,
            textAlign: TextAlign.center, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: colors.text)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Text('Hide AI features'.tr, style: TextStyle(fontSize: 13, color: colors.text))),
          AppSwitch(value: settings.hideAi, onChanged: (v) => settings.hideAi = v),
        ]),
        if (settings.aiRestartPending)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Restart to apply.'.tr, style: TextStyle(fontSize: 12, color: colors.textMuted)),
            ),
          ),
      ]),
    );
  }
}

/// The providers' search, as Settings' own: Esc with something typed clears it.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final carbon = CarbonColors.maybeOf(context);
    return SizedBox(
      height: carbon == null ? 30 : 32,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape || controller.text.isEmpty) {
            return KeyEventResult.ignored;
          }
          controller.clear();
          return KeyEventResult.handled;
        },
        child: TextField(
          controller: controller,
          style: TextStyle(fontSize: carbon == null ? 13 : 14),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search providers'.tr,
            prefixIcon: Icon(AppIcon.search.of(context), size: 16, color: carbon?.textSecondary ?? colors.textMuted),
            prefixIconConstraints: BoxConstraints(minWidth: carbon == null ? 30 : 40),
            filled: true,
            fillColor: carbon?.field ?? colors.line.withValues(alpha: 0.6),
            contentPadding: EdgeInsets.symmetric(vertical: carbon == null ? 7 : 8),
            border: carbon != null
                ? fieldBorders(context).rest
                : OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: BorderSide.none),
            enabledBorder: carbon != null ? fieldBorders(context).rest : null,
            focusedBorder: carbon != null
                ? fieldBorders(context).focused
                : OutlineInputBorder(
                    borderRadius: BorderRadius.circular(7),
                    borderSide: BorderSide(color: colors.accent.withValues(alpha: 0.6)),
                  ),
          ),
        ),
      ),
    );
  }
}

/// A provider in the list: its name, and whether it is on.
class _ProviderTile extends StatefulWidget {
  const _ProviderTile({required this.provider, required this.selected, required this.onTap});
  final AiProvider provider;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ProviderTile> createState() => _ProviderTileState();
}

class _ProviderTileState extends State<_ProviderTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = AppStyle.of(context);
    final k = CarbonColors.maybeOf(context);
    final selected = widget.selected;
    // As Settings' sidebar marks its page: the accent's tint (Carbon: its selected layer).
    final fill = k != null
        ? (selected ? k.layerSelected : _hover ? k.layerHover : k.layerHover.withValues(alpha: 0))
        : selected
            ? colors.accentSoft
            : _hover
                ? colors.line.withValues(alpha: 0.45)
                : colors.line.withValues(alpha: 0);
    final p = widget.provider;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        button: true,
        selected: selected,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: stateDuration(motion(context, 120)),
              curve: style.curve,
              height: 38,
              padding: const EdgeInsets.only(left: 10, right: 6),
              decoration: BoxDecoration(color: fill, borderRadius: style.radius(7)),
              child: Row(children: [
                Expanded(
                  child: Text(p.name, // the provider's own name: not translated
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13, color: colors.text, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                ),
                const SizedBox(width: 6),
                _OnOffChip(on: p.enabled),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Green "On", orange "Off".
class _OnOffChip extends StatelessWidget {
  const _OnOffChip({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = on
        ? (dark ? const Color(0xFF5FCB8C) : const Color(0xFF1C8A4C))
        : (dark ? const Color(0xFFF1A85F) : const Color(0xFFC0640E));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.18 : 0.12),
        borderRadius: AppStyle.of(context).radius(9),
      ),
      child: Text(
        on ? 'On'.trIn('provider') : 'Off'.trIn('provider'),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

/// The chosen provider: its name (Edit Provider… by it) and its switch; the API key (shown on
/// demand, Test beside its label), base URL and path; and its models, which can be searched,
/// chosen several at once to remove, added by ID, or fetched from the provider.
class _ProviderPane extends StatefulWidget {
  const _ProviderPane(
      {super.key, required this.settings, required this.provider, required this.groupColor, required this.onRemoved});
  final AppSettings settings;
  final AiProvider provider;
  final Color Function(BuildContext) groupColor;
  final VoidCallback onRemoved;

  @override
  State<_ProviderPane> createState() => _ProviderPaneState();
}

/// What a Test last said: [ok], or not with the server's [message].
typedef _TestResult = ({bool ok, String message});

class _ProviderPaneState extends State<_ProviderPane> {
  late final _key = TextEditingController(text: widget.provider.apiKey);
  late final _base = TextEditingController(text: widget.provider.baseUrl);
  late final _path = TextEditingController(text: widget.provider.path);
  late final _headers = TextEditingController(text: widget.provider.headers);
  late final _body = TextEditingController(text: widget.provider.body);
  final _modelSearch = TextEditingController();
  bool _keyShown = false, _searching = false, _selecting = false, _testing = false, _fetching = false;

  /// Advanced shown: from the start, when the provider has custom headers or a body.
  late bool _advanced = widget.provider.headers.trim().isNotEmpty || widget.provider.body.trim().isNotEmpty;
  final _picked = <String>{};
  _TestResult? _tested;

  AiProvider get _p => widget.provider;

  void _set(AiProvider p) => widget.settings.setAiProvider(p);

  @override
  void initState() {
    super.initState();
    _modelSearch.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(_ProviderPane old) {
    super.didUpdateWidget(old);
    // Changed elsewhere (Edit Provider…'s format): the fields follow. What is typed stays as
    // typed: a space at its end isn't kept with the provider, but taken from the field it would
    // take the caret with it.
    if (_base.text.trim() != _p.baseUrl) _base.text = _p.baseUrl;
    if (_path.text.trim() != _p.path) _path.text = _p.path;
    if (_key.text.trim() != _p.apiKey) _key.text = _p.apiKey;
    if (_headers.text != _p.headers) _headers.text = _p.headers;
    if (_body.text != _p.body) _body.text = _p.body;
    // What Test found was of the key and the address as they were.
    if (!_sameServer(old.provider, _p)) _tested = null;
    _picked.retainAll(_p.models);
  }

  @override
  void dispose() {
    _key.dispose();
    _base.dispose();
    _path.dispose();
    _headers.dispose();
    _body.dispose();
    _modelSearch.dispose();
    super.dispose();
  }

  Future<void> _edit() async {
    final result = await showAppDialog<_ProviderEdit>(context: context, builder: (_) => _ProviderDialog(provider: _p));
    switch (result) {
      case _Changed(:final name, :final format):
        // A new format brings its own path, unless one of the user's own was typed.
        final path = format != _p.format && (_p.path.trim().isEmpty || _p.path == _p.format.path) ? format.path : null;
        _set(_p.copyWith(name: name, format: format, path: path));
      case _Removed():
        widget.settings.removeAiProvider(_p.id);
        widget.onRemoved();
      case null:
    }
  }

  Future<void> _test(String? model) async {
    setState(() {
      _testing = true;
      _tested = null;
    });
    final asked = _p;
    _TestResult result;
    try {
      await AiClient(asked).test(model);
      result = (ok: true, message: 'Connected'.tr);
    } catch (e) {
      result = (ok: false, message: _errorText(e));
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _tested = _sameServer(asked, _p) ? result : null; // not of a key changed meanwhile
    });
  }

  /// Whether [a] and [b] are asked alike: the same key, at the same address, in the same format,
  /// with the same custom headers and body.
  static bool _sameServer(AiProvider a, AiProvider b) =>
      a.format == b.format &&
      a.apiKey == b.apiKey &&
      a.baseUrl == b.baseUrl &&
      a.path == b.path &&
      a.headers == b.headers &&
      a.body == b.body;

  Future<void> _fetch() async {
    setState(() => _fetching = true);
    final provider = _p;
    Map<String, AiModelInfo>? offered;
    Object? error;
    try {
      offered = await AiClient(provider).models();
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    setState(() => _fetching = false);
    if (error != null) {
      await showAppDialog<void>(
        context: context,
        builder: (context) => AppDialog(
          title: Text('Couldn’t Fetch Models'.tr),
          content: SingleChildScrollView(child: Text(_errorText(error!))),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text('OK'.tr))],
        ),
      );
      return;
    }
    if (!mounted) return;
    final list = offered!;
    final chosen = await showAppDialog<List<String>>(
      context: context,
      builder: (_) => _FetchedModelsDialog(offered: list, chosen: _p.models),
    );
    if (chosen == null) return;
    // What the list says of each model chosen goes with it, but for what was set by hand.
    final p = _p;
    _set(p.copyWith(models: chosen, details: {
      for (final m in chosen) m: switch (list[m]) { final found? => p.infoOf(m).fetched(found), null => p.infoOf(m) },
    }));
  }

  /// Edit Model: what is known of [model].
  Future<void> _editModel(String model) async {
    final info = await showAppDialog<AiModelInfo>(context: context, builder: (_) => _ModelDialog(provider: _p, model: model));
    if (info != null && _p.models.contains(model)) _set(_p.withInfo(model, info));
  }

  Future<void> _addModel() async {
    final id = await showAppDialog<String>(context: context, builder: (_) => _AddModelDialog(models: _p.models));
    if (id != null) _set(_p.copyWith(models: [..._p.models, id]));
  }

  void _removeModels(Iterable<String> ids) {
    final gone = ids.toSet();
    _set(_p.copyWith(models: [for (final m in _p.models) if (!gone.contains(m)) m]));
    _picked.removeAll(gone);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final p = _p;
    final q = _modelSearch.text.trim().toLowerCase();
    final models = [for (final m in p.models) if (!_searching || q.isEmpty || m.toLowerCase().contains(q)) m];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        Row(children: [
          Expanded(
            child: Row(children: [
              Flexible(
                child: Text(p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
              ),
              const SizedBox(width: 4),
              ToolbarButton(icon: AppIcon.settings.of(context), tooltip: 'Edit provider'.tr, onPressed: _edit),
            ]),
          ),
          const SizedBox(width: 12),
          AppSwitch(value: p.enabled, onChanged: (v) => _set(p.copyWith(enabled: v))),
        ]),
        const SizedBox(height: 10),
        Divider(height: 1, color: colors.line),
        const SizedBox(height: 14),
        // The key's label, and Test at its right with what it last found.
        SizedBox(
          height: 28,
          child: Row(children: [
            _Label('API key'.tr),
            const SizedBox(width: 12),
            Expanded(child: _testStatus(context)),
            _testButton(context),
          ]),
        ),
        const SizedBox(height: 4),
        AppTextField(
          controller: _key,
          label: '',
          obscureText: !_keyShown,
          suffix: IconButton(
            tooltip: _keyShown ? 'Hide key'.tr : 'Show key'.tr,
            iconSize: 17,
            color: colors.textMuted,
            onPressed: () => setState(() => _keyShown = !_keyShown),
            icon: Icon((_keyShown ? AppIcon.hide : AppIcon.show).of(context)),
          ),
          onChanged: (v) => _set(_p.copyWith(apiKey: v.trim())),
        ),
        SizedBox(height: dialogGap(context)),
        AppTextField(
          controller: _base,
          label: 'API base URL'.tr,
          hint: 'https://',
          keyboardType: TextInputType.url,
          onChanged: (v) => _set(_p.copyWith(baseUrl: v.trim())),
        ),
        SizedBox(height: dialogGap(context)),
        AppTextField(
          controller: _path,
          label: 'API path'.tr,
          hint: p.format.path,
          onChanged: (v) => _set(_p.copyWith(path: v.trim())),
        ),
        SizedBox(height: dialogGap(context)),
        _Disclosure(
          label: 'Advanced'.tr,
          open: _advanced,
          onToggle: () => setState(() => _advanced = !_advanced),
          child: _RequestFields(
            headers: _headers,
            body: _body,
            onHeaders: (v) => _set(_p.copyWith(headers: v)),
            onBody: (v) => _set(_p.copyWith(body: v)),
          ),
        ),
        const SizedBox(height: 18),
        Row(children: [
          Text('Models'.tr, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: colors.text)),
          const SizedBox(width: 8),
          _CountBadge(p.models.length),
          const Spacer(),
          ToolbarButton(
            icon: AppIcon.search.of(context),
            tooltip: 'Search models'.tr,
            selected: _searching,
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _modelSearch.clear();
            }),
          ),
          ToolbarButton(
            icon: AppIcon.selectMany.of(context),
            tooltip: 'Select models'.tr,
            selected: _selecting,
            onPressed: p.models.isEmpty && !_selecting
                ? null
                : () => setState(() {
                      _selecting = !_selecting;
                      _picked.clear();
                    }),
          ),
          ToolbarButton(icon: AppIcon.add.of(context), tooltip: 'Add model'.tr, onPressed: _addModel),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: _fetching ? null : _fetch,
            icon: _fetching ? const _Spinner() : Icon(AppIcon.fetch.of(context), size: 16),
            label: Text('Fetch'.tr),
          ),
        ]),
        if (_searching) ...[
          const SizedBox(height: 8),
          AppTextField(controller: _modelSearch, label: '', hint: 'Search models'.tr, autofocus: true),
        ],
        if (_selecting) ...[
          const SizedBox(height: 6),
          Row(children: [
            TextButton(
              onPressed: models.isEmpty
                  ? null
                  : () => setState(() => _picked.containsAll(models) ? _picked.removeAll(models) : _picked.addAll(models)),
              child: Text(_picked.containsAll(models) && models.isNotEmpty ? 'Select None'.tr : 'Select All'.tr),
            ),
            const Spacer(),
            TextButton(
              onPressed: _picked.isEmpty ? null : () => setState(() => _removeModels(_picked.toList())),
              child: Text(_picked.isEmpty ? 'Remove'.tr : 'Remove {n}'.fill({'n': _picked.length})),
            ),
          ]),
        ],
        const SizedBox(height: 8),
        if (models.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(
              p.models.isEmpty ? 'No models yet.'.tr : 'No matching models'.tr,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: colors.textMuted),
            ),
          )
        else
          DecoratedBox(
            decoration: BoxDecoration(color: widget.groupColor(context), borderRadius: AppStyle.of(context).radius(10)),
            child: Column(children: [
              for (final (i, m) in models.indexed) ...[
                if (i > 0) Divider(height: 1, indent: 12, endIndent: 12, color: colors.line),
                _ModelRow(
                  id: m,
                  info: p.infoOf(m),
                  picked: _selecting ? _picked.contains(m) : null,
                  onTap: _selecting
                      ? () => setState(() => _picked.contains(m) ? _picked.remove(m) : _picked.add(m))
                      : () => _editModel(m),
                  onEdit: () => _editModel(m),
                  onRemove: () => _removeModels([m]),
                ),
              ],
            ]),
          ),
      ],
    );
  }

  /// Test: with no models, whether the key and base URL get the model list; with one, a word from
  /// it; with several, a word from the one chosen from its menu.
  Widget _testButton(BuildContext context) {
    final models = _p.models;
    final icon = _testing ? const _Spinner() : Icon(AppIcon.test.of(context), size: 16);
    if (models.length < 2 || _testing) {
      return TextButton.icon(
        onPressed: _testing ? null : () => _test(models.firstOrNull),
        icon: icon,
        label: Text('Test'.tr),
      );
    }
    return AppPopupMenuButton<String>(
      tooltip: 'Test a model'.tr,
      position: PopupMenuPosition.under,
      onSelected: _test,
      itemBuilder: (context) => [
        for (final m in models) menuItem(context, value: m, child: Text(m, overflow: TextOverflow.ellipsis)),
      ],
      child: IgnorePointer(child: TextButton.icon(onPressed: () {}, icon: icon, label: Text('Test'.tr))),
    );
  }

  /// What the last Test found, at the right of the key's label: its whole message in a hover text.
  Widget _testStatus(BuildContext context) {
    final tested = _tested;
    if (tested == null) return const SizedBox.shrink();
    final color = tested.ok
        ? (Theme.of(context).brightness == Brightness.dark ? const Color(0xFF5FCB8C) : const Color(0xFF1C8A4C))
        : Theme.of(context).colorScheme.error;
    return Align(
      alignment: Alignment.centerRight,
      child: Tip(
        message: tested.message,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon((tested.ok ? AppIcon.done : AppIcon.failed).of(context), size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(tested.message,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: color)),
          ),
        ]),
      ),
    );
  }
}

/// A heading that shows what is under it while [open] (Advanced), its arrow turning.
class _Disclosure extends StatelessWidget {
  const _Disclosure({required this.label, required this.open, required this.onToggle, required this.child});
  final String label;
  final bool open;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final muted = context.colors.textMuted;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          button: true,
          expanded: open,
          child: InkWell(
            onTap: onToggle,
            borderRadius: AppStyle.of(context).radius(6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                AnimatedRotation(
                  turns: open ? 0 : -0.25,
                  duration: stateDuration(motion(context, 150)),
                  curve: AppStyle.of(context).curve,
                  child: Icon(AppIcon.dropDown.of(context), size: 18, color: muted),
                ),
                const SizedBox(width: 4),
                _Label(label),
              ]),
            ),
          ),
        ),
      ),
      if (open) Padding(padding: const EdgeInsets.only(top: 8), child: child),
    ]);
  }
}

/// Custom headers and a custom body (a provider's, or a model's after it), in monospace, each
/// saying under it what of it isn't right.
class _RequestFields extends StatelessWidget {
  const _RequestFields({required this.headers, required this.body, required this.onHeaders, required this.onBody});
  final TextEditingController headers, body;
  final ValueChanged<String> onHeaders, onBody;

  /// What [parse] finds wrong in [text]; null when nothing.
  static String? problem(String text, void Function(String) parse) {
    try {
      parse(text);
      return null;
    } on AiError catch (e) {
      return e.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget field(TextEditingController controller, String label, String hint, String? problem, ValueChanged<String> onChanged) =>
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AppTextField(
            controller: controller,
            label: label,
            hint: hint,
            bad: problem != null,
            lines: 3,
            textStyle: monospace.copyWith(fontSize: 12.5),
            onChanged: onChanged,
          ),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(problem, style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.error)),
            ),
        ]);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      field(headers, 'Custom headers'.tr, 'Name: value'.tr, problem(headers.text, AiClient.headersIn), onHeaders),
      SizedBox(height: dialogGap(context)),
      field(body, 'Custom body'.tr, '{"temperature": 0}', problem(body.text, AiClient.bodyIn), onBody),
    ]);
  }
}

/// What went wrong talking to a provider, as the interface says it.
String _errorText(Object e) => e is AiError ? '$e' : describeError(e);

/// A field's label, as [FieldLabel] sets one (for a label with a button beside it).
class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final carbon = AppStyle.of(context).isCarbon;
    return Text(text,
        style: carbon
            ? TextStyle(fontSize: 12, height: 16 / 12, letterSpacing: 0.32, color: context.colors.textMuted)
            : TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: context.colors.textMuted));
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2));
}

/// How many models: a small grey pill.
class _CountBadge extends StatelessWidget {
  const _CountBadge(this.count);
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: colors.line.withValues(alpha: 0.7), borderRadius: AppStyle.of(context).radius(9)),
      child: Text('$count',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.textMuted)),
    );
  }
}

/// What is known of a model, small at the right of its ID: whether it reads images and whether it
/// reasons, as icons; its context, as 128K; each named in a hover text. Nothing for what isn't
/// known or it can't do.
class _Abilities extends StatelessWidget {
  const _Abilities(this.info);
  final AiModelInfo info;

  @override
  Widget build(BuildContext context) {
    final muted = context.colors.textMuted;
    final tokens = info.context;
    Widget icon(AppIcon icon, String tip) => Tip(
          message: tip,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: Icon(icon.of(context), size: 15, color: muted)),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (info.vision == true) icon(AppIcon.vision, 'Vision'.trIn('ability')),
      if (info.reasoning == true) icon(AppIcon.reasoning, 'Reasoning'.trIn('ability')),
      if (tokens != null)
        Tip(
          message: 'Context size: {tokens} tokens'.fill({'tokens': _grouped(tokens)}),
          child: Padding(
            padding: const EdgeInsets.only(left: 5, right: 2),
            child: Text(AiModelInfo.short(tokens),
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: muted, fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ),
    ]);
  }
}

/// [n] with its thousands apart: 131,072.
String _grouped(int n) => '$n'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

/// A context size in its field: grouped, nothing while it isn't known.
String _tokensText(int? tokens) => tokens == null ? '' : _grouped(tokens);

/// A model in the list: its ID, what is known of it ([_Abilities]), Edit Model and a remove
/// button; while models are being chosen ([picked] not null), a checkbox in front instead of
/// the buttons. A click edits it, or (choosing) ticks it.
class _ModelRow extends StatelessWidget {
  const _ModelRow(
      {required this.id,
      required this.info,
      required this.picked,
      required this.onTap,
      required this.onEdit,
      required this.onRemove});
  final String id;
  final AiModelInfo info;
  final bool? picked;
  final VoidCallback? onTap;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final picked = this.picked;
    return InkWell(
      onTap: onTap,
      hoverColor: onTap == null ? Colors.transparent : null,
      borderRadius: AppStyle.of(context).radius(10),
      child: SizedBox(
        height: 38,
        child: Padding(
          padding: EdgeInsets.only(left: picked == null ? 14 : 8, right: 6),
          child: Row(children: [
            if (picked != null) ...[
              SizedBox.square(
                  dimension: 18, child: IgnorePointer(child: Checkbox(value: picked, onChanged: (_) {}))),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(id, // a model's ID: not translated
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: colors.text)),
            ),
            _Abilities(info),
            if (picked == null) ...[
              const SizedBox(width: 4),
              ToolbarButton(icon: AppIcon.settings.of(context), tooltip: 'Edit model'.tr, color: colors.textMuted, onPressed: onEdit),
              ToolbarButton(icon: AppIcon.close.of(context), tooltip: 'Remove model'.tr, color: colors.textMuted, onPressed: onRemove),
            ] else
              const SizedBox(width: 8),
          ]),
        ),
      ),
    );
  }
}

/// Edit Provider… or Add Provider…: what was decided.
sealed class _ProviderEdit {
  const _ProviderEdit();
}

class _Changed extends _ProviderEdit {
  const _Changed(this.name, this.format);
  final String name;
  final AiFormat format;
}

class _Removed extends _ProviderEdit {
  const _Removed();
}

/// A provider's name and the API it speaks (a built-in one's is fixed); for one of the user's,
/// Delete…. Without a [provider], a new one's.
class _ProviderDialog extends StatefulWidget {
  const _ProviderDialog({this.provider});
  final AiProvider? provider;

  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends State<_ProviderDialog> {
  late final _name = TextEditingController(text: widget.provider?.name ?? '');
  late AiFormat _format = widget.provider?.format ?? AiFormat.openai;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _ready => _name.text.trim().isNotEmpty;

  void _done() {
    if (_ready) Navigator.pop(context, _Changed(_name.text.trim(), _format));
  }

  Future<void> _delete() async {
    final p = widget.provider!;
    final sure = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Delete “{name}”?'.fill({'name': p.name})),
        content: Text('Its key and models go with it.'.tr),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel'.tr)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Delete'.tr)),
        ],
      ),
    );
    if (sure == true && mounted) Navigator.pop(context, const _Removed());
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    return AppDialog(
      title: Text(p == null ? 'Add Provider'.tr : 'Edit Provider'.tr),
      content: SizedBox(
        width: dialogWidth(context, 320),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AppTextField(controller: _name, label: 'Name'.tr, autofocus: true, onSubmitted: (_) => _done()),
          if (p == null || !p.builtIn) ...[
            SizedBox(height: dialogGap(context)),
            AppDropdown<AiFormat>(
              label: 'API format'.tr,
              value: _format,
              isExpanded: true,
              items: [for (final f in AiFormat.values) DropdownMenuItem(value: f, child: Text(f.label))],
              onChanged: (f) => setState(() => _format = f ?? _format),
            ),
          ],
        ]),
      ),
      leading: [
        if (p != null && !p.builtIn) TextButton(onPressed: _delete, child: Text('Delete…'.tr)),
      ],
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(onPressed: _ready ? _done : null, child: Text(p == null ? 'Add'.tr : 'Save'.tr)),
      ],
    );
  }
}

/// Add Model: one model by its ID.
class _AddModelDialog extends StatefulWidget {
  const _AddModelDialog({required this.models});

  /// Those already there: not added twice.
  final List<String> models;

  @override
  State<_AddModelDialog> createState() => _AddModelDialogState();
}

class _AddModelDialogState extends State<_AddModelDialog> {
  final _id = TextEditingController();

  @override
  void initState() {
    super.initState();
    _id.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  String get _value => _id.text.trim();
  bool get _there => widget.models.contains(_value);
  bool get _ready => _value.isNotEmpty && !_there;

  void _done() {
    if (_ready) Navigator.pop(context, _value);
  }

  @override
  Widget build(BuildContext context) => AppDialog(
        title: Text('Add Model'.tr),
        content: SizedBox(
          width: dialogWidth(context, 320),
          child: AppTextField(
            controller: _id,
            label: 'Model ID'.tr,
            bad: _there,
            autofocus: true,
            onSubmitted: (_) => _done(),
          ),
        ),
        status: _there ? Text('Already added'.tr, style: TextStyle(color: Theme.of(context).colorScheme.error)) : null,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
          FilledButton(onPressed: _ready ? _done : null, child: Text('Add'.tr)),
        ],
      );
}

/// Edit Model: what is known of [model] (whether it reads images, whether it reasons, its context
/// size), set by hand or filled in from the provider's list (Fetch). Save answers it.
class _ModelDialog extends StatefulWidget {
  const _ModelDialog({required this.provider, required this.model});
  final AiProvider provider;
  final String model;

  @override
  State<_ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<_ModelDialog> {
  late AiModelInfo _info = widget.provider.infoOf(widget.model);
  late final _context = TextEditingController(text: _tokensText(_info.context));
  late final _headers = TextEditingController(text: _info.headers);
  late final _body = TextEditingController(text: _info.body);
  bool _fetching = false;
  late bool _advanced = _info.headers.trim().isNotEmpty || _info.body.trim().isNotEmpty;

  /// What Fetch found, [bad] when it found nothing.
  ({String text, bool bad})? _fetched;

  @override
  void dispose() {
    _context.dispose();
    _headers.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _contextBad => _context.text.trim().isNotEmpty && AiModelInfo.parseTokens(_context.text) == null;

  bool get _ready =>
      !_contextBad && _RequestFields.problem(_headers.text, AiClient.headersIn) == null && _RequestFields.problem(_body.text, AiClient.bodyIn) == null;

  /// Set by hand: a Fetch from the list after it leaves it as set.
  void _setByHand({bool? vision, bool? reasoning, int? Function()? tokens}) => setState(() {
        _info = AiModelInfo(
          vision: vision ?? _info.vision,
          reasoning: reasoning ?? _info.reasoning,
          context: tokens == null ? _info.context : tokens(),
          byHand: true,
        );
        _fetched = null;
      });

  Future<void> _fetch() async {
    setState(() {
      _fetching = true;
      _fetched = null;
    });
    final name = widget.provider.name;
    ({String text, bool bad}) fetched;
    try {
      final found = (await AiClient(widget.provider).models())[widget.model];
      if (!mounted) return;
      if (found == null) {
        fetched = (text: '{provider} doesn’t list this model.'.fill({'provider': name}), bad: true);
      } else if (found.isEmpty) {
        fetched = (text: '{provider} gives no details of this model.'.fill({'provider': name}), bad: false);
      } else {
        fetched = (text: 'Fetched from {provider}.'.fill({'provider': name}), bad: false);
        // What the list says, in place of what was set by hand.
        _info = AiModelInfo(vision: _info.vision, reasoning: _info.reasoning, context: _info.context).fetched(found);
        _context.text = _tokensText(_info.context);
      }
    } catch (e) {
      fetched = (text: _errorText(e), bad: true);
    }
    if (!mounted) return;
    setState(() {
      _fetching = false;
      _fetched = fetched;
    });
  }

  void _save() {
    if (!_ready) return;
    Navigator.pop(
        context,
        AiModelInfo(
            vision: _info.vision,
            reasoning: _info.reasoning,
            context: _info.context,
            byHand: _info.byHand,
            headers: _headers.text,
            body: _body.text));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fetched = _fetched;
    return AppDialog(
      title: Text('Edit Model'.tr),
      content: SizedBox(
        width: dialogWidth(context, 340),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          FieldLabel(
            label: 'Model ID'.tr,
            child: SelectableText(widget.model, style: TextStyle(fontSize: 14, color: colors.text)), // not translated
          ),
          SizedBox(height: dialogGap(context)),
          FieldLabel(
            label: 'Abilities'.tr,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              AppCheckRow(
                value: _info.vision == true,
                label: 'Vision'.trIn('ability'),
                named: true,
                trailing: Icon(AppIcon.vision.of(context), size: 16, color: colors.textMuted),
                onChanged: (v) => _setByHand(vision: v ?? false),
              ),
              AppCheckRow(
                value: _info.reasoning == true,
                label: 'Reasoning'.trIn('ability'),
                named: true,
                trailing: Icon(AppIcon.reasoning.of(context), size: 16, color: colors.textMuted),
                onChanged: (v) => _setByHand(reasoning: v ?? false),
              ),
            ]),
          ),
          SizedBox(height: dialogGap(context)),
          AppTextField(
            controller: _context,
            label: 'Context size'.tr,
            hint: '128K',
            bad: _contextBad,
            onChanged: (v) => _setByHand(tokens: () => AiModelInfo.parseTokens(v)),
            onSubmitted: (_) => _save(),
          ),
          SizedBox(height: dialogGap(context)),
          _Disclosure(
            label: 'Advanced'.tr,
            open: _advanced,
            onToggle: () => setState(() => _advanced = !_advanced),
            child: _RequestFields(headers: _headers, body: _body, onHeaders: (_) => setState(() {}), onBody: (_) => setState(() {})),
          ),
        ]),
      ),
      leading: [
        TextButton.icon(
          onPressed: _fetching ? null : _fetch,
          icon: _fetching ? const _Spinner() : Icon(AppIcon.fetch.of(context), size: 16),
          label: Text('Fetch'.tr),
        ),
      ],
      status: fetched == null
          ? null
          : Text(fetched.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: fetched.bad ? Theme.of(context).colorScheme.error : colors.textMuted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(onPressed: _ready ? _save : null, child: Text('Save'.tr)),
      ],
    );
  }
}

/// Fetch: the models the provider [offered] (with what its list says of each), those already
/// [chosen] ticked; Save keeps the ticked ones, those added by hand (not offered) as they were.
class _FetchedModelsDialog extends StatefulWidget {
  const _FetchedModelsDialog({required this.offered, required this.chosen});
  final Map<String, AiModelInfo> offered;
  final List<String> chosen;

  @override
  State<_FetchedModelsDialog> createState() => _FetchedModelsDialogState();
}

class _FetchedModelsDialogState extends State<_FetchedModelsDialog> {
  late final _ticked = {...widget.chosen.where(widget.offered.containsKey)};
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<String> get _result => [
        for (final m in widget.chosen)
          if (!widget.offered.containsKey(m) || _ticked.contains(m)) m,
        for (final m in widget.offered.keys)
          if (_ticked.contains(m) && !widget.chosen.contains(m)) m,
      ];

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final shown = [for (final m in widget.offered.keys) if (q.isEmpty || m.toLowerCase().contains(q)) m];
    final all = shown.isNotEmpty && _ticked.containsAll(shown);
    final none = !shown.any(_ticked.contains);
    return AppDialog(
      title: Text('Choose Models'.tr),
      divided: true,
      content: SizedBox(
        width: dialogWidth(context, 380),
        height: 360,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AppTextField(controller: _search, label: '', hint: 'Search models'.tr, autofocus: true),
          const SizedBox(height: 8),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(
                widget.offered.isEmpty ? 'The provider offers no models.'.tr : 'No matching models'.tr,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: context.colors.textMuted),
              ),
            )
          else ...[
            AppCheckRow(
              value: all ? true : (none ? false : null),
              tristate: true,
              bold: true,
              label: q.isEmpty ? 'All'.tr : 'All matching'.tr,
              onChanged: (_) => setState(() => all ? _ticked.removeAll(shown) : _ticked.addAll(shown)),
              trailing: Text('{n} of {all}'.fill({'n': shown.where(_ticked.contains).length, 'all': shown.length}),
                  style: TextStyle(fontSize: 12.5, color: context.colors.textMuted)),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (context, i) => AppCheckRow(
                  value: _ticked.contains(shown[i]),
                  label: shown[i],
                  named: true,
                  trailing: _Abilities(widget.offered[shown[i]]!),
                  onChanged: (_) => setState(() => _ticked.contains(shown[i]) ? _ticked.remove(shown[i]) : _ticked.add(shown[i])),
                ),
              ),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(onPressed: () => Navigator.pop(context, _result), child: Text('Save'.tr)),
      ],
    );
  }
}
