import 'package:flutter/material.dart';

import '../local/session_overview.dart';
import '../theme.dart';

enum CapsuleBindingMode { none, team, project }

class CapsuleBindingPicker extends StatelessWidget {
  final CapsuleBindingCatalog? catalog;
  final CapsuleBinding binding;
  final ValueChanged<CapsuleBinding> onChanged;
  final bool enabled;
  final String? error;

  const CapsuleBindingPicker({
    super.key,
    required this.catalog,
    required this.binding,
    required this.onChanged,
    this.enabled = true,
    this.error,
  });

  CapsuleBindingMode get _mode => binding.projectId.isNotEmpty
      ? CapsuleBindingMode.project
      : binding.orgId.isNotEmpty
      ? CapsuleBindingMode.team
      : CapsuleBindingMode.none;

  List<CapsuleBindingProject> get _projects => [
    for (final project in catalog?.projects ?? const [])
      if (project.orgId == binding.orgId) project,
  ];

  void _setMode(CapsuleBindingMode mode) {
    if (mode == CapsuleBindingMode.none) {
      onChanged(const CapsuleBinding());
      return;
    }
    final teams = catalog?.teams ?? const <CapsuleBindingTeam>[];
    if (teams.isEmpty) return;
    final team = teams.firstWhere(
      (item) => item.id == binding.orgId,
      orElse: () => teams.first,
    );
    if (mode == CapsuleBindingMode.team) {
      onChanged(CapsuleBinding(orgId: team.id));
      return;
    }
    final projects = [
      for (final project in catalog?.projects ?? const [])
        if (project.orgId == team.id) project,
    ];
    onChanged(
      CapsuleBinding(
        orgId: team.id,
        projectId: projects.isEmpty ? '' : projects.first.id,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final teams = catalog?.teams ?? const <CapsuleBindingTeam>[];
    final loading = catalog == null && error == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('环境绑定', style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            if (loading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SegmentedButton<CapsuleBindingMode>(
          key: const ValueKey('capsule-binding-mode'),
          segments: [
            const ButtonSegment(
              value: CapsuleBindingMode.none,
              label: Text('不绑定'),
            ),
            ButtonSegment(
              value: CapsuleBindingMode.team,
              enabled: teams.isNotEmpty,
              label: const Text('团队'),
            ),
            ButtonSegment(
              value: CapsuleBindingMode.project,
              enabled:
                  teams.isNotEmpty && (catalog?.projects.isNotEmpty ?? false),
              label: const Text('项目'),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: enabled ? (value) => _setMode(value.first) : null,
        ),
        if (_mode != CapsuleBindingMode.none) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey('capsule-binding-team-${binding.orgId}'),
            initialValue: teams.any((team) => team.id == binding.orgId)
                ? binding.orgId
                : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '团队', isDense: true),
            items: [
              for (final team in teams)
                DropdownMenuItem(
                  value: team.id,
                  child: Text(
                    team.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: !enabled
                ? null
                : (id) {
                    if (id == null) return;
                    if (_mode == CapsuleBindingMode.project) {
                      final projects = [
                        for (final project in catalog?.projects ?? const [])
                          if (project.orgId == id) project,
                      ];
                      onChanged(
                        CapsuleBinding(
                          orgId: id,
                          projectId: projects.isEmpty ? '' : projects.first.id,
                        ),
                      );
                    } else {
                      onChanged(CapsuleBinding(orgId: id));
                    }
                  },
          ),
        ],
        if (_mode == CapsuleBindingMode.project) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey('capsule-binding-project-${binding.projectId}'),
            initialValue:
                _projects.any((project) => project.id == binding.projectId)
                ? binding.projectId
                : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '项目环境', isDense: true),
            items: [
              for (final project in _projects)
                DropdownMenuItem(
                  value: project.id,
                  child: Text(
                    project.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: !enabled
                ? null
                : (id) {
                    if (id == null) return;
                    onChanged(
                      CapsuleBinding(orgId: binding.orgId, projectId: id),
                    );
                  },
          ),
        ],
        if (error != null && error!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              error!,
              key: const ValueKey('capsule-binding-error'),
              style: const TextStyle(color: CcColors.danger, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
