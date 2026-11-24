import 'package:flutter/foundation.dart';

/// Words for people, in English, that the app says in the language it is set to: what the
/// engine finds wrong (a script's line, a package's file) is said in them. [text] is the
/// English, each `{name}` in it standing for its value in [values], and a value that is words
/// too is said as its own. The app translates [text] as it does its own texts (`make l10n`
/// finds the literal each is made with here, as it finds the app's) and fills it in;
/// [toString] is the English, filled in.
@immutable
class Words {
  const Words(this.text, [this.values = const {}]);
  final String text;
  final Map<String, Object?> values;

  /// It in a language: [translate] gives each text's (its own, then its values' that are
  /// [Words]), each `{name}` then filled in.
  String said(String Function(String text) translate) => translate(text).replaceAllMapped(_placeholder, (m) {
        if (!values.containsKey(m[1])) return m[0]!;
        return switch (values[m[1]]) { final Words words => words.said(translate), final value => '$value' };
      });

  @override
  String toString() => said((text) => text);

  static final _placeholder = RegExp(r'\{(\w+)\}');
}

/// A [FormatException] whose message is [words]: what is wrong with a file, which the app says
/// in its own language ([message] is the English).
class WordsFormatException extends FormatException {
  const WordsFormatException(this.words);
  final Words words;

  @override
  String get message => '$words';
}
