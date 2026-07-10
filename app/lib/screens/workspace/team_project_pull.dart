part of '../workspace_page.dart';

typedef TeamRepoCloneAction =
    Future<Map<String, dynamic>> Function({
      required String workspaceName,
      required String workspacePath,
      required String repoName,
      required String cloneUrl,
      required String projectId,
    });

typedef TeamProjectLoader = Future<List<ProjectDetail>> Function();
typedef DirectoryPicker = Future<String?> Function();

bool teamProjectPullContextMatches({
  required Object expectedClient,
  required Object? currentClient,
  required String expectedRelay,
  required String currentRelay,
  required String expectedToken,
  required String currentToken,
  required String expectedIdentity,
  required String currentIdentity,
}) =>
    identical(expectedClient, currentClient) &&
    expectedRelay == currentRelay &&
    expectedToken == currentToken &&
    expectedIdentity == currentIdentity;

class TeamProjectPullDraft {
  final ProjectDetail project;
  final String workspaceName, parentDirectory;
  final Set<String> repoNames;

  const TeamProjectPullDraft({
    required this.project,
    required this.workspaceName,
    required this.parentDirectory,
    required this.repoNames,
  });

  String get workspacePath =>
      joinTeamProjectPath(parentDirectory, workspaceName);
}

class TeamProjectPullResult {
  final ProjectRepo repo;
  final bool success;
  final String status, message;

  const TeamProjectPullResult({
    required this.repo,
    required this.success,
    required this.status,
    required this.message,
  });
}

