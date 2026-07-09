import 'package:app/local/online_send_layout.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('online send dialog width fits narrow screens', () {
    expect(onlineSendDialogWidth(const Size(320, 760)), 288);
    expect(onlineSendDialogWidth(const Size(1024, 760)), 440);
    expect(onlineSendDialogWidth(const Size(360, 760), preferred: 460), 328);
    expect(onlineSendDialogWidth(const Size(1024, 760), preferred: 460), 460);
  });

  test('online send user chip width leaves room for wrapping', () {
    expect(
      onlineSendUserChipWidth(const BoxConstraints(maxWidth: 240)),
      closeTo(115.2, 0.001),
    );
    expect(onlineSendUserChipWidth(const BoxConstraints(maxWidth: 640)), 180);
    expect(
      onlineSendUserChipWidth(
        const BoxConstraints(maxWidth: 300),
        preferred: 220,
        maxFraction: 0.4,
      ),
      120,
    );
  });
}
