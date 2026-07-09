import 'dart:async';
import 'dart:typed_data';

import 'package:app/api/relay_client.dart';
import 'package:app/api/todo_models.dart';
import 'package:app/widgets/todo_body_view.dart';
import 'package:app/widgets/todo_attachment_thumb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'stale attachment image load cannot overwrite a newer attachment',
    (tester) async {
      final client = _DelayedAttachmentClient();
      final first = _attachment('first.png', 'thumb-test-stale-first');
      final second = _attachment('second.png', 'thumb-test-stale-second');

      await tester.pumpWidget(
        MaterialApp(
          home: TodoAttachmentThumb(
            client: client,
            todoId: 'td1',
            attachment: first,
          ),
        ),
      );
      await tester.pump();
      expect(client.requested, ['first.png']);

      await tester.pumpWidget(
        MaterialApp(
          home: TodoAttachmentThumb(
            client: client,
            todoId: 'td1',
            attachment: second,
          ),
        ),
      );
      await tester.pump();
      expect(client.requested, ['first.png', 'second.png']);

      client.complete('second.png', _secondPng);
      await tester.pumpAndSettle();
      expect(_renderedBytes(tester), _secondPng);

      client.complete('first.png', _firstPng);
      await tester.pumpAndSettle();
      expect(_renderedBytes(tester), _secondPng);
    },
  );

  testWidgets(
    'attachment image reloads and ignores stale loads after client switch',
    (tester) async {
      final firstClient = _DelayedAttachmentClient();
      final secondClient = _DelayedAttachmentClient();
      final attachment = _attachment('same.png', 'thumb-test-client-switch');

      await tester.pumpWidget(
        MaterialApp(
          home: TodoAttachmentThumb(
            client: firstClient,
            todoId: 'td1',
            attachment: attachment,
          ),
        ),
      );
      await tester.pump();
      expect(firstClient.requestedKeys, ['td1/same.png']);

      await tester.pumpWidget(
        MaterialApp(
          home: TodoAttachmentThumb(
            client: secondClient,
            todoId: 'td1',
            attachment: attachment,
          ),
        ),
      );
      await tester.pump();
      expect(secondClient.requestedKeys, ['td1/same.png']);

      secondClient.completeFor('td1', 'same.png', _secondPng);
      await tester.pumpAndSettle();
      expect(_renderedBytes(tester), _secondPng);

      firstClient.completeFor('td1', 'same.png', _firstPng);
      await tester.pumpAndSettle();
      expect(_renderedBytes(tester), _secondPng);
    },
  );

  testWidgets(
    'inline todo image reloads and ignores stale loads after client switch',
    (tester) async {
      final firstClient = _DelayedAttachmentClient();
      final secondClient = _DelayedAttachmentClient();
      final attachment = _attachment('inline.png', 'inline-test-client-switch');

      Widget view(RelayClient client) => MaterialApp(
        home: TodoBodyView(
          client: client,
          todoId: 'td1',
          bodyMd: '![](inline.png)',
          attachments: [attachment],
        ),
      );

      await tester.pumpWidget(view(firstClient));
      await tester.pump();
      expect(firstClient.requestedKeys, ['td1/inline.png']);

      await tester.pumpWidget(view(secondClient));
      await tester.pump();
      expect(secondClient.requestedKeys, ['td1/inline.png']);

      secondClient.completeFor('td1', 'inline.png', _secondPng);
      await tester.pumpAndSettle();
      expect(_renderedBytes(tester), _secondPng);

      firstClient.completeFor('td1', 'inline.png', _firstPng);
      await tester.pumpAndSettle();
      expect(_renderedBytes(tester), _secondPng);
    },
  );
}

TodoAttachment _attachment(String name, String sha256) =>
    TodoAttachment.fromJson({'name': name, 'sha256': sha256, 'size': 1});

Uint8List _renderedBytes(WidgetTester tester) {
  final image = tester.widget<Image>(find.byType(Image));
  return (image.image as MemoryImage).bytes;
}

class _DelayedAttachmentClient extends RelayClient {
  _DelayedAttachmentClient() : super('http://127.0.0.1', 'tok');

  final requested = <String>[];
  final requestedKeys = <String>[];
  final _requests = <String, Completer<List<int>>>{};

  @override
  Future<List<int>> todoAttachment(String id, String name) {
    requested.add(name);
    requestedKeys.add(_key(id, name));
    final completer = Completer<List<int>>();
    _requests[_key(id, name)] = completer;
    return completer.future;
  }

  String _key(String id, String name) => '$id/$name';

  void complete(String name, List<int> bytes) {
    final key = _requests.keys.firstWhere((key) => key.endsWith('/$name'));
    _requests[key]!.complete(bytes);
  }

  void completeFor(String id, String name, List<int> bytes) {
    _requests[_key(id, name)]!.complete(bytes);
  }
}

final _firstPng = Uint8List.fromList([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9c,
  0x63,
  0xf8,
  0xcf,
  0xc0,
  0xf0,
  0x1f,
  0x00,
  0x05,
  0x00,
  0x01,
  0xff,
  0x89,
  0x99,
  0x3d,
  0x1d,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
]);

final _secondPng = Uint8List.fromList([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9c,
  0x63,
  0x60,
  0xf8,
  0xcf,
  0xf0,
  0x1f,
  0x00,
  0x05,
  0x00,
  0x01,
  0xff,
  0x89,
  0x99,
  0x3d,
  0x1d,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
]);
