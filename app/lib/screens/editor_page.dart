import 'dart:io';

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';

import '../theme.dart';
import '../widgets.dart';

class CodeEditorPane extends StatefulWidget {
  final String path;
  final int? initialLine;
  final ValueChanged<bool>? onDirtyChanged;
  final VoidCallback? onLoaded;
  const CodeEditorPane({
    super.key,
    required this.path,
    this.initialLine,
    this.onDirtyChanged,
    this.onLoaded,
  });

  @override
  State<CodeEditorPane> createState() => CodeEditorPaneState();
}

class CodeEditorPaneState extends State<CodeEditorPane> {
  CodeLineEditingController? _ctl;
  final _scrollCtl = CodeScrollController();
  String _original = '';
  bool _crlf = false; // file used CRLF endings — re-apply them on save
  bool _dirty = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  bool get dirty => _dirty;
  bool get saving => _saving;
  String get text => _ctl?.text ?? '';
  int get lineCount => text.isEmpty ? 0 : text.split('\n').length;
  String get eol => _crlf ? 'CRLF' : 'LF';
  String get languageLabel {
    final ext = widget.path.split('.').last.toLowerCase();
    return _languageLabelForExt(ext);
  }

  int? get fileBytes {
    try {
      return File(widget.path).lengthSync();
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CodeEditorPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _ctl?.dispose();
      _ctl = null;
      _original = '';
      _dirty = false;
      _loading = true;
      _saving = false;
      _error = null;
      _load();
    } else if (oldWidget.initialLine != widget.initialLine) {
      _jumpToInitialLine();
    }
  }

  Future<void> _load() async {
    try {
      final content = await File(widget.path).readAsString();
      _crlf = content.contains('\r\n');
      _ctl = CodeLineEditingController.fromText(content)
        ..addListener(_onChange);
      // re_editor normalises EOLs to LF internally; baseline against that so a
      // CRLF file doesn't open already-dirty.
      _original = _ctl!.text;
      if (mounted) {
        setState(() => _loading = false);
        _jumpToInitialLine();
        widget.onLoaded?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorText(e);
          _loading = false;
        });
      }
    }
  }

  void _jumpToInitialLine() {
    final ctl = _ctl;
    final line = widget.initialLine;
    if (ctl == null || line == null || line <= 0) return;
    final index = (line - 1).clamp(0, lineCount == 0 ? 0 : lineCount - 1);
    ctl.selection = CodeLineSelection.collapsed(index: index, offset: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollCtl.makeCenterIfInvisible(
        CodeLinePosition(index: index, offset: 0),
      );
    });
  }

  void _onChange() {
    final d = _ctl!.text != _original;
    if (d != _dirty && mounted) {
      setState(() => _dirty = d);
      widget.onDirtyChanged?.call(d);
    }
  }

  Future<void> save() async {
    final ctl = _ctl;
    if (ctl == null) return;
    setState(() => _saving = true);
    try {
      final out = _crlf ? ctl.text.replaceAll('\n', '\r\n') : ctl.text;
      await File(widget.path).writeAsString(out);
      _original = ctl.text;
      if (mounted) {
        setState(() {
          _dirty = false;
          _saving = false;
        });
        widget.onDirtyChanged?.call(false);
        snack(context, '已保存');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        snack(context, errorText(e));
      }
    }
  }

  @override
  void dispose() {
    _ctl?.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return centerMsg(_error!);
    return CodeEditor(
      controller: _ctl!,
      scrollController: _scrollCtl,
      wordWrap: false,
      style: CodeEditorStyle(
        fontSize: 13,
        fontFamily: CcType.mono,
        backgroundColor: CcColors.bg,
        codeTheme: _themeFor(widget.path),
      ),
      indicatorBuilder:
          (context, editingController, chunkController, notifier) =>
              DefaultCodeLineNumber(
                controller: editingController,
                notifier: notifier,
              ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    );
  }
}

// EditorPage edits a local file with syntax highlighting (re_editor) and saves
// back to disk. Used from the diff view's "编辑" and the project file browser.
class EditorPage extends StatefulWidget {
  final String path;
  const EditorPage({super.key, required this.path});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final _editorKey = GlobalKey<CodeEditorPaneState>();
  bool _dirty = false;

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未保存的修改'),
        content: const Text('放弃修改并离开?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.path.split('/').last;
    final saving = _editorKey.currentState?.saving ?? false;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _confirmDiscard() && mounted) nav.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            '${_dirty ? '● ' : ''}$name',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: (_dirty && !saving)
                    ? _editorKey.currentState?.save
                    : null,
                icon: saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_rounded, size: 18),
                label: const Text('保存'),
              ),
            ),
          ],
        ),
        body: CodeEditorPane(
          key: _editorKey,
          path: widget.path,
          onDirtyChanged: (v) => setState(() => _dirty = v),
        ),
      ),
    );
  }
}

CodeHighlightTheme? _themeFor(String path) {
  final mode = _modeForExt(path.split('.').last.toLowerCase());
  if (mode == null) return null;
  return CodeHighlightTheme(
    languages: {'code': CodeHighlightThemeMode(mode: mode)},
    theme: atomOneDarkTheme,
  );
}

Mode? _modeForExt(String ext) => switch (ext) {
  'dart' => langDart,
  'go' => langGo,
  'ts' || 'tsx' => langTypescript,
  'js' || 'jsx' || 'mjs' => langJavascript,
  'py' => langPython,
  'json' => langJson,
  'yaml' || 'yml' => langYaml,
  'md' || 'markdown' => langMarkdown,
  'sh' || 'bash' || 'zsh' => langBash,
  'xml' || 'html' || 'htm' => langXml,
  'css' => langCss,
  'java' => langJava,
  'kt' || 'kts' => langKotlin,
  'rs' => langRust,
  'c' || 'cc' || 'cpp' || 'cxx' || 'h' || 'hpp' => langCpp,
  'sql' => langSql,
  'rb' => langRuby,
  'php' => langPhp,
  'toml' || 'ini' || 'cfg' || 'conf' || 'properties' => langIni,
  _ => null,
};

String _languageLabelForExt(String ext) => switch (ext) {
  'dart' => 'Dart',
  'go' => 'Go',
  'ts' || 'tsx' => 'TypeScript',
  'js' || 'jsx' || 'mjs' => 'JavaScript',
  'py' => 'Python',
  'json' => 'JSON',
  'yaml' || 'yml' => 'YAML',
  'md' || 'markdown' => 'Markdown',
  'sh' || 'bash' || 'zsh' => 'Shell',
  'xml' || 'html' || 'htm' => 'XML/HTML',
  'css' => 'CSS',
  'java' => 'Java',
  'kt' || 'kts' => 'Kotlin',
  'rs' => 'Rust',
  'c' || 'cc' || 'cpp' || 'cxx' || 'h' || 'hpp' => 'C/C++',
  'sql' => 'SQL',
  'rb' => 'Ruby',
  'php' => 'PHP',
  'toml' => 'TOML',
  'ini' || 'cfg' || 'conf' || 'properties' => 'Config',
  _ => ext.isEmpty ? 'Plain Text' : ext.toUpperCase(),
};
