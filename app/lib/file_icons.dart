import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

// GoLand-style file-type icons. Maps a filename to a bundled SVG asset
// (see assets/file_icons/, sourced from Material Icon Theme — MIT). The file
// tree (file_browser_page.dart) renders these instead of generic Material
// glyphs so each type reads at a glance, like the IDE Project panel.

const _base = 'assets/file_icons';

const _folder = '$_base/folder.svg';
const _file = '$_base/file.svg'; // fallback

// Whole-name matches (lowercased) — checked before extension. These files
// either have no extension (Makefile) or a name that's more telling than it.
const Map<String, String> _byName = {
  'go.mod': '$_base/go.svg',
  'go.sum': '$_base/go.svg',
  'dockerfile': '$_base/docker.svg',
  'containerfile': '$_base/docker.svg',
  'makefile': '$_base/makefile.svg',
  'gnumakefile': '$_base/makefile.svg',
  'license': '$_base/certificate.svg',
  'license.md': '$_base/certificate.svg',
  'license.txt': '$_base/certificate.svg',
  'copying': '$_base/certificate.svg',
  'ofl.txt': '$_base/certificate.svg',
  '.gitignore': '$_base/git.svg',
  '.gitattributes': '$_base/git.svg',
  '.gitmodules': '$_base/git.svg',
};

// Extension matches (lowercased, without the dot).
const Map<String, String> _byExt = {
  'go': '$_base/go.svg',
  'dart': '$_base/dart.svg',
  'md': '$_base/markdown.svg',
  'markdown': '$_base/markdown.svg',
  'sh': '$_base/console.svg',
  'bash': '$_base/console.svg',
  'zsh': '$_base/console.svg',
  'fish': '$_base/console.svg',
  'command': '$_base/console.svg',
  'ps1': '$_base/powershell.svg',
  'psm1': '$_base/powershell.svg',
  'json': '$_base/json.svg',
  'jsonc': '$_base/json.svg',
  'yaml': '$_base/yaml.svg',
  'yml': '$_base/yaml.svg',
  'toml': '$_base/toml.svg',
  'ini': '$_base/settings.svg',
  'cfg': '$_base/settings.svg',
  'conf': '$_base/settings.svg',
  'config': '$_base/settings.svg',
  'properties': '$_base/settings.svg',
  'env': '$_base/tune.svg',
  'xml': '$_base/xml.svg',
  'plist': '$_base/xml.svg',
  'html': '$_base/html.svg',
  'htm': '$_base/html.svg',
  'css': '$_base/css.svg',
  'scss': '$_base/css.svg',
  'sass': '$_base/css.svg',
  'less': '$_base/css.svg',
  'js': '$_base/javascript.svg',
  'mjs': '$_base/javascript.svg',
  'cjs': '$_base/javascript.svg',
  'jsx': '$_base/javascript.svg',
  'ts': '$_base/typescript.svg',
  'tsx': '$_base/typescript.svg',
  'mts': '$_base/typescript.svg',
  'cts': '$_base/typescript.svg',
  'py': '$_base/python.svg',
  'pyi': '$_base/python.svg',
  'rs': '$_base/rust.svg',
  'java': '$_base/java.svg',
  'kt': '$_base/kotlin.svg',
  'kts': '$_base/kotlin.svg',
  'c': '$_base/c.svg',
  'h': '$_base/c.svg',
  'cpp': '$_base/cpp.svg',
  'cc': '$_base/cpp.svg',
  'cxx': '$_base/cpp.svg',
  'hpp': '$_base/cpp.svg',
  'hxx': '$_base/cpp.svg',
  'png': '$_base/image.svg',
  'jpg': '$_base/image.svg',
  'jpeg': '$_base/image.svg',
  'gif': '$_base/image.svg',
  'webp': '$_base/image.svg',
  'bmp': '$_base/image.svg',
  'ico': '$_base/image.svg',
  'svg': '$_base/image.svg',
  'avif': '$_base/image.svg',
  'lock': '$_base/lock.svg',
  'txt': '$_base/document.svg',
  'text': '$_base/document.svg',
  'log': '$_base/document.svg',
  'sql': '$_base/database.svg',
};

/// Asset path of the type icon for a file named [name] (the last path segment).
String fileIconAsset(String name) {
  final lower = name.toLowerCase();
  final exact = _byName[lower];
  if (exact != null) return exact;
  // Special-case Dockerfile.<tag> / .env.<env> style suffixed names.
  if (lower.startsWith('dockerfile')) return '$_base/docker.svg';
  if (lower.startsWith('.env')) return '$_base/tune.svg';
  final dot = lower.lastIndexOf('.');
  if (dot > 0 && dot < lower.length - 1) {
    final ext = lower.substring(dot + 1);
    final byExt = _byExt[ext];
    if (byExt != null) return byExt;
  }
  return _file;
}

/// Folder icon — GoLand New UI keeps one glyph regardless of open/closed
/// state; the disclosure chevron conveys expansion.
String get folderIconAsset => _folder;

/// Terse SVG icon widget for tree rows.
Widget fileSvg(String asset, {double size = 16}) =>
    SvgPicture.asset(asset, width: size, height: size);
