/// [v] as a person writes it: a whole number without ".0" ("4", not "4.0"); otherwise as Dart
/// writes it, or with [digits] after the point.
String plainNumber(double v, {int? digits}) => v == v.roundToDouble() ? '${v.round()}' : (digits == null ? '$v' : v.toStringAsFixed(digits));
