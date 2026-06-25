import 'package:app/plugins/format_plugin.dart';
import 'package:app/plugins/plugin_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final mgr = PluginManager.instance;

  // The manager is a singleton; reset to a known state before each test:
  // every plugin enabled, every tool marked unavailable.
  setUp(() {
    for (final p in kFormatPlugins) {
      mgr.setEnabled(p.id, true);
      if (!p.builtIn) mgr.debugSetAvailable(p.id, false);
    }
  });

  group('catalog integrity', () {
    test('ids are unique', () {
      final ids = kFormatPlugins.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('formatters carry a tool + args; renderers do not', () {
      for (final p in kFormatPlugins) {
        if (p.kind == PluginKind.formatter) {
          expect(p.tool, isNotNull, reason: '${p.id} needs a tool');
          expect(p.args, isNotNull, reason: '${p.id} needs args');
        } else {
          expect(p.builtIn, isTrue, reason: '${p.id} renderer is built-in');
        }
      }
    });

    test('extensions are lowercase', () {
      for (final p in kFormatPlugins) {
        for (final e in p.exts) {
          expect(e, e.toLowerCase());
        }
      }
    });
  });

  group('formatterCatalogFor (availability-independent)', () {
    test('maps known extensions', () {
      expect(mgr.formatterCatalogFor('go')?.id, 'gofmt');
      expect(mgr.formatterCatalogFor('dart')?.id, 'dartfmt');
      expect(mgr.formatterCatalogFor('py')?.id, 'black');
      expect(mgr.formatterCatalogFor('rs')?.id, 'rustfmt');
      expect(mgr.formatterCatalogFor('json')?.id, 'prettier');
      expect(mgr.formatterCatalogFor('ts')?.id, 'prettier');
    });

    test('is case-insensitive', () {
      expect(mgr.formatterCatalogFor('GO')?.id, 'gofmt');
    });

    test('markdown has no formatter (render-only)', () {
      expect(mgr.formatterCatalogFor('md'), isNull);
    });

    test('unknown extension → null', () {
      expect(mgr.formatterCatalogFor('zzz'), isNull);
    });
  });

  group('formatterFor (gated by enabled + available)', () {
    test('null until the tool is detected available', () {
      expect(mgr.formatterFor('go'), isNull); // not available yet
      mgr.debugSetAvailable('gofmt', true);
      expect(mgr.formatterFor('go')?.id, 'gofmt');
    });

    test('disabling hides an otherwise-available formatter', () {
      mgr.debugSetAvailable('gofmt', true);
      expect(mgr.formatterFor('go')?.id, 'gofmt');
      mgr.setEnabled('gofmt', false);
      expect(mgr.formatterFor('go'), isNull);
    });

    test('unavailable tool is never returned even when enabled', () {
      mgr.debugSetAvailable('prettier', false);
      expect(mgr.formatterFor('ts'), isNull);
    });
  });

  group('rendererFor', () {
    test('markdown renderer follows enable state', () {
      expect(mgr.rendererFor('md')?.id, 'markdown');
      expect(mgr.rendererFor('markdown')?.id, 'markdown');
      mgr.setEnabled('markdown', false);
      expect(mgr.rendererFor('md'), isNull);
    });

    test('non-markdown has no renderer', () {
      expect(mgr.rendererFor('go'), isNull);
    });
  });
}
