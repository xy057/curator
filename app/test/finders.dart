import 'package:curated_score/dialog_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The text field of the [AppTextField] with [label] (the label sits over its field in Refined).
Finder appField(String label) =>
    find.descendant(of: find.widgetWithText(AppTextField, label), matching: find.byType(TextField));
