import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

// htmlToMarkdown converts a clipboard HTML fragment (Linear/Notion/browser
// "copy" payloads) into the same literal markdown subset
// markdown_lite_editor.dart already knows how to render: headings,
// bold/italic, links, un/ordered lists, paragraphs and images. It is
// intentionally not a general HTML→Markdown engine — unrecognized tags
// (table/div-soup, styling spans, etc.) degrade to their flattened text
// content rather than erroring, since the only inputs this ever sees are
// clipboard fragments from a handful of known sources.
//
// Images can't be resolved to a `![](name)` reference here (that requires
// downloading + uploading via RelayClient, which is the caller's job), so
// each `<img src>` is instead replaced with an [imgPlaceholder] token and
// its `src` collected in [HtmlToMarkdownResult.imageSrcs] in document
// order. The caller resolves placeholder i to imageSrcs[i]'s upload result
// with `markdown.replaceFirst(imgPlaceholder(i), '![](name)')`, or drops it
// with an empty replacement if the image couldn't be fetched.

const _imgMarkerPrefix = '<<<CC_IMG_';
const _imgMarkerSuffix = '>>>';

String imgPlaceholder(int index) => '$_imgMarkerPrefix$index$_imgMarkerSuffix';

class HtmlToMarkdownResult {
  final String markdown;
  final List<String> imageSrcs;

  const HtmlToMarkdownResult({required this.markdown, required this.imageSrcs});

  bool get isEmpty => markdown.trim().isEmpty && imageSrcs.isEmpty;
}

HtmlToMarkdownResult htmlToMarkdown(String html) {
  final document = html_parser.parse(html);
  final images = <String>[];
  final root = document.body ?? document.documentElement;
  final blocks = root == null ? <String>[] : _blockify(root, images);
  final markdown = blocks.where((b) => b.trim().isNotEmpty).join('\n\n').trim();
  return HtmlToMarkdownResult(markdown: markdown, imageSrcs: images);
}

String _normalizeWhitespace(String raw) => raw.replaceAll(RegExp(r'\s+'), ' ');

// Wraps non-whitespace core of [inner] with [marker] on both sides while
// keeping any leading/trailing whitespace outside the markers — `** x **`
// isn't valid CommonMark emphasis, `x **y** z` (from `x <b> y </b> z`) is.
String _wrapEmphasis(String inner, String marker) {
  final core = inner.trim();
  if (core.isEmpty) return inner;
  final leading = inner.substring(0, inner.length - inner.trimLeft().length);
  final trailing = inner.substring(inner.trimRight().length);
  return '$leading$marker$core$marker$trailing';
}

// Flattens a subtree into a single inline string: text runs concatenated,
// whitespace collapsed, <br> as a literal newline, <b>/<i>/<a> converted to
// their markdown spans, everything else (including stray block tags found
// mid-inline-content) just recursed into for its text. Never splits into
// multiple paragraphs/blocks — used for content that must stay one line
// (heading/paragraph/list-item text), even if the source HTML nests block
// tags inside it.
String _flattenInlineOnly(dom.Node node, List<String> images, {Set<dom.Element>? skip}) {
  final buf = StringBuffer();
  for (final child in node.nodes) {
    if (child is dom.Text) {
      buf.write(_normalizeWhitespace(child.text));
      continue;
    }
    if (child is! dom.Element) continue;
    if (skip != null && skip.contains(child)) continue;
    final tag = child.localName?.toLowerCase() ?? '';
    switch (tag) {
      case 'script':
      case 'style':
        break;
      case 'br':
        buf.write('\n');
        break;
      case 'img':
        final src = child.attributes['src'];
        if (src != null && src.isNotEmpty) {
          images.add(src);
          buf.write(imgPlaceholder(images.length - 1));
        }
        break;
      case 'b':
      case 'strong':
        buf.write(_wrapEmphasis(_flattenInlineOnly(child, images), '**'));
        break;
      case 'i':
      case 'em':
        buf.write(_wrapEmphasis(_flattenInlineOnly(child, images), '*'));
        break;
      case 'a':
        final href = child.attributes['href'];
        final text = _flattenInlineOnly(child, images).trim();
        if (text.isNotEmpty) {
          buf.write(href != null && href.isNotEmpty ? '[$text]($href)' : text);
        }
        break;
      case 'code':
        final text = _flattenInlineOnly(child, images).trim();
        if (text.isNotEmpty) buf.write('`$text`');
        break;
      case 'pre':
        // Raw text (not the whitespace-collapsing recursive walk below) —
        // a <pre> is exactly the case where the original newlines/indent
        // are the content, not incidental formatting whitespace.
        buf.write(child.text);
        break;
      default:
        buf.write(_flattenInlineOnly(child, images));
    }
  }
  return buf.toString();
}

