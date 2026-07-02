import 'dart:io';

// LspServerPlugin describes one language's LSP server for go-to-definition:
// which file extensions it handles, the LSP languageId to tag documents with,
// the default command to run (probed on the login PATH, user-overridable), the
// args that command takes, and how to install it. The catalog [kLspServers] is
// the source of truth; LspManager (lsp_client.dart) handles detection, the
// enable/command config (Prefs) and the runtime. This mirrors FormatPlugin /
// kFormatPlugins so the settings panel can render both the same way.

class LspServerPlugin {
  final String id; // stable key + Prefs keys: lsp.<id>.enabled / lsp.<id>.cmd
  final String name; // display name, e.g. "Go (gopls)"
  final Set<String> exts; // lowercased extensions this server handles
  final String languageId; // LSP languageId for didOpen
  final String command; // default executable (user can override in the panel)
  final List<String> Function(String root) argsFor; // argv after the command
  final String? installHint; // human description of how to get it
  final String? installCmd; // copyable shell command, when one exists

  const LspServerPlugin({
    required this.id,
    required this.name,
    required this.exts,
    required this.languageId,
    required this.command,
    required this.argsFor,
    this.installHint,
    this.installCmd,
  });
}

// argv builders (top-level so they can sit in the const catalog).
List<String> _noArgs(String _) => const [];
List<String> _dartArgs(String _) => const ['language-server', '--protocol=lsp'];
List<String> _stdioArgs(String _) => const ['--stdio']; // pyright / tsserver
// jdtls needs a writable per-project data dir for its index. Derive a stable one
// under the system temp dir keyed by the root path so each project gets its own.
List<String> _jdtlsArgs(String root) => [
  '-data',
  '${Directory.systemTemp.path}/cc-lsp-jdtls/${root.hashCode & 0x7fffffff}',
];

// The built-in catalog. Extensions must not overlap across entries (the router
// picks by ext). Commands are defaults — the user can point any row at their own
// install from the panel when auto-detection fails.
const List<LspServerPlugin> kLspServers = [
  LspServerPlugin(
    id: 'gopls',
    name: 'Go (gopls)',
    exts: {'go'},
    languageId: 'go',
    command: 'gopls',
    argsFor: _noArgs,
    installHint: 'go install golang.org/x/tools/gopls@latest',
    installCmd: 'go install golang.org/x/tools/gopls@latest',
  ),
  LspServerPlugin(
    id: 'dart',
    name: 'Dart (analysis server)',
    exts: {'dart'},
    languageId: 'dart',
    command: 'dart',
    argsFor: _dartArgs,
    installHint: '随 Dart / Flutter SDK 提供',
  ),
  LspServerPlugin(
    id: 'jdtls',
    name: 'Java (jdtls)',
    exts: {'java'},
    languageId: 'java',
    command: 'jdtls',
    argsFor: _jdtlsArgs,
    installHint: 'brew install jdtls (Eclipse JDT LS)',
    installCmd: 'brew install jdtls',
  ),
  LspServerPlugin(
    id: 'pyright',
    name: 'Python (pyright)',
    exts: {'py', 'pyi'},
    languageId: 'python',
    command: 'pyright-langserver',
    argsFor: _stdioArgs,
    installHint: 'npm i -g pyright',
    installCmd: 'npm i -g pyright',
  ),
  LspServerPlugin(
    id: 'tsserver',
    name: 'TS / JS (typescript-language-server)',
    exts: {'ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs'},
    languageId: 'typescript',
    command: 'typescript-language-server',
    argsFor: _stdioArgs,
    installHint: 'npm i -g typescript-language-server typescript',
    installCmd: 'npm i -g typescript-language-server typescript',
  ),
  LspServerPlugin(
    id: 'rust',
    name: 'Rust (rust-analyzer)',
    exts: {'rs'},
    languageId: 'rust',
    command: 'rust-analyzer',
    argsFor: _noArgs,
    installHint: 'rustup component add rust-analyzer',
    installCmd: 'rustup component add rust-analyzer',
  ),
  LspServerPlugin(
    id: 'clangd',
    name: 'C / C++ (clangd)',
    exts: {'c', 'cc', 'cpp', 'cxx', 'h', 'hpp'},
    languageId: 'cpp',
    command: 'clangd',
    argsFor: _noArgs,
    installHint: 'brew install llvm',
    installCmd: 'brew install llvm',
  ),
];
