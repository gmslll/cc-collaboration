import 'package:app/local/session_overview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SessionStatus parses hook-derived overview states', () {
    expect(sessionStatusFromName('runningTool'), SessionStatus.runningTool);
    expect(sessionStatusFromName('toolFailed'), SessionStatus.toolFailed);
    expect(
      sessionStatusFromName('waitingPermission'),
      SessionStatus.waitingPermission,
    );
    expect(statusLabel(SessionStatus.compacting), '压缩中');
    expect(sessionStatusIsActive(SessionStatus.subagent), isTrue);
    expect(sessionStatusIsActive(SessionStatus.toolFailed), isTrue);
    expect(sessionStatusIsActive(SessionStatus.waitingInput), isFalse);
  });
}
