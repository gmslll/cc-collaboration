import 'package:app/local/path_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pathBaseName', () {
    test('handles POSIX and Windows separators', () {
      expect(pathBaseName('/tmp/project/lib/main.dart'), 'main.dart');
      expect(pathBaseName(r'E:\demoFile\oppr\package.json'), 'package.json');
      expect(pathBaseName(r'E:\demoFile\oppr\'), 'oppr');
      expect(pathBaseName(r'E:\demoFile\oppr/src/main.dart'), 'main.dart');
    });
  });

  group('pathJoin', () {
    test('preserves Windows-style separators when the parent uses them', () {
      expect(pathJoin(r'E:\demoFile\oppr', 'src'), r'E:\demoFile\oppr\src');
      expect(pathJoin('/tmp/project', 'src'), '/tmp/project/src');
    });
  });

  group('pathWithin and pathRelativeTo', () {
    test('match children across mixed separators', () {
      expect(
        pathWithin(r'E:\demoFile\oppr\Src\Main.dart', r'E:\demoFile\oppr'),
        isTrue,
      );
      expect(
        pathWithin(r'E:\demoFile\oppr/Src/Main.dart', r'E:\demoFile\oppr'),
        isTrue,
      );
      expect(
        pathRelativeTo(r'E:\demoFile\oppr', r'E:\demoFile\oppr\Src\Main.dart'),
        'Src/Main.dart',
      );
    });

    test('are case-insensitive for Windows drive paths', () {
      expect(pathWithin(r'e:\demoFile\oppr\src', r'E:\demoFile\oppr'), isTrue);
    });

    test('reject paths outside the root after dot segment normalization', () {
      expect(
        pathWithin(r'E:\demoFile\oppr\..\other', r'E:\demoFile\oppr'),
        isFalse,
      );
    });

    test('do not treat relative POSIX paths as absolute children', () {
      expect(pathWithin('tmp/project/file.dart', '/tmp/project'), isFalse);
      expect(pathWithin('/tmp/project/file.dart', '/tmp/project'), isTrue);
      expect(
        pathRelativeTo('/tmp/project', '/tmp/project/lib/Main.dart'),
        'lib/Main.dart',
      );
    });

    test('POSIX root contains absolute descendants', () {
      expect(pathWithin('/tmp/project', '/'), isTrue);
      expect(pathRelativeTo('/', '/tmp/project'), 'tmp/project');
    });
  });
}
