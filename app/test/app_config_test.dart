import 'dart:io';

import 'package:app/local/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'publish sessions config defaults to private unless explicitly true',
    () {
      expect(AppConfig.parsePublishSessionsFlag(const {}), isFalse);
      expect(
        AppConfig.parsePublishSessionsFlag({'publish_sessions': false}),
        isFalse,
      );
      expect(
        AppConfig.parsePublishSessionsFlag({'publish_sessions': true}),
        isTrue,
      );
      expect(
        AppConfig.parsePublishSessionsFlag({'publish_sessions': 'true'}),
        isFalse,
      );
    },
  );

  test('workspace project config preserves relay project id', () {
    final source = File('lib/local/config.dart').readAsStringSync();

    expect(source, contains('final String projectId;'));
    expect(source, contains("p['project_id']"));
    expect(source, contains('ProjectCfg(name, path, github, projectId)'));
  });
}
