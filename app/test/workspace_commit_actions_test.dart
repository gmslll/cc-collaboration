import 'package:app/screens/workspace_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('workspace commit actions require target and non-empty message', () {
    expect(
      workspaceCommitActionEnabled(
        hasCommitTarget: true,
        message: '  fix app  ',
        loading: false,
      ),
      isTrue,
    );
    expect(
      workspaceCommitActionEnabled(
        hasCommitTarget: true,
        message: '   ',
        loading: false,
      ),
      isFalse,
    );
    expect(
      workspaceCommitActionEnabled(
        hasCommitTarget: false,
        message: 'fix app',
        loading: false,
      ),
      isFalse,
    );
    expect(
      workspaceCommitActionEnabled(
        hasCommitTarget: true,
        message: 'fix app',
        loading: true,
      ),
      isFalse,
    );
  });
}
