import 'dart:io';

import 'package:app/api/todo_models.dart';
import 'package:app/local/todo_materialize.dart';
import 'package:flutter_test/flutter_test.dart';

// Builds a Todo via fromJson (its only map-driven constructor), mirroring the
// fixture style in todo_models_test.dart.
Todo makeTodo({
  String id = 'todo-1',
  String title = 'T',
  String bodyMd = '',
  String status = 'todo',
  String priority = 'normal',
  String? groupName,
  String? dueAt,
  List<Map<String, dynamic>> attachments = const [],
}) =>
    Todo.fromJson({
      'id': id,
      'project_id': null,
      'owner_identity': 'alice',
      'title': title,
      'body_md': bodyMd,
      'status': status,
      'priority': priority,
      'group_name': groupName,
      'due_at': dueAt,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
      'comment_count': 0,
      'attachment_count': attachments.length,
      'attachments': attachments,
    });

Map<String, dynamic> att(String name, int size) =>
    {'name': name, 'sha256': '', 'size': size};

TodoComment makeComment(String author, String body) => TodoComment.fromJson({
      'author_identity': author,
      'body': body,
      'created_at': '2026-01-02T03:04:00Z',
    });

void main() {
  group('renderTodoMarkdown (pure)', () {
    test('minimal todo: title + metadata, no optional sections', () {
      final md = renderTodoMarkdown(makeTodo(title: '修 bug'), comments: const []);
      expect(md, contains('# 修 bug'));
      expect(md, contains('- **状态**: 待办'));
      expect(md, contains('- **优先级**: 普通'));
      // No body / comments / attachments → those whole sections are omitted.
      expect(md, isNot(contains('## 描述')));
      expect(md, isNot(contains('## 评论')));
      expect(md, isNot(contains('## 📎 附件')));
      // Optional metadata lines only appear when set.
      expect(md, isNot(contains('**截止**')));
      expect(md, isNot(contains('**分组**')));
    });

    test('non-empty body emits the 描述 section', () {
      final md = renderTodoMarkdown(
        makeTodo(bodyMd: '这是正文\n第二行'),
        comments: const [],
      );
      expect(md, contains('## 描述'));
      expect(md, contains('这是正文'));
      expect(md, contains('第二行'));
    });

    test('empty/whitespace body omits the 描述 section', () {
      final md = renderTodoMarkdown(makeTodo(bodyMd: '   \n  '), comments: const []);
      expect(md, isNot(contains('## 描述')));
    });

    test('comments emit the 评论 section with author + body', () {
      final md = renderTodoMarkdown(
        makeTodo(),
        comments: [makeComment('bob', '看起来是缓存问题'), makeComment('carol', '同意')],
      );
      expect(md, contains('## 评论'));
      expect(md, contains('**bob**'));
      expect(md, contains('看起来是缓存问题'));
      expect(md, contains('**carol**'));
      expect(md, contains('同意'));
    });

    test('empty comment list omits the 评论 section', () {
      final md = renderTodoMarkdown(makeTodo(), comments: const []);
      expect(md, isNot(contains('## 评论')));
    });

    test('attachments emit the 📎 附件 section with Read-tool wording + sizes', () {
      final md = renderTodoMarkdown(
        makeTodo(attachments: [att('shot.png', 2048), att('log.txt', 512)]),
        comments: const [],
      );
      expect(md, contains('## 📎 附件'));
      expect(md, contains('用 Read 工具打开它们'));
      expect(md, contains('- `attachments/shot.png` — 2 KB'));
      expect(md, contains('- `attachments/log.txt` — 512 B'));
    });

    test('due + group metadata lines appear only when present', () {
      final md = renderTodoMarkdown(
        makeTodo(dueAt: '2026-07-10T09:30:00Z', groupName: 'sprint-1'),
        comments: const [],
      );
      expect(md, contains('**截止**'));
      expect(md, contains('- **分组**: sprint-1'));
    });
  });

  group('materializeTodoAssignment (IO)', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('todo_mat_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('writes todo.md + attachment bytes; returns rel paths', () async {
      final todo = makeTodo(
        id: 'abc',
        title: '带附件的待办',
        bodyMd: '正文',
        attachments: [att('a.bin', 3), att('b.bin', 2)],
      );
      final fetched = <String, List<int>>{
        'a.bin': [1, 2, 3],
        'b.bin': [9, 8],
      };
      final res = await materializeTodoAssignment(
        workdir: tmp.path,
        todo: todo,
        comments: [makeComment('bob', '备注')],
        fetchAttachment: (name) async => fetched[name]!,
      );

      expect(res, isNotNull);
      expect(res!.mdRelPath, '.cc-handoff/todos/abc/todo.md');
      expect(res.attachmentsRelDir, '.cc-handoff/todos/abc/attachments');

      final mdFile = File('${tmp.path}/${res.mdRelPath}');
      expect(mdFile.existsSync(), isTrue);
      final md = mdFile.readAsStringSync();
      expect(md, contains('# 带附件的待办'));
      expect(md, contains('## 描述'));
      expect(md, contains('## 评论'));
      expect(md, contains('## 📎 附件'));

      expect(
        File('${tmp.path}/${res.attachmentsRelDir}/a.bin').readAsBytesSync(),
        [1, 2, 3],
      );
      expect(
        File('${tmp.path}/${res.attachmentsRelDir}/b.bin').readAsBytesSync(),
        [9, 8],
      );
    });

    test('a single attachment fetch failure skips only that file', () async {
      final todo = makeTodo(
        id: 'abc',
        attachments: [att('good.bin', 2), att('bad.bin', 2), att('good2.bin', 1)],
      );
      final res = await materializeTodoAssignment(
        workdir: tmp.path,
        todo: todo,
        comments: const [],
        fetchAttachment: (name) async {
          if (name == 'bad.bin') throw Exception('boom');
          return [7];
        },
      );

      // The whole operation still succeeds and todo.md is intact.
      expect(res, isNotNull);
      expect(File('${tmp.path}/${res!.mdRelPath}').existsSync(), isTrue);
      final dir = '${tmp.path}/${res.attachmentsRelDir}';
      expect(File('$dir/good.bin').existsSync(), isTrue);
      expect(File('$dir/good2.bin').existsSync(), isTrue);
      // Only the failing one is missing.
      expect(File('$dir/bad.bin').existsSync(), isFalse);
    });

    test('empty workdir returns null (caller falls back to raw paste)', () async {
      final res = await materializeTodoAssignment(
        workdir: '',
        todo: makeTodo(),
        comments: const [],
        fetchAttachment: (_) async => const [],
      );
      expect(res, isNull);
    });

    test('re-assigning the same todo overwrites without error', () async {
      final first = makeTodo(id: 'abc', bodyMd: '第一版正文');
      await materializeTodoAssignment(
        workdir: tmp.path,
        todo: first,
        comments: const [],
        fetchAttachment: (_) async => const [],
      );
      // Second assignment with different content + a fresh attachment.
      final second = makeTodo(
        id: 'abc',
        bodyMd: '第二版正文',
        attachments: [att('new.bin', 1)],
      );
      final res = await materializeTodoAssignment(
        workdir: tmp.path,
        todo: second,
        comments: const [],
        fetchAttachment: (_) async => [42],
      );

      expect(res, isNotNull);
      final md = File('${tmp.path}/${res!.mdRelPath}').readAsStringSync();
      expect(md, contains('第二版正文'));
      expect(md, isNot(contains('第一版正文')));
      expect(
        File('${tmp.path}/${res.attachmentsRelDir}/new.bin').readAsBytesSync(),
        [42],
      );
    });
  });

  group('buildAssignTaskText', () {
    const result = TodoMaterializeResult(
      mdRelPath: '.cc-handoff/todos/abc/todo.md',
      attachmentsRelDir: '.cc-handoff/todos/abc/attachments',
    );

    test('no attachments: title + file pointer only', () {
      final text = buildAssignTaskText(makeTodo(title: '干活'), result);
      expect(text, contains('[待办] 干活'));
      expect(text, contains('完整内容见 .cc-handoff/todos/abc/todo.md'));
      expect(text, contains('用 Read 工具直接打开'));
      expect(text, isNot(contains('附件已下载到')));
    });

    test('with attachments: also points at the attachments dir', () {
      final text = buildAssignTaskText(
        makeTodo(title: '干活', attachments: [att('x.png', 1)]),
        result,
      );
      expect(text, contains('附件已下载到 .cc-handoff/todos/abc/attachments/ 下'));
    });
  });
}
