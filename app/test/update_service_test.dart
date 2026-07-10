import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('update prompt version title is width constrained', () {
    final source = File('lib/local/update_service.dart').readAsStringSync();
    final prompt = source.substring(
      source.indexOf('final go = await showDialog<bool>('),
      source.indexOf('if (go == true && context.mounted)'),
    );

    expect(prompt, isNot(contains("title: Text('发现新版本 \${info.version}')")));
    expect(prompt, contains("'发现新版本 \${info.version}',\n        maxLines: 1"));
    expect(prompt, contains('overflow: TextOverflow.ellipsis'));
  });
}
