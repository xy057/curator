import 'dart:io';

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'project_file.dart';
import 'ui_kit.dart';

/// What shows before anything is open: one Open for projects and scores alike, the sample,
/// and the files opened lately.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.recentFiles,
    required this.onOpen,
    required this.onOpenRecent,
    required this.onRemoveRecent,
    required this.onClearRecent,
    required this.onOpenSample,
  });

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
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [colors.accent, colors.accentStrong],
                    ),
                    boxShadow: [BoxShadow(color: colors.accent.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 6))],
                  ),
                  child: const Icon(Icons.library_music_rounded, size: 34, color: Colors.white),
                ),
              ),
              const SizedBox(height: 18),
              _Entrance(
                delay: 1,
                child: Column(children: [
                  Text('Curated Score', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(
                    'One continuous line of music scrolling past a fixed pointer. '
                    'Each instrument glides in only while it plays.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: colors.textMuted, height: 1.4),
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
                      message: 'A Curated Score project, or a MusicXML score to start one (${shortcut('⌘O')})',
                      child: FilledButton.icon(
                        onPressed: onOpen,
                        icon: const Icon(Icons.folder_open_rounded, size: 18),
                        label: const Text('Open…'),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: onOpenSample,
                      icon: const Icon(Icons.play_circle_outline_rounded, size: 18),
                      label: const Text('Try the sample'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _Entrance(
                delay: 2,
                child: Text(
                  'Projects (.ccs) and MusicXML scores (.musicxml, .mxl) — or drop one anywhere.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.textMuted),
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
        duration: Duration(milliseconds: 420 + delay * 70),
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
        decoration: BoxDecoration(border: Border.all(color: colors.line), borderRadius: BorderRadius.circular(10)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Column(children: [
            for (final (i, path) in files.indexed) ...[
              if (i > 0) Divider(height: 1, color: colors.line),
              _RecentRow(path: path, onOpen: () => onOpen(path), onRemove: () => onRemove(path)),
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

  String get _name => widget.path.split(RegExp(r'[/\\]')).last;

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
          duration: const Duration(milliseconds: 120),
          color: _hover && _exists ? colors.accentWash : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
          child: Row(children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: _exists ? colors.accentSoft : colors.grid,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                _isProject ? Icons.movie_filter_outlined : Icons.queue_music_rounded,
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
              duration: const Duration(milliseconds: 120),
              // Hidden until hovered, but always there for VoiceOver (and its tooltip's overlay).
              alwaysIncludeSemantics: true,
              child: ToolbarButton(
                icon: Icons.close_rounded,
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
