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

// EditorPage edits a local file with syntax highlighting (re_editor) and saves
// back to disk. Used from the diff view's "编辑" and the project file browser.
class EditorPage extends StatefulWidget {
  final String path;
  const EditorPage({super.key, required this.path});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  CodeLineEditingController? _ctl;
  String _original = '';
  bool _dirty = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final content = await File(widget.path).readAsString();
      _original = content;
      _ctl = CodeLineEditingController.fromText(content)..addListener(_onChange);
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorText(e);
          _loading = false;
        });
      }
    }
  }

  void _onChange() {
    final d = _ctl!.text != _original;
    if (d != _dirty && mounted) setState(() => _dirty = d);
  }

  Future<void> _save() async {
    final ctl = _ctl;
    if (ctl == null) return;
    setState(() => _saving = true);
    try {
      await File(widget.path).writeAsString(ctl.text);
      _original = ctl.text;
      if (mounted) {
        setState(() {
          _dirty = false;
          _saving = false;
        });
        snack(context, '已保存');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        snack(context, errorText(e));
      }
    }
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未保存的修改'),
        content: const Text('放弃修改并离开?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  void dispose() {
    _ctl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.path.split('/').last;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _confirmDiscard() && mounted) nav.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('${_dirty ? '● ' : ''}$name',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: (_dirty && !_saving) ? _save : null,
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_rounded, size: 18),
                label: const Text('保存'),
              ),
            ),
          ],
        ),
        body: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return centerMsg(_error!);
    return CodeEditor(
      controller: _ctl!,
      wordWrap: false,
      style: CodeEditorStyle(
        fontSize: 13,
        fontFamily: CcType.mono,
        backgroundColor: CcColors.bg,
        codeTheme: _themeFor(widget.path),
      ),
      indicatorBuilder: (context, editingController, chunkController, notifier) =>
          DefaultCodeLineNumber(
              controller: editingController, notifier: notifier),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
