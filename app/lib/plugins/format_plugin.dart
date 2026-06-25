// FormatPlugin describes one "format plugin": either a built-in renderer
// (Markdown preview) or a code formatter that shells out to a host CLI tool
// (gofmt / prettier / …). The catalog `kFormatPlugins` is the source of truth;
// PluginManager handles detection, enable state and running the tool.

enum PluginKind { renderer, formatter }

class FormatPlugin {
  final String id; // stable key, also the Prefs key: plugin.<id>.enabled
  final String name; // display name
  final PluginKind kind;
  final Set<String> exts; // lowercased extensions this plugin handles
  final String? tool; // executable to detect/run; null = built-in renderer
  final List<String> Function(String file)? args; // argv after [tool]
  final String? installHint; // human description of how to get the tool
  final String? installCmd; // copyable shell command, when one exists

  const FormatPlugin({
    required this.id,
    required this.name,
    required this.kind,
    required this.exts,
    this.tool,
    this.args,
    this.installHint,
    this.installCmd,
  });

  // Built-in plugins (renderers) need no host tool and are always "available".
  bool get builtIn => tool == null;
}

// argv builders (top-level so they can sit in the const catalog).
List<String> _wArg(String f) => ['-w', f]; // gofmt, shfmt
List<String> _iArg(String f) => ['-i', f]; // clang-format
List<String> _writeArg(String f) => ['--write', f]; // prettier
List<String> _dartArgs(String f) => ['format', f]; // dart format
List<String> _blackArgs(String f) => ['-q', f]; // black
List<String> _fileArg(String f) => [f]; // rustfmt

// The built-in catalog. Order matters: formatterFor returns the first match,
// so list more specific tools before generalists (prettier).
const List<FormatPlugin> kFormatPlugins = [
  FormatPlugin(
    id: 'markdown',
    name: 'Markdown 预览',
    kind: PluginKind.renderer,
    exts: {'md', 'markdown'},
  ),
  FormatPlugin(
    id: 'gofmt',
    name: 'Go (gofmt)',
    kind: PluginKind.formatter,
    exts: {'go'},
    tool: 'gofmt',
    args: _wArg,
    installHint: '随 Go SDK 提供(装好 Go 即可)',
  ),
  FormatPlugin(
    id: 'dartfmt',
    name: 'Dart (dart format)',
    kind: PluginKind.formatter,
    exts: {'dart'},
    tool: 'dart',
    args: _dartArgs,
    installHint: '随 Dart / Flutter SDK 提供',
  ),
  FormatPlugin(
    id: 'rustfmt',
    name: 'Rust (rustfmt)',
    kind: PluginKind.formatter,
    exts: {'rs'},
    tool: 'rustfmt',
    args: _fileArg,
    installHint: 'rustup component add rustfmt',
    installCmd: 'rustup component add rustfmt',
  ),
  FormatPlugin(
    id: 'black',
    name: 'Python (black)',
    kind: PluginKind.formatter,
    exts: {'py'},
    tool: 'black',
    args: _blackArgs,
    installHint: 'pip install black',
    installCmd: 'pip install black',
  ),
  FormatPlugin(
    id: 'clangfmt',
    name: 'C / C++ (clang-format)',
    kind: PluginKind.formatter,
    exts: {'c', 'cc', 'cpp', 'cxx', 'h', 'hpp'},
    tool: 'clang-format',
    args: _iArg,
    installHint: 'brew install clang-format / LLVM',
    installCmd: 'brew install clang-format',
  ),
  FormatPlugin(
    id: 'shfmt',
    name: 'Shell (shfmt)',
    kind: PluginKind.formatter,
    exts: {'sh', 'bash', 'zsh'},
    tool: 'shfmt',
    args: _wArg,
    installHint: 'brew install shfmt',
    installCmd: 'brew install shfmt',
  ),
  FormatPlugin(
    id: 'prettier',
    name: 'Prettier (JS/TS/JSON/CSS/HTML/YAML)',
    kind: PluginKind.formatter,
    exts: {
      'js',
      'jsx',
      'mjs',
      'cjs',
      'ts',
      'tsx',
      'json',
      'css',
      'scss',
      'less',
      'html',
      'htm',
      'yaml',
      'yml',
    },
    tool: 'prettier',
    args: _writeArg,
    installHint: 'npm i -g prettier',
    installCmd: 'npm i -g prettier',
  ),
];
