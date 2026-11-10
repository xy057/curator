import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'ai_providers.dart';
import 'app_colors.dart';
import 'app_icons.dart';
import 'app_settings.dart';
import 'dialog_kit.dart';
import 'l10n/l10n.dart';
import 'menu_kit.dart';
import 'pdf_import_ai.dart';
import 'ui_kit.dart';

/// What a model's exam ([PdfAiExam]) lets it do, by the share it got right (whole percent): over
/// 95 it is used; over 85 too, with a word that some marks may need fixing; over 75 once Use
/// anyway is ticked; over 65 once a warning is confirmed; over 50 both, Use in red; no more, never.
enum PdfAiVerdict {
  pass,
  passWarned,
  ticked,
  confirmed,
  discouraged,
  incapable;

  static PdfAiVerdict of(int percent) => switch (percent) {
        > 95 => pass,
        > 85 => passWarned,
        > 75 => ticked,
        > 65 => confirmed,
        > 50 => discouraged,
        _ => incapable,
      };

  /// Whether Use anyway is to be ticked first.
  bool get ticks => this == ticked || this == discouraged;

  /// Whether a warning is to be confirmed.
  bool get confirms => this == confirmed || this == discouraged;

  /// Green, amber or red.
  Color color(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return switch (this) {
      pass || passWarned => dark ? const Color(0xFF5FCB8C) : const Color(0xFF1C8A4C),
      ticked || confirmed => dark ? const Color(0xFFE3B341) : const Color(0xFF9A6700),
      discouraged || incapable => Theme.of(context).colorScheme.error,
    };
  }

  String get title => switch (this) {
        pass || passWarned => 'Passed'.tr,
        ticked => 'Passed with mistakes'.tr,
        confirmed => 'Inaccurate'.tr,
        discouraged => 'Not recommended'.tr,
        incapable => 'Failed'.tr,
      };

  String get detail => switch (this) {
        pass => 'Reads PDF scores well.'.tr,
        passWarned => 'Some marks may need fixing.'.tr,
        ticked => 'Check its marks after reading.'.tr,
        confirmed => 'Many marks will need fixing.'.tr,
        discouraged => 'Most marks will need fixing.'.tr,
        incapable => 'This model can’t mark PDF scores.'.tr,
      };
}

/// [result]'s accuracy, whole percent: what [PdfAiVerdict.of] is told and the user is shown.
int pdfAiPercent(PdfAiExamResult result) => (result.accuracy * 100).round();

/// What part [part] of the exam is called.
String _partName(PdfAiExamPart part) => switch (part) {
      PdfAiExamPart.horizontal => 'Horizontal borders'.tr,
      PdfAiExamPart.barlines => 'Barlines'.tr,
      PdfAiExamPart.names => 'Instrument names'.tr,
      PdfAiExamPart.clefs => 'Clefs'.tr,
      PdfAiExamPart.keys => 'Key signatures'.tr,
      PdfAiExamPart.tempo => 'Tempo and time'.tr,
    };

/// Settings ▸ General ▸ AI for PDF import, and Read with AI with no model chosen: the model to
/// read with, each taking the exam ([PdfAiExam]) when chosen (its result kept, [AppSettings.pdfAiExam])
/// and used as its result allows ([PdfAiVerdict]). The model used, or null (Cancel, or None).
Future<AiModel?> showPdfAiModelDialog(BuildContext context, AppSettings settings) => showAppDialog<AiModel?>(
    context: context, barrierDismissible: false, builder: (_) => _PdfAiModelDialog(settings: settings));

class _PdfAiModelDialog extends StatefulWidget {
  const _PdfAiModelDialog({required this.settings});
  final AppSettings settings;

  @override
  State<_PdfAiModelDialog> createState() => _PdfAiModelDialogState();
}

class _PdfAiModelDialogState extends State<_PdfAiModelDialog> {
  AppSettings get settings => widget.settings;

  /// The model chosen ([AiModels.keyOf]); '' for none.
  late String _choice = settings.pdfAi == null ? '' : settings.pdfAiModel;

  /// The exam under way, and how many of its pages are answered.
  PdfAiExamRun? _run;
  int _done = 0;

  /// What went wrong in the last exam, in full.
  String? _error;

  /// Use anyway, ticked.
  bool _anyway = false;

  @override
  void dispose() {
    _run?.stop();
    super.dispose();
  }

  void _choose(String choice) {
    if (choice == _choice) return;
    setState(() {
      _choice = choice;
      _error = null;
      _anyway = false;
    });
    if (choice.isNotEmpty && settings.pdfAiExam(choice) == null) _start();
  }

  Future<void> _start() async {
    final key = _choice;
    final model = settings.aiProviders.model(key);
    if (model == null) return;
    final run = PdfAiExamRun(model);
    setState(() {
      _run = run;
      _done = 0;
      _error = null;
      _anyway = false;
    });
    try {
      final result = await run.run(onPage: (done, _) {
        if (mounted) setState(() => _done = done);
      });
      settings.setPdfAiExam(key, result);
    } on Object catch (e) {
      if (mounted && !run.stopped && _choice == key) setState(() => _error = '$e');
    } finally {
      if (mounted && _run == run) setState(() => _run = null);
    }
  }

  void _stop() {
    _run?.stop();
    setState(() => _run = null);
  }

  /// What the chosen model's exam allows; null: none chosen, or no result.
  PdfAiVerdict? get _verdict => switch (settings.pdfAiExam(_choice)) {
        final r? when _choice.isNotEmpty && _run == null && _error == null => PdfAiVerdict.of(pdfAiPercent(r)),
        _ => null,
      };

