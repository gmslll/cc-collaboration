import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../local/lsp/lsp_client.dart';
import '../local/lsp/lsp_plugin.dart';
import '../plugins/format_plugin.dart';
import '../plugins/plugin_manager.dart';
import '../theme.dart';
import '../widgets.dart';

// Plugins management dialog: list the format plugins, show whether each tool is
// installed on the host, let the user enable/disable them, and surface the
// install command for missing tools.
Future<void> showPluginsDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: CcColors.panel,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 580, maxHeight: 620),
      child: const _PluginsPane(),
    ),
  ),
);

class _PluginsPane extends StatefulWidget {
  const _PluginsPane();

  @override
  State<_PluginsPane> createState() => _PluginsPaneState();
}

class _PluginsPaneState extends State<_PluginsPane> {
  final _mgr = PluginManager.instance;
  final _lsp = LspManager.instance;

  @override
  void initState() {
    super.initState();
    _mgr.detectAll(); // refresh availability when the page opens
    _lsp.detectAll();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
          child: Row(
            children: [
              const Icon(
                Icons.extension_rounded,
                size: 20,
                color: CcColors.accentBright,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '编辑器插件',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: '重新检测',
                icon: const Icon(Icons.refresh_rounded, size: 18),
                onPressed: () {
                  _mgr.detectAll(force: true);
                  _lsp.detectAll(force: true);
                },
              ),
              IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            '格式化按类型渲染 / 格式化;代码跳转用语言服务器 (LSP) 精确跳到定义,未装则回退符号索引。都需宿主机装好对应命令(仅桌面本地生效),没检测到可手动指定路径。',
            style: TextStyle(color: CcColors.muted, fontSize: 12.5, height: 1.4),
          ),
        ),
        const Divider(height: 1),
        Flexible(
          child: ListenableBuilder(
            listenable: Listenable.merge([_mgr, _lsp]),
            builder: (context, _) => ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _sectionHeader('格式化 / 渲染'),
                for (final p in kFormatPlugins) _row(p),
                const SizedBox(height: 6),
                const Divider(height: 1),
                const SizedBox(height: 6),
                _sectionHeader('代码跳转 (LSP)'),
                for (final p in kLspServers) _lspRow(p),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: CcColors.subtle,
        letterSpacing: 0.4,
      ),
    ),
  );

  Widget _row(FormatPlugin p) {
    final on = _mgr.enabled(p.id);
    final avail = _mgr.available(p);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              p.kind == PluginKind.renderer
                  ? Icons.visibility_rounded
                  : Icons.auto_fix_high_rounded,
              size: 18,
              color: on ? CcColors.accentBright : CcColors.subtle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        p.name,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _extChips(p.exts),
                  ],
                ),
                const SizedBox(height: 4),
                _status(p, avail),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: on,
            onChanged: (v) => _mgr.setEnabled(p.id, v),
          ),
        ],
      ),
    );
  }

  Widget _extChips(Set<String> exts) {
    final shown = exts.take(4).map((e) => '.$e').toList();
    final extra = exts.length - shown.length;
    return Wrap(
      spacing: 4,
      children: [
        for (final e in shown) chip(e),
        if (extra > 0) chip('+$extra'),
      ],
    );
  }

  Widget _status(FormatPlugin p, bool avail) {
    if (p.builtIn) {
      return Row(
        children: [
          statusDot(CcColors.ok, size: 7),
          const SizedBox(width: 6),
          const Text(
            '内置 · 渲染预览',
            style: TextStyle(color: CcColors.muted, fontSize: 12),
          ),
        ],
      );
    }
    if (avail) {
      return Row(
        children: [
          statusDot(CcColors.ok, size: 7),
          const SizedBox(width: 6),
          Text(
            '已检测到 ${p.tool}',
            style: const TextStyle(color: CcColors.muted, fontSize: 12),
          ),
        ],
      );
    }
    final hint = p.installHint ?? '未安装';
    return Row(
      children: [
        statusDot(CcColors.warning, size: 7),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            '未检测到 ${p.tool} · $hint',
            style: const TextStyle(color: CcColors.warning, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (p.installCmd != null)
          IconButton(
            tooltip: '复制安装命令',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            icon: const Icon(Icons.copy_rounded, size: 14),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: p.installCmd!));
              if (!mounted) return;
              snack(context, '已复制安装命令');
            },
          ),
      ],
    );
  }

  // ---- LSP 语言服务器行:检测状态 + 开关 + 手动配置命令/路径 ----

  Widget _lspRow(LspServerPlugin p) {
    final on = _lsp.enabled(p.id);
    final cmd = _lsp.commandFor(p);
    final ok = _lsp.detected(p.id);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.my_location_rounded,
              size: 18,
              color: on ? CcColors.accentBright : CcColors.subtle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        p.name,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _extChips(p.exts),
                  ],
                ),
                const SizedBox(height: 4),
                _lspStatus(p, cmd, ok),
              ],
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '配置命令 / 路径',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            icon: const Icon(Icons.tune_rounded, size: 15),
            onPressed: () => _editLspCommand(p),
          ),
          const SizedBox(width: 4),
          Switch(value: on, onChanged: (v) => _lsp.setEnabled(p.id, v)),
        ],
      ),
    );
  }

  Widget _lspStatus(LspServerPlugin p, String cmd, bool ok) {
    if (ok) {
      return Row(
        children: [
          statusDot(CcColors.ok, size: 7),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '已检测到 $cmd',
              style: const TextStyle(color: CcColors.muted, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }
    final hint = p.installHint ?? '未安装';
    return Row(
      children: [
        statusDot(CcColors.warning, size: 7),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            '未检测到 $cmd · $hint',
            style: const TextStyle(color: CcColors.warning, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (p.installCmd != null)
          IconButton(
            tooltip: '复制安装命令',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            icon: const Icon(Icons.copy_rounded, size: 14),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: p.installCmd!));
              if (!mounted) return;
              snack(context, '已复制安装命令');
            },
          ),
      ],
    );
  }

  Future<void> _editLspCommand(LspServerPlugin p) async {
    final ctl = TextEditingController(text: _lsp.commandFor(p));
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: CcColors.panel,
        title: Text(
          '${p.name} · 服务器命令',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '填可执行文件名或绝对路径(启动参数用内置默认)。留空恢复默认命令。',
              style: TextStyle(color: CcColors.muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctl,
              autofocus: true,
              style: CcType.code(size: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: p.command,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('恢复默认'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (result == null) return; // 取消
    _lsp.setCommand(p.id, result.trim());
    _lsp.detectAll(force: true); // 立刻按新命令重新检测
  }
}
