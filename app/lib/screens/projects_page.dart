import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/relay_client.dart';
import '../theme.dart';
import '../widgets.dart';

class ProjectsPage extends StatefulWidget {
  final RelayClient client;
  const ProjectsPage({super.key, required this.client});

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  List<Project>? _projects;
  String? _error;
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final ps = await widget.client.projects();
      if (mounted) {
        setState(() {
          _projects = ps;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    try {
      await widget.client.createProject(name);
      _name.clear();
      await _load();
    } catch (e) {
      if (mounted) snack(context, '创建失败: ${errorText(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(
                  hintText: '新项目名称',
                  isDense: true,
                  prefixIcon: Icon(Icons.create_new_folder_outlined)),
              onSubmitted: (_) => _create(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新建项目')),
        ]),
        const SizedBox(height: 16),
        Expanded(child: _body()),
      ]),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
          child: Text(_error!, style: const TextStyle(color: CcColors.danger)));
    }
    if (_projects == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_projects!.isEmpty) {
      return const Center(
          child: Text('还没有项目', style: TextStyle(color: CcColors.muted)));
    }
    return ListView(
      children: _projects!
            .map((p) => Card(
                child: ListTile(
                  leading:
                      const Icon(Icons.folder_outlined, color: CcColors.accent),
                  title: Text(p.name,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('owner: ${p.ownerIdentity}',
                      style: const TextStyle(color: CcColors.muted)),
                  trailing: const Icon(Icons.chevron_right, color: CcColors.muted),
                  onTap: () => showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _ProjectSheet(
                        client: widget.client, id: p.id, onChanged: _load),
                  ),
                ),
              ))
          .toList(),
    );
  }
}

class _ProjectSheet extends StatefulWidget {
  final RelayClient client;
  final String id;
  final VoidCallback onChanged;
  const _ProjectSheet(
      {required this.client, required this.id, required this.onChanged});

  @override
  State<_ProjectSheet> createState() => _ProjectSheetState();
}

class _ProjectSheetState extends State<_ProjectSheet> {
  ProjectDetail? _d;
  final _repo = TextEditingController();
  final _member = TextEditingController();
  String _role = 'member';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _repo.dispose();
    _member.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.client.project(widget.id);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<void> _do(Future<void> Function() action) async {
    try {
      await action();
      await _load();
      widget.onChanged();
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  Future<void> _rename(String current) async {
    final ctl = TextEditingController(text: current);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名项目'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || ctl.text.trim().isEmpty) return;
    await _do(() => widget.client.renameProject(widget.id, ctl.text.trim()));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除项目?'),
        content: const Text('删除后不可恢复(repo / 成员映射一并删除)。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: CcColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.client.deleteProject(widget.id);
      widget.onChanged();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) snack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Padding(
      padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: d == null
          ? const SizedBox(
              height: 180, child: Center(child: CircularProgressIndicator()))
          : SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                  Row(children: [
                    Expanded(
                      child: Text(d.project.name,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: '重命名',
                        onPressed: () => _rename(d.project.name)),
                    IconButton(
                        icon: const Icon(Icons.delete_outline,
                            size: 18, color: CcColors.danger),
                        tooltip: '删除',
                        onPressed: _delete),
                  ]),
                  const SizedBox(height: 8),
                  const Text('Repos', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: d.repos.isEmpty
                        ? [const Text('无', style: TextStyle(color: CcColors.muted))]
                        : d.repos
                            .map((r) => Chip(
                                label: Text(r),
                                onDeleted: () =>
                                    _do(() => widget.client.unmapRepo(widget.id, r))))
                            .toList(),
                  ),
                  Row(children: [
                    Expanded(
                        child: TextField(
                            controller: _repo,
                            decoration: const InputDecoration(
                                hintText: 'repo 名(如 kunlun-backend)',
                                isDense: true))),
                    TextButton(
                        onPressed: () {
                          final r = _repo.text.trim();
                          if (r.isNotEmpty) {
                            _repo.clear();
                            _do(() => widget.client.mapRepo(widget.id, r));
                          }
                        },
                        child: const Text('绑定')),
                  ]),
                  const SizedBox(height: 16),
                  const Text('成员', style: TextStyle(fontWeight: FontWeight.bold)),
                  ...d.members.map((m) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(m.identity),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(m.role,
                              style: const TextStyle(color: CcColors.muted)),
                          IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => _do(() =>
                                  widget.client.removeMember(widget.id, m.identity))),
                        ]),
                      )),
                  Row(children: [
                    Expanded(
                        child: TextField(
                            controller: _member,
                            decoration: const InputDecoration(
                                hintText: 'identity', isDense: true))),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: _role,
                      items: const [
                        DropdownMenuItem(value: 'member', child: Text('member')),
                        DropdownMenuItem(value: 'viewer', child: Text('viewer')),
                        DropdownMenuItem(value: 'owner', child: Text('owner')),
                      ],
                      onChanged: (v) => setState(() => _role = v ?? 'member'),
                    ),
                    TextButton(
                        onPressed: () {
                          final m = _member.text.trim();
                          if (m.isNotEmpty) {
                            _member.clear();
                            _do(() =>
                                widget.client.addMember(widget.id, m, _role));
                          }
                        },
                        child: const Text('加成员')),
                  ]),
                ]),
            ),
    );
  }
}
