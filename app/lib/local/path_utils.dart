String pathBaseName(String path) {
  final trimmed = _trimTrailingSeparators(path);
  final slash = trimmed.lastIndexOf('/');
  final backslash = trimmed.lastIndexOf(r'\');
  final i = slash > backslash ? slash : backslash;
  return i < 0 ? trimmed : trimmed.substring(i + 1);
}

String pathDirName(String path) {
  final trimmed = _trimTrailingSeparators(path);
  final slash = trimmed.lastIndexOf('/');
  final backslash = trimmed.lastIndexOf(r'\');
  final i = slash > backslash ? slash : backslash;
  return i < 0 ? '' : trimmed.substring(0, i);
}

(String, String) splitPathNameDir(String path) {
  final trimmed = _trimTrailingSeparators(path);
  final slash = trimmed.lastIndexOf('/');
  final backslash = trimmed.lastIndexOf(r'\');
  final i = slash > backslash ? slash : backslash;
  return (
    i < 0 ? trimmed : trimmed.substring(i + 1),
    i < 0 ? '' : trimmed.substring(0, i),
  );
}

String pathJoin(String dir, String name) {
  if (dir.isEmpty) return name;
  if (dir.endsWith('/') || dir.endsWith(r'\')) return '$dir$name';
  return '$dir${_preferredSeparator(dir)}$name';
}

bool pathEquals(String a, String b) => _normForCompare(a) == _normForCompare(b);

bool pathWithin(String path, String root) {
  final p = _normForCompare(path);
  final r = _normForCompare(root);
  if (r.isEmpty) return p.isEmpty;
  if (r == '/') return p == '/' || p.startsWith('/');
  return p == r || p.startsWith('$r/');
}

String pathRelativeTo(String root, String path) {
  if (!pathWithin(path, root)) return path;
  final r = _normPreserveCase(root);
  final p = _normPreserveCase(path);
  if (p == r) return '';
  if (r == '/') return p.substring(1);
  return p.substring(r.length + 1);
}

String normalizePathSeparators(String path) => path.replaceAll('\\', '/');

String _preferredSeparator(String path) =>
    path.contains('\\') && !path.contains('/') ? '\\' : '/';

String _trimTrailingSeparators(String path) {
  var end = path.length;
  while (end > 1 &&
      (path.codeUnitAt(end - 1) == 47 || path.codeUnitAt(end - 1) == 92)) {
    if (end == 3 && path.codeUnitAt(1) == 58) break; // C:\ or C:/
    end--;
  }
  return end == path.length ? path : path.substring(0, end);
}

String _normForCompare(String path) {
  final out = _normPreserveCase(path);
  return _looksWindowsPath(path) ? out.toLowerCase() : out;
}

String _normPreserveCase(String path) {
  final normalized = normalizePathSeparators(path);
  var prefix = '';
  var rest = normalized;
  if (_hasWindowsDrive(normalized)) {
    prefix = normalized.substring(0, 2);
    rest = normalized.substring(2);
    if (rest.startsWith('/')) rest = rest.substring(1);
  } else if (normalized.startsWith('//')) {
    prefix = '//';
    rest = normalized.substring(2);
  } else if (normalized.startsWith('/')) {
    prefix = '/';
    rest = normalized.substring(1);
  }

  final parts = <String>[];
  for (final seg in rest.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(seg);
  }
  final body = parts.join('/');
  if (prefix == '/') return body.isEmpty ? '/' : '/$body';
  if (prefix == '//') return body.isEmpty ? '//' : '//$body';
  if (prefix.isNotEmpty) return body.isEmpty ? prefix : '$prefix/$body';
  return body;
}

bool _hasWindowsDrive(String path) =>
    path.length >= 2 && path.codeUnitAt(1) == 58;

bool _looksWindowsPath(String path) =>
    path.contains('\\') || _hasWindowsDrive(path);