String joinTeamProjectPath(String parent, String name) {
  final value = parent.trim();
  if (value.endsWith('/') || value.endsWith(r'\')) return '$value$name';
  return '$value${Platform.pathSeparator}$name';
}

String safeTeamWorkspaceName(String projectName) {
  var value = projectName.trim().replaceAll(
    RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]+'),
    '-',
  );
  value = value.replaceAll(RegExp(r'[- ]{2,}'), '-');
  value = value.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (value.runes.length > 80) {
    value = String.fromCharCodes(value.runes.take(80));
    value = value.replaceAll(RegExp(r'[. ]+$'), '');
  }
  if (_reservedTeamWorkspaceName(value)) value = 'team-$value';
  return value.isEmpty ? 'team-project' : value;
}

bool validTeamWorkspaceName(String value) {
  final trimmed = value.trim();
  return trimmed.isNotEmpty &&
      trimmed != '.' &&
      trimmed != '..' &&
      safeTeamWorkspaceName(trimmed) == trimmed;
}

bool _reservedTeamWorkspaceName(String value) {
  final device = value.split('.').first.toUpperCase();
  if (const {'CON', 'PRN', 'AUX', 'NUL'}.contains(device)) return true;
  return RegExp(r'^(COM|LPT)[1-9]$').hasMatch(device);
}

Size workspaceTeamProjectDialogSize(
  Size viewport, {
  double preferredWidth = 560,
  double preferredHeight = 620,
}) {
  final availableWidth = viewport.width - 32;
  // Reserve room for AlertDialog title/actions/padding as well as its content.
  final availableHeight = viewport.height - 220;
  final width = availableWidth.isFinite && availableWidth > 0
      ? availableWidth.clamp(288.0, preferredWidth)
      : preferredWidth;
  final height = availableHeight.isFinite && availableHeight > 0
      ? availableHeight.clamp(180.0, preferredHeight)
      : preferredHeight;
  return Size(width, height);
}

Future<List<TeamProjectPullResult>> orchestrateTeamProjectPull(
  TeamProjectPullDraft draft,
  TeamRepoCloneAction clone, {
  ValueChanged<TeamProjectPullResult>? onResult,
}) async {
  final results = <TeamProjectPullResult>[];
  for (final repo in draft.project.cloneableRepos) {
    if (!draft.repoNames.contains(repo.repoName)) continue;
    TeamProjectPullResult result;
    try {
      final output = await clone(
        workspaceName: draft.workspaceName,
        workspacePath: draft.workspacePath,
        repoName: repo.repoName,
        cloneUrl: repo.cloneUrl,
        projectId: draft.project.project.id,
      );
      final status = (output['status'] ?? 'cloned').toString();
      final message = switch (status) {
        'imported' => '已导入匹配 remote 的已有仓库',
        'already_registered' => '已存在，无需重复拉取',
        _ => '已克隆并注册',
      };
      result = TeamProjectPullResult(
        repo: repo,
        success: true,
        status: status,
        message: message,
      );
    } catch (e) {
      result = TeamProjectPullResult(
        repo: repo,
        success: false,
        status: 'failed',
        message: errorText(e),
      );
    }
    results.add(result);
    onResult?.call(result);
  }
  return results;
}

class TeamProjectPullDialog extends StatefulWidget {
  final TeamProjectLoader loadProjects;
  final DirectoryPicker pickDirectory;
  final String initialParentDirectory;

  const TeamProjectPullDialog({
    super.key,
    required this.loadProjects,
    required this.pickDirectory,
    required this.initialParentDirectory,
  });

  @override
  State<TeamProjectPullDialog> createState() => _TeamProjectPullDialogState();
}

class _TeamProjectPullDialogState extends State<TeamProjectPullDialog> {
  final _workspace = TextEditingController();
  final _parent = TextEditingController();
  List<ProjectDetail>? _projects;
  ProjectDetail? _selected;
  Set<String> _selectedRepos = const {};
  String? _error;
  bool _workspaceEdited = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _parent.text = widget.initialParentDirectory;
    _workspace.addListener(_changed);
    _parent.addListener(_changed);
    _load();
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _workspace.removeListener(_changed);
    _parent.removeListener(_changed);
    _workspace.dispose();
    _parent.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _projects = null;
      _selected = null;
      _error = null;
    });
    try {
      final projects = (await widget.loadProjects())
          .where((project) => project.cloneableRepos.isNotEmpty)
          .toList(growable: false);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _projects = projects;
        if (projects.isNotEmpty) _selectProject(projects.first);
      });
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _projects = const [];
          _error = errorText(e);
        });
      }
    }
  }

  void _selectProject(ProjectDetail project) {
    _selected = project;
    _selectedRepos = {for (final repo in project.cloneableRepos) repo.repoName};
    if (!_workspaceEdited) {
      _workspace.text = safeTeamWorkspaceName(project.project.name);
    }
  }

  Future<void> _pickParent() async {
    final value = await widget.pickDirectory();
    if (!mounted || value == null || value.trim().isEmpty) return;
    _parent.text = value.trim();
  }

  bool get _valid =>
      _selected != null &&
      _selectedRepos.isNotEmpty &&
      _parent.text.trim().isNotEmpty &&
      validTeamWorkspaceName(_workspace.text);

  void _submit() {
    if (!_valid) return;
    Navigator.pop(
      context,
      TeamProjectPullDraft(
        project: _selected!,
        workspaceName: _workspace.text.trim(),
        parentDirectory: _parent.text.trim(),
        repoNames: Set.unmodifiable(_selectedRepos),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = workspaceTeamProjectDialogSize(MediaQuery.sizeOf(context));
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Row(
        children: [
          Icon(Icons.cloud_download_outlined, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text('拉取团队项目', maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      content: SizedBox(
        width: size.width,
        height: size.height,
        child: _content(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _valid ? _submit : null,
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('开始拉取'),
        ),
      ],
    );
  }

  Widget _content() {
    if (_projects == null) {
      return const Center(
        key: ValueKey('team-project-pull-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_error != null) {
      return Center(
        key: const ValueKey('team-project-pull-error'),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                color: CcColors.danger,
                size: 30,
              ),
              const SizedBox(height: 10),
              Text(
                '无法读取团队项目\n$_error',
                textAlign: TextAlign.center,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_projects!.isEmpty) {
      return const Center(
        key: ValueKey('team-project-pull-empty'),
        child: Text(
          '没有可拉取的团队项目\n请先让项目管理员绑定 GitHub 仓库 URL',
          textAlign: TextAlign.center,
          style: TextStyle(color: CcColors.muted),
        ),
      );
    }
    final project = _selected!;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: const ValueKey('team-project-pull-project'),
            initialValue: project.project.id,
            isExpanded: true,
            menuMaxHeight: workspaceLogFilterMenuMaxHeight(
              MediaQuery.sizeOf(context),
            ),
            decoration: const InputDecoration(labelText: '团队项目'),
            items: [
              for (final item in _projects!)
                DropdownMenuItem(
                  value: item.project.id,
                  child: Text(
                    item.project.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (id) {
              if (id == null) return;
              setState(() {
                _selectProject(
                  _projects!.firstWhere((item) => item.project.id == id),
                );
              });
            },
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('team-project-pull-workspace'),
            controller: _workspace,
            decoration: InputDecoration(
              labelText: '本地 workspace 名称',
              errorText:
                  _workspace.text.trim().isNotEmpty &&
                      !validTeamWorkspaceName(_workspace.text)
                  ? '名称不能包含路径分隔符或系统保留字符'
                  : null,
            ),
            onChanged: (_) => _workspaceEdited = true,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('team-project-pull-parent'),
            controller: _parent,
            readOnly: true,
            decoration: InputDecoration(
              labelText: '目标父目录',
              suffixIcon: IconButton(
                tooltip: '选择目录',
                onPressed: _pickParent,
                icon: const Icon(Icons.folder_open_rounded),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('仓库', style: CcType.code(size: 12, color: CcColors.muted)),
          const SizedBox(height: 4),
          for (final repo in project.cloneableRepos)
            CheckboxListTile(
              key: ValueKey('team-project-pull-repo-${repo.repoName}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _selectedRepos.contains(repo.repoName),
              title: Text(
                repo.repoName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                repo.cloneUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.code(size: 10.5, color: CcColors.muted),
              ),
              onChanged: (checked) {
                setState(() {
                  _selectedRepos = {..._selectedRepos};
                  if (checked == true) {
                    _selectedRepos.add(repo.repoName);
                  } else {
                    _selectedRepos.remove(repo.repoName);
                  }
                });
              },
            ),
          const SizedBox(height: 8),
          Text(
            '不会覆盖已有目录；匹配 Git remote 的现有仓库会安全导入。私有仓库使用本机 Git/SSH 凭据。',
            style: const TextStyle(color: CcColors.subtle, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class TeamProjectPullProgressDialog extends StatefulWidget {
  final TeamProjectPullDraft draft;
  final TeamRepoCloneAction clone;

  const TeamProjectPullProgressDialog({
    super.key,
    required this.draft,
    required this.clone,
  });

  @override
  State<TeamProjectPullProgressDialog> createState() =>
      _TeamProjectPullProgressDialogState();
}

class _TeamProjectPullProgressDialogState
    extends State<TeamProjectPullProgressDialog> {
  final List<TeamProjectPullResult> _results = [];
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    await orchestrateTeamProjectPull(
      widget.draft,
      widget.clone,
      onResult: (result) {
        if (mounted) setState(() => _results.add(result));
      },
    );
    if (mounted) setState(() => _done = true);
  }

  @override
  Widget build(BuildContext context) {
    final selectedCount = widget.draft.repoNames.length;
    return PopScope(
      canPop: _done,
      child: AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: Text(
          _done ? '拉取团队项目完成' : '正在拉取团队项目',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: SizedBox(
          width: workspaceConfirmDialogWidth(
            MediaQuery.sizeOf(context),
            preferred: 520,
          ),
          height: workspaceTeamProjectDialogSize(
            MediaQuery.sizeOf(context),
            preferredHeight: 420,
          ).height,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_done) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 10),
              ],
              Text(
                '${widget.draft.workspaceName} · ${_results.length}/$selectedCount',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.code(size: 11.5, color: CcColors.muted),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final result in _results)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          result.success
                              ? Icons.check_circle_outline_rounded
                              : Icons.error_outline_rounded,
                          color: result.success ? CcColors.ok : CcColors.danger,
                        ),
                        title: Text(
                          result.repo.repoName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          result.message,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: _done
                ? () => Navigator.pop(context, List.of(_results))
                : null,
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }
}
