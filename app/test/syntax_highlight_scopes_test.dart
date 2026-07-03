import 'package:app/editor_theme.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/re_highlight.dart';

// Regression test for the editor's syntax-highlighting scope coverage. It
// exercises the real tokenizers (re_highlight's Go/Dart Mode definitions,
// including the vendored Dart "type" patch — see
// third_party/re_highlight/lib/languages/dart.dart) so the theme's key list
// is driven by measurement of actual hljs-* scopes rather than guessing from
// the language grammar source.
void main() {
  final hl = Highlight()..registerLanguages({'go': langGo, 'dart': langDart});

  const goSample = '''
const (
    TerminalAppTerminal = "terminal"
)

// UserConfigPath returns the canonical user-level config path.
func UserConfigPath() (string, error) {
    if runtime.GOOS == "windows" {
        dir, err := os.UserConfigDir()
        if err != nil {
            return "", err
        }
        return filepath.Join(dir, "cc-handoff", "config.toml"), nil
    }
    return "", nil
}
''';

  const dartSample =
      'class Foo { final String name; int count = 0; Foo(this.name); }';

  test('Go tokens land on the expected hljs scopes', () {
    final html = hl.highlight(code: goSample, language: 'go').toHtml();
    expect(html, contains('class="hljs-keyword">const'));
    expect(html, contains('class="hljs-keyword">if'));
    expect(html, contains('class="hljs-keyword">return'));
    expect(html, contains('class="hljs-string">&quot;terminal&quot;'));
    expect(html, contains('class="hljs-comment">// UserConfigPath'));
    // `func` sugar (beginKeywords) nests as keyword+title+params inside a
    // "function" wrapper mode rather than getting its own top-level scope.
    expect(html, contains('class="hljs-function">'));
    expect(html, contains('class="hljs-keyword">func'));
    expect(html, contains('class="hljs-title">UserConfigPath'));
    // Return types (string, error) are plain root-level `type` scope, not
    // nested under "function" (the params mode's endsParent closes it first).
    expect(html, contains('class="hljs-type">string'));
    expect(html, contains('class="hljs-type">error'));
    expect(html, contains('class="hljs-literal">nil'));
  });

  test('Dart tokens land on the expected hljs scopes', () {
    final html = hl.highlight(code: dartSample, language: 'dart').toHtml();
    expect(html, contains('class="hljs-keyword">class'));
    expect(html, contains('class="hljs-title">Foo'));
    expect(html, contains('class="hljs-keyword">final'));
    // Vendored patch: String/int are their own "type" scope, not "built_in".
    expect(html, contains('class="hljs-type">String'));
    expect(html, contains('class="hljs-type">int'));
    expect(html, isNot(contains('class="hljs-built_in">String')));
    expect(html, isNot(contains('class="hljs-built_in">int')));
    expect(html, contains('class="hljs-number">0'));
  });

  group('ccCodeTheme resolution', () {
    // The diff viewer (syntax.dart's TextSpanRenderer, from re_highlight
    // itself) looks up a node's own scope directly in the theme map — no
    // parent-scope compounding. So these checks target the raw scope keys
    // that highlightLine() actually renders with. (The code-editor's
    // re_editor engine additionally compounds nested scopes like
    // "function-keyword" and strips prefixes until a match is found — a leaf
    // key existing here is sufficient for that path to resolve too.)
    test('keyword is warm, not atomOneDark violet', () {
      final style = ccCodeTheme['keyword'];
      expect(style, isNotNull);
      expect(style!.color, isNot(const Color(0xffc678dd)));
    });

    test('type and literal are italic cyan (types/constants)', () {
      for (final key in ['type', 'literal']) {
        final style = ccCodeTheme[key];
        expect(style, isNotNull, reason: '$key must be styled');
        expect(
          style!.fontStyle,
          FontStyle.italic,
          reason: '$key must be italic',
        );
        expect(style.color, const Color(0xFF56B6C2), reason: '$key must be cyan');
      }
    });

    test('string/comment/title are inherited from atomOneDarkTheme unchanged', () {
      expect(ccCodeTheme['string']!.color, const Color(0xff98c379));
      expect(ccCodeTheme['comment']!.color, const Color(0xff5c6370));
      expect(ccCodeTheme['comment']!.fontStyle, FontStyle.italic);
      expect(ccCodeTheme['title']!.color, const Color(0xff61aeee));
    });

    test('every scope actually hit by the Go/Dart samples has a theme entry', () {
      // Diff-view style resolution: an open node's OWN scope (not compounded
      // with ancestors) is what gets looked up — so walk the render tree and
      // check every non-null leaf scope directly against ccCodeTheme. Skips
      // wrapper scopes (function, class, params) that only group children
      // and carry no visible text of their own in these samples.
      const wrapperScopes = {'function', 'class', 'params'};
      final missing = <String>{};
      void check(String language, String code) {
        final result = hl.highlight(code: code, language: language);
        final openScopes = <String?>[];
        result.render(_RecordingRenderer(
          onOpen: (scope) => openScopes.add(scope?.split('.').first),
          onClose: () => openScopes.removeLast(),
          onText: (text) {
            if (text.trim().isEmpty) return;
            final scope = openScopes.isEmpty ? null : openScopes.last;
            if (scope == null || wrapperScopes.contains(scope)) return;
            if (!ccCodeTheme.containsKey(scope)) missing.add(scope);
          },
        ));
      }

      check('go', goSample);
      check('dart', dartSample);
      expect(missing, isEmpty, reason: 'ccCodeTheme is missing: $missing');
    });
  });
}

class _RecordingRenderer implements HighlightRenderer {
  final void Function(String? scope) onOpen;
  final void Function() onClose;
  final void Function(String text) onText;

  _RecordingRenderer({
    required this.onOpen,
    required this.onClose,
    required this.onText,
  });

  @override
  void addText(String text) => onText(text);

  @override
  void openNode(DataNode node) => onOpen(node.scope);

  @override
  void closeNode(DataNode node) => onClose();
}
