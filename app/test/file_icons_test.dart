import 'package:app/file_icons.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fileIconAsset', () {
    String icon(String name) => fileIconAsset(name).split('/').last;

    test('maps by extension', () {
      expect(icon('main.go'), 'go.svg');
      expect(icon('app.dart'), 'dart.svg');
      expect(icon('1.md'), 'markdown.svg');
      expect(icon('deploy.sh'), 'console.svg');
      expect(icon('install.ps1'), 'powershell.svg');
      expect(icon('config.json'), 'json.svg');
      expect(icon('pubspec.yaml'), 'yaml.svg');
      expect(icon('.cc-handoff.toml'), 'toml.svg');
      expect(icon('index.tsx'), 'typescript.svg');
    });

    test('extension match is case-insensitive', () {
      expect(icon('PHOTO.PNG'), 'image.svg');
      expect(icon('Main.GO'), 'go.svg');
    });

    test('whole-name matches take precedence', () {
      expect(icon('go.mod'), 'go.svg');
      expect(icon('Makefile'), 'makefile.svg');
      expect(icon('Dockerfile'), 'docker.svg');
      expect(icon('LICENSE'), 'certificate.svg');
      expect(icon('.gitignore'), 'git.svg');
    });

    test('suffixed special names', () {
      expect(icon('Dockerfile.dev'), 'docker.svg');
      expect(icon('.env.local'), 'tune.svg');
    });

    test('unknown / extensionless falls back to file', () {
      expect(icon('README'), 'file.svg');
      expect(icon('weird.zzz'), 'file.svg');
      expect(icon('noext'), 'file.svg');
    });

    test('folder icon is the single folder glyph', () {
      expect(folderIconAsset.split('/').last, 'folder.svg');
    });
  });
}
