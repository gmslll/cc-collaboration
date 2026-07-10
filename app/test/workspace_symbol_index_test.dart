import 'dart:io';

import 'package:app/screens/workspace_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('symbol definition dialog size is responsive', () {
    expect(symbolDefinitionDialogWidth(const Size(1024, 900)), 720);
    expect(symbolDefinitionDialogWidth(const Size(320, 640)), 288);

    expect(symbolDefinitionDialogHeight(const Size(1024, 900), 20), 620);
    expect(
      symbolDefinitionDialogHeight(const Size(320, 420), 20),
      closeTo(344.4, 0.001),
    );
    expect(symbolDefinitionDialogHeight(const Size(320, 240), 20), 220);
  });

  test('symbol definition dialog avoids fixed desktop width', () {
    final source = File(
      'lib/screens/workspace/symbol_index.dart',
    ).readAsStringSync();
    final dialog = source.substring(
      source.indexOf('class _GoToDefinitionDialog'),
    );

    expect(dialog, contains('MediaQuery.sizeOf(context)'));
    expect(dialog, contains('symbolDefinitionDialogWidth'));
    expect(dialog, contains('symbolDefinitionDialogHeight'));
    expect(dialog, isNot(contains('width: 720')));
  });
}