String _renderList(dom.Element listEl, List<String> images, int depth) {
  final ordered = listEl.localName?.toLowerCase() == 'ol';
  final lines = <String>[];
  var index = 1;
  for (final li in listEl.children) {
    if (li.localName?.toLowerCase() != 'li') continue;
    final nestedLists = li.children
        .where((c) => const {'ul', 'ol'}.contains(c.localName?.toLowerCase()))
        .toSet();
    final indent = '  ' * depth;
    final marker = ordered ? '${index++}. ' : '- ';
    final text = _flattenInlineOnly(li, images, skip: nestedLists).trim();
    lines.add('$indent$marker$text');
    for (final nested in nestedLists) {
      final nestedText = _renderList(nested, images, depth + 1);
      if (nestedText.trim().isNotEmpty) lines.add(nestedText);
    }
  }
  return lines.join('\n');
}

// Walks [root]'s direct children, splitting them into block-level chunks
// (paragraphs/headings/lists/blockquotes, one entry per block) with
// consecutive loose text/inline-tag siblings (a fragment copied without a
// wrapping <p>, e.g. a plain-text browser selection) folded into a single
// implicit paragraph block instead of exploding into one block per node.
List<String> _blockify(dom.Node root, List<String> images) {
  final blocks = <String>[];
  final inlineBuf = StringBuffer();
  void flushInline() {
    final t = inlineBuf.toString().trim();
    if (t.isNotEmpty) blocks.add(t);
    inlineBuf.clear();
  }

  for (final child in root.nodes) {
    if (child is dom.Text) {
      inlineBuf.write(_normalizeWhitespace(child.text));
      continue;
    }
    if (child is! dom.Element) continue;
    final tag = child.localName?.toLowerCase() ?? '';
    switch (tag) {
      case 'script':
      case 'style':
      case 'head':
      case 'title':
        break;
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        flushInline();
        final level = int.parse(tag.substring(1));
        final text = _flattenInlineOnly(child, images).trim();
        if (text.isNotEmpty) blocks.add('${'#' * level} $text');
        break;
      case 'p':
      case 'blockquote':
        flushInline();
        final text = _flattenInlineOnly(child, images).trim();
        if (text.isNotEmpty) {
          blocks.add(tag == 'blockquote'
              ? text.split('\n').map((l) => '> $l').join('\n')
              : text);
        }
        break;
      case 'ul':
      case 'ol':
        flushInline();
        final listText = _renderList(child, images, 0);
        if (listText.trim().isNotEmpty) blocks.add(listText);
        break;
      case 'pre':
        flushInline();
        final raw = child.text.trimRight();
        if (raw.trim().isNotEmpty) blocks.add('```\n$raw\n```');
        break;
      case 'li':
        // A loose <li> outside any ul/ol (malformed source markup) — keep
        // it as a one-item block rather than dropping it.
        flushInline();
        final text = _flattenInlineOnly(child, images).trim();
        if (text.isNotEmpty) blocks.add('- $text');
        break;
      case 'br':
        inlineBuf.write('\n');
        break;
      case 'img':
        final src = child.attributes['src'];
        if (src != null && src.isNotEmpty) {
          images.add(src);
          inlineBuf.write(imgPlaceholder(images.length - 1));
        }
        break;
      case 'div':
      case 'section':
      case 'article':
      case 'body':
      case 'html':
        flushInline();
        blocks.addAll(_blockify(child, images));
        break;
      case 'b':
      case 'strong':
        inlineBuf.write(_wrapEmphasis(_flattenInlineOnly(child, images), '**'));
        break;
      case 'i':
      case 'em':
        inlineBuf.write(_wrapEmphasis(_flattenInlineOnly(child, images), '*'));
        break;
      case 'a':
        final href = child.attributes['href'];
        final text = _flattenInlineOnly(child, images).trim();
        if (text.isNotEmpty) {
          inlineBuf.write(href != null && href.isNotEmpty ? '[$text]($href)' : text);
        }
        break;
      default:
        inlineBuf.write(_flattenInlineOnly(child, images));
    }
  }
  flushInline();
  return blocks;
}
