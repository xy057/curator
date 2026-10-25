import 'dart:io';

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'app_logo.dart';
import 'app_settings.dart';
import 'file_names.dart';
import 'project_file.dart';
import 'ui_kit.dart';

/// What shows before anything is open: one Open for projects and scores alike, the sample,
/// and the files opened lately. Terse on purpose: a name, a line, what to open.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.settings,
    required this.recentFiles,
    required this.onOpen,
    required this.onOpenRecent,
    required this.onRemoveRecent,
    required this.onClearRecent,
    required this.onOpenSample,
  });

  /// For the icon up top ([AppLogo]).
  final AppSettings settings;
  final List<String> recentFiles;
  final VoidCallback onOpen;
  final ValueChanged<String> onOpenRecent;
  final ValueChanged<String> onRemoveRecent;
  final VoidCallback onClearRecent;
  final VoidCallback onOpenSample;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Entrance(
                delay: 0,
                child: AppLogo(settings: settings, size: 80),
              ),
              const SizedBox(height: 18),
              _Entrance(
                delay: 1,
                child: Column(children: [
                  // The page's one heading: large, bold and set tight, the line under it quiet.
                  Text('Curator',
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.4, height: 1.15)),
                  const SizedBox(height: 6),
                  Text(
                    'Scores that follow the music.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(color: colors.textMuted, height: 1.4),
                  ),
                ]),
              ),
              const SizedBox(height: 24),
              _Entrance(
                delay: 2,
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    Tip(
                      message: 'Project or MusicXML (${shortcut('⌘O')})',
                      child: FilledButton.icon(
                        onPressed: onOpen,
                        icon: Icon(AppIcon.open.of(context), size: 18),
                        label: const Text('Open…'),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: onOpenSample,
                      icon: Icon(AppIcon.demo.of(context), size: 18),
                      label: const Text('Open Sample'),
                    ),
                  ],
                ),
              ),
              if (recentFiles.isNotEmpty) ...[
                const SizedBox(height: 32),
                _Entrance(
                  delay: 3,
                  child: _RecentList(
                    files: recentFiles,
                    onOpen: onOpenRecent,
                    onRemove: onRemoveRecent,
                    onClear: onClearRecent,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Fades and rises into place, a beat after the element above it.
class _Entrance extends StatelessWidget {
  const _Entrance({required this.delay, required this.child});
  final int delay;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: AppStyle.of(context).moving(Duration(milliseconds: 420 + delay * 70)),
        curve: Interval(delay * 0.12, 1, curve: Curves.easeOutCubic),
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, (1 - t) * 12), child: child),
        ),
        child: child,
      );
}

class _RecentList extends StatelessWidget {
  const _RecentList({required this.files, required this.onOpen, required this.onRemove, required this.onClear});
  final List<String> files;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text('RECENT',
              style: TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w600, color: colors.textMuted)),
        ),
        const Spacer(),
        TextButton(
          onPressed: onClear,
          style: TextButton.styleFrom(foregroundColor: colors.textMuted, textStyle: const TextStyle(fontSize: 12)),
          child: const Text('Clear'),
        ),
      ]),
      const SizedBox(height: 4),
      DecoratedBox(
        // Raised a little in Refined's light theme (a tight shadow under a soft one), as a card
        // to click is; flat in the dark and in Carbon.
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.line),
          borderRadius: AppStyle.of(context).radius(10),
          boxShadow: CarbonColors.maybeOf(context) != null || Theme.of(context).brightness == Brightness.dark
              ? null
              : const [
                  BoxShadow(color: Color(0x0F000000), blurRadius: 2, offset: Offset(0, 1)),
                  BoxShadow(color: Color(0x0A000000), blurRadius: 12, offset: Offset(0, 4)),
                ],
        ),
        child: ClipRRect(
          borderRadius: AppStyle.of(context).radius(10),
          child: Column(children: [
            for (final (i, path) in files.indexed) ...[
              if (i > 0) Divider(height: 1, color: colors.line),
              // A hover repaints its own row, not the list.
              RepaintBoundary(
                child: _RecentRow(path: path, onOpen: () => onOpen(path), onRemove: () => onRemove(path)),
              ),
            ],
          ]),
        ),
      ),
    ]);
  }
}

class _RecentRow extends StatefulWidget {
  const _RecentRow({required this.path, required this.onOpen, required this.onRemove});
  final String path;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _hover = false;
  late final bool _exists = File(widget.path).existsSync();

  static final _home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  String get _name => fileNameOf(widget.path);

  String get _folder {
    final parts = widget.path.split(RegExp(r'[/\\]'));
    var folder = parts.sublist(0, parts.length - 1).join(Platform.pathSeparator);
    final home = _home;
    if (home != null && folder.startsWith(home)) folder = '~${folder.substring(home.length)}';
    return folder;
  }

  bool get _isProject => widget.path.toLowerCase().endsWith('.${ProjectFile.extension}');

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: _exists ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _exists ? widget.onOpen : null,
        child: AnimatedContainer(
          duration: stateDuration(motion(context, 120)),
          // From the wash at no opacity, not Colors.transparent (black): a fade from black dims the
          // row through grey on the way.
          color: colors.accentWash.withValues(alpha: _hover && _exists ? 1 : 0),
          padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
          child: Row(children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: _exists ? colors.accentSoft : colors.grid,
                borderRadius: AppStyle.of(context).radius(8),
              ),
              child: Icon(
                _isProject ? AppIcon.project.of(context) : AppIcon.score.of(context),
                size: 17,
                color: _exists ? colors.accentStrong : colors.textMuted,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: _exists ? colors.text : colors.textMuted)),
                const SizedBox(height: 1),
                Text(_exists ? _folder : 'Not found · $_folder',
                    overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: colors.textMuted)),
              ]),
            ),
            AnimatedOpacity(
              opacity: _hover || !_exists ? 1 : 0,
              duration: motion(context, 120),
              // Hidden until hovered, but always there for VoiceOver (and its tooltip's overlay).
              alwaysIncludeSemantics: true,
              child: ToolbarButton(
                icon: AppIcon.close.of(context),
                tooltip: 'Remove from Recent',
                color: colors.textMuted,
                onPressed: widget.onRemove,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
