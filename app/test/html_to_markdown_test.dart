import 'package:app/widgets/html_to_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('headings and paragraphs', () {
    test('converts h1-h3 with # prefixes', () {
      final r = htmlToMarkdown('<h1>Title</h1><h2>Sub</h2><h3>SubSub</h3>');
      expect(r.markdown, '# Title\n\n## Sub\n\n### SubSub');
    });

    test('paragraphs are separated by a blank line', () {
      final r = htmlToMarkdown('<p>One</p><p>Two</p>');
      expect(r.markdown, 'One\n\nTwo');
    });

    test('loose text without a wrapping <p> stays one paragraph', () {
      final r = htmlToMarkdown('Hello <b>world</b>, nice to see you.');
      expect(r.markdown, 'Hello **world**, nice to see you.');
    });
  });

  group('inline formatting', () {
    test('bold/italic/link render as markdown spans', () {
      final r = htmlToMarkdown(
          '<p>Hello <b>world</b>, <i>nice</i> to see you. '
          '<a href="https://x.com">link</a></p>');
      expect(r.markdown, 'Hello **world**, *nice* to see you. [link](https://x.com)');
    });

    test('strong/em are treated the same as b/i', () {
      final r = htmlToMarkdown('<p><strong>bold</strong> <em>italic</em></p>');
      expect(r.markdown, '**bold** *italic*');
    });

    test('emphasis markers hug the text, not surrounding whitespace', () {
      final r = htmlToMarkdown('<p>x <b> y </b> z</p>');
      expect(r.markdown, 'x  **y**  z');
    });

    test('a without href falls back to plain text', () {
      final r = htmlToMarkdown('<p><a>no href</a></p>');
      expect(r.markdown, 'no href');
    });

    test('inline code gets backtick-wrapped', () {
      final r = htmlToMarkdown('<p>Run <code>flutter test</code> now</p>');
      expect(r.markdown, 'Run `flutter test` now');
    });
  });

  group('lists', () {
    test('unordered list uses - markers', () {
      final r = htmlToMarkdown('<ul><li>One</li><li>Two</li></ul>');
      expect(r.markdown, '- One\n- Two');
    });

    test('ordered list numbers sequentially', () {
      final r = htmlToMarkdown('<ol><li>One</li><li>Two</li><li>Three</li></ol>');
      expect(r.markdown, '1. One\n2. Two\n3. Three');
    });

    test('nested list is indented under its parent item', () {
      final r = htmlToMarkdown(
          '<ul><li>Parent<ul><li>Child</li></ul></li></ul>');
      expect(r.markdown, '- Parent\n  - Child');
    });
  });

  group('blockquote', () {
    test('each line gets a > prefix', () {
      final r = htmlToMarkdown('<blockquote>quoted text</blockquote>');
      expect(r.markdown, '> quoted text');
    });
  });

  group('code blocks', () {
    test('pre preserves raw whitespace/newlines in a fenced block', () {
      final r = htmlToMarkdown('<pre>line one\n  line two</pre>');
      expect(r.markdown, '```\nline one\n  line two\n```');
    });
  });

  group('images', () {
    test('img becomes a placeholder and its src is collected in order', () {
      final r = htmlToMarkdown(
          '<p>Look:</p><img src="https://example.com/a.png">'
          '<img src="https://example.com/b.png">');
      expect(r.imageSrcs, ['https://example.com/a.png', 'https://example.com/b.png']);
      expect(r.markdown, contains(imgPlaceholder(0)));
      expect(r.markdown, contains(imgPlaceholder(1)));
      expect(r.markdown, startsWith('Look:'));
    });

    test('placeholders are stable and resolvable via string replacement', () {
      final r = htmlToMarkdown('<img src="https://example.com/a.png">');
      final resolved = r.markdown.replaceFirst(imgPlaceholder(0), '![](pasted-1.png)');
      expect(resolved, '![](pasted-1.png)');
    });
  });

  group('unknown/unsupported tags degrade gracefully', () {
    test('script/style content is stripped entirely, not surfaced as text', () {
      final r = htmlToMarkdown('<style>body{color:red}</style><p>Hi</p>');
      expect(r.markdown, 'Hi');
    });

    test('unrecognized tags (span/table) fall back to their flattened text', () {
      final r = htmlToMarkdown(
          '<table><tr><td>Cell <span>text</span></td></tr></table>');
      expect(r.markdown, 'Cell text');
    });

    test('div is treated like a block container, not dropped', () {
      final r = htmlToMarkdown('<div>One</div><div>Two</div>');
      expect(r.markdown, 'One\n\nTwo');
    });
  });

  group('degenerate input never throws', () {
    test('empty string', () {
      final r = htmlToMarkdown('');
      expect(r.isEmpty, isTrue);
    });

    test('plain unclosed/malformed tags', () {
      expect(() => htmlToMarkdown('<p>unclosed <b>bold'), returnsNormally);
    });

    test('only whitespace/comments', () {
      final r = htmlToMarkdown('<!-- just a comment -->   ');
      expect(r.isEmpty, isTrue);
    });
  });
}