  /// Use: None at once; a model as its exam allows.
  VoidCallback? get _use {
    if (_run != null) return null;
    if (_choice.isEmpty) return () => _finish('');
    final verdict = _verdict;
    if (verdict == null || verdict == PdfAiVerdict.incapable || (verdict.ticks && !_anyway)) return null;
    return () => _confirmAndFinish(verdict);
  }

  Future<void> _confirmAndFinish(PdfAiVerdict verdict) async {
    if (verdict.confirms) {
      final percent = pdfAiPercent(settings.pdfAiExam(_choice)!);
      final red = verdict == PdfAiVerdict.discouraged ? verdict.color(context) : null;
      final ok = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppDialog(
          title: Text('Use an inaccurate model?'.tr),
          content: Text('It got {n}% of the exam right. Expect to fix its marks on every page.'.fill({'n': percent})),
          confirmsOnReturn: false,
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel'.tr)),
            FilledButton(
              style: red == null ? null : FilledButton.styleFrom(backgroundColor: red, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(context, true),
              child: Text('Use Anyway'.tr),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    _finish(_choice);
  }

  void _finish(String choice) {
    settings.pdfAiModel = choice;
    Navigator.pop(context, settings.pdfAi);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: settings, builder: (context, _) => _dialog(context));

  Widget _dialog(BuildContext context) {
    final models = settings.aiProviders.models;
    final verdict = _verdict;
    final red = verdict == PdfAiVerdict.discouraged ? verdict!.color(context) : null;
    return AppDialog(
        title: Text('AI for PDF Import'.tr),
        onEscape: () => Navigator.pop(context),
        content: SizedBox(
          width: dialogWidth(context, 400),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FieldLabel(
              label: 'Model',
              child: AppDropdown<String>(
                value: _choice,
                boxed: true,
                isExpanded: true,
                onChanged: _run == null ? (v) => _choose(v ?? '') : null,
                items: [
                  DropdownMenuItem(value: '', child: Text('None'.tr)),
                  for (final m in models)
                    DropdownMenuItem(value: AiModels.keyOf(m), child: Text('${m.model} · ${m.provider.name}', overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
            if (models.isEmpty) ...[
              const SizedBox(height: 8),
              Text('Turn on a provider in Settings ▸ AI to choose a model.'.tr, style: TextStyle(fontSize: 13, color: context.colors.textMuted)),
            ],
            if (_choice.isNotEmpty) ...[
              SizedBox(height: dialogGap(context)),
              _exam(context),
            ],
            if (verdict?.ticks ?? false) ...[
              const SizedBox(height: 8),
              AppCheckRow(value: _anyway, onChanged: (v) => setState(() => _anyway = v ?? false), label: 'Use anyway'),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
          FilledButton(
            style: red == null ? null : FilledButton.styleFrom(backgroundColor: red, foregroundColor: Colors.white),
            onPressed: _use,
            child: Text('Use'.tr),
          ),
        ],
    );
  }

  /// The chosen model's exam: under way, what went wrong, its result, or not taken yet.
  Widget _exam(BuildContext context) {
    final colors = context.colors;
    final muted = TextStyle(fontSize: 13, color: colors.textMuted);
    if (_run != null) {
      return Row(children: [
        const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Expanded(child: Text('Taking the exam… {n} of {count} pages'.fill({'n': _done, 'count': PdfAiExam.pages.length}))),
        TextButton.icon(onPressed: _stop, icon: Icon(AppIcon.close.of(context), size: 16), label: Text('Stop'.tr)),
      ]);
    }
    final again = TextButton.icon(onPressed: _start, icon: Icon(AppIcon.test.of(context), size: 16), label: Text('Run Again'.tr));
    if (_error case final error?) {
      final red = Theme.of(context).colorScheme.error;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(AppIcon.failed.of(context), size: 16, color: red),
          const SizedBox(width: 8),
          Expanded(child: Text('The exam couldn’t be run.'.tr, style: TextStyle(fontWeight: FontWeight.w600, color: red))),
          again,
        ]),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(maxHeight: 160),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: red.withValues(alpha: 0.08),
            border: Border.all(color: red.withValues(alpha: 0.4)),
            borderRadius: AppStyle.of(context).radius(8),
          ),
          child: SingleChildScrollView(child: SelectableText(error, style: const TextStyle(fontSize: 13))),
        ),
      ]);
    }
    final result = settings.pdfAiExam(_choice);
    if (result == null) {
      return Row(children: [
        Expanded(child: Text('Not tested yet.'.tr, style: muted)),
        OutlinedButton.icon(onPressed: _start, icon: Icon(AppIcon.test.of(context), size: 16), label: Text('Run Exam'.tr)),
      ]);
    }
    final percent = pdfAiPercent(result), verdict = PdfAiVerdict.of(percent), color = verdict.color(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Text('{n}%'.fill({'n': percent}), style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: color, height: 1.1)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(verdict.title, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
            Row(children: [
              if (verdict == PdfAiVerdict.passWarned) ...[
                Icon(AppIcon.warning.of(context), size: 14, color: PdfAiVerdict.ticked.color(context)),
                const SizedBox(width: 4),
              ],
              Flexible(child: Text(verdict.detail, style: muted)),
            ]),
          ]),
        ),
        again,
      ]),
      const SizedBox(height: 12),
      for (final part in PdfAiExamPart.values)
        SizedBox(
          height: 22,
          child: Row(children: [
            Expanded(child: Text(_partName(part), style: muted)),
            Text('{n}%'.fill({'n': (result.parts[part]! * 100).round()}), style: const TextStyle(fontSize: 13)),
          ]),
        ),
    ]);
  }
}
