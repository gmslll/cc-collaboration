import 'package:app/local/session_overview.dart';
import 'package:app/theme.dart';
import 'package:app/widgets/capsule_binding_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const catalog = CapsuleBindingCatalog(
    teams: [
      CapsuleBindingTeam('org-a', 'Team A'),
      CapsuleBindingTeam('org-b', 'Team B'),
    ],
    projects: [
      CapsuleBindingProject('project-a', 'org-a', 'Project A'),
      CapsuleBindingProject('project-b', 'org-b', 'Project B'),
    ],
  );

  test('visibility description follows the effective audience', () {
    expect(
      capsuleVisibilityDescription(false, const CapsuleBinding()),
      '只有你自己能在广场看到',
    );
    expect(
      capsuleVisibilityDescription(true, const CapsuleBinding(orgId: 'org-a')),
      '同团队成员能在广场看到',
    );
    expect(
      capsuleVisibilityDescription(
        true,
        const CapsuleBinding(orgId: 'org-a', projectId: 'project-a'),
      ),
      '该项目的参与者能在广场看到',
    );
  });

  testWidgets('binding picker supports none, team and project scopes', (
    tester,
  ) async {
    var binding = const CapsuleBinding();

    Widget app() => MaterialApp(
      theme: ccTheme(),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => CapsuleBindingPicker(
            catalog: catalog,
            binding: binding,
            onChanged: (next) => setState(() => binding = next),
          ),
        ),
      ),
    );

    await tester.pumpWidget(app());
    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    expect(binding.orgId, 'org-a');
    expect(binding.projectId, 'project-a');

    await tester.tap(find.text('Team A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Team B').last);
    await tester.pumpAndSettle();
    expect(binding.orgId, 'org-b');
    expect(binding.projectId, 'project-b');

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('capsule-binding-mode')),
        matching: find.text('团队'),
      ),
    );
    await tester.pumpAndSettle();
    expect(binding.orgId, 'org-b');
    expect(binding.projectId, isEmpty);

    await tester.tap(find.text('不绑定'));
    await tester.pumpAndSettle();
    expect(binding.orgId, isEmpty);
    expect(binding.projectId, isEmpty);
  });
}
