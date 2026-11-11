import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ai_providers.dart';
import 'app_colors.dart';
import 'app_icons.dart';
import 'app_settings.dart';
import 'dialog_kit.dart';
import 'error_text.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';
import 'l10n/l10n.dart';

/// Settings ▸ AI: the providers at the left, searched by name, each on or off, Add Provider…
/// under them; the chosen one's credentials and models at the right ([_ProviderPane]).
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

/// Over Settings ▸ AI while AI is hidden ([AppSettings.aiHidden]): that it is, and the switch
/// (Settings ▸ General's own) to show it again from the next launch.
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

/// A provider in the list: its initial in a circle, its name, and whether it is on.
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
              padding: const EdgeInsets.only(left: 6, right: 6),
              decoration: BoxDecoration(color: fill, borderRadius: style.radius(7)),
              child: Row(children: [
                _Initial(name: p.name),
                const SizedBox(width: 9),
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

/// A provider's first letter in a small tinted circle.
class _Initial extends StatelessWidget {
  const _Initial({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final letter = name.trim().isEmpty ? '?' : String.fromCharCode(name.trim().runes.first).toUpperCase();
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: AppStyle.of(context).isCarbon ? BoxShape.rectangle : BoxShape.circle,
        color: colors.accentSoft,
        border: Border.all(color: colors.accent.withValues(alpha: 0.25)),
      ),
      child: Text(letter, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.accentStrong)),
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
  final _modelSearch = TextEditingController();
  bool _keyShown = false, _searching = false, _selecting = false, _testing = false, _fetching = false;
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
    // Changed elsewhere (Edit Provider…'s format): the fields follow.
    if (_base.text != _p.baseUrl) _base.text = _p.baseUrl;
    if (_path.text != _p.path) _path.text = _p.path;
    if (_key.text != _p.apiKey) _key.text = _p.apiKey;
    _picked.retainAll(_p.models);
  }

  @override
  void dispose() {
    _key.dispose();
    _base.dispose();
    _path.dispose();
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
    _TestResult result;
    try {
      await AiClient(_p).test(model);
      result = (ok: true, message: 'Connected'.tr);
    } catch (e) {
      result = (ok: false, message: _errorText(e));
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _tested = result;
    });
  }

  Future<void> _fetch() async {
    setState(() => _fetching = true);
    final provider = _p;
    List<String>? offered;
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
    final chosen = await showAppDialog<List<String>>(
      context: context,
      builder: (_) => _FetchedModelsDialog(offered: offered!, chosen: _p.models),
    );
    if (chosen != null) _set(_p.copyWith(models: chosen));
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
        const SizedBox(height: 22),
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
                  picked: _selecting ? _picked.contains(m) : null,
                  onTap: _selecting ? () => setState(() => _picked.contains(m) ? _picked.remove(m) : _picked.add(m)) : null,
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

/// A model in the list: its ID, and a remove button; while models are being chosen ([picked] not
/// null), a checkbox in front instead.
class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.id, required this.picked, required this.onTap, required this.onRemove});
  final String id;
  final bool? picked;
  final VoidCallback? onTap;
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
            if (picked == null)
              ToolbarButton(icon: AppIcon.close.of(context), tooltip: 'Remove model'.tr, color: colors.textMuted, onPressed: onRemove),
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

/// Fetch: the models the provider [offered], those already [chosen] ticked; Save keeps the
/// ticked ones, those added by hand (not offered) as they were.
class _FetchedModelsDialog extends StatefulWidget {
  const _FetchedModelsDialog({required this.offered, required this.chosen});
  final List<String> offered;
  final List<String> chosen;

  @override
  State<_FetchedModelsDialog> createState() => _FetchedModelsDialogState();
}

class _FetchedModelsDialogState extends State<_FetchedModelsDialog> {
  late final _ticked = {...widget.chosen.where(widget.offered.contains)};
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
          if (!widget.offered.contains(m) || _ticked.contains(m)) m,
        for (final m in widget.offered)
          if (_ticked.contains(m) && !widget.chosen.contains(m)) m,
      ];

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final shown = [for (final m in widget.offered) if (q.isEmpty || m.toLowerCase().contains(q)) m];
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
