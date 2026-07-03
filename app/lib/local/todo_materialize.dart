import 'dart:io';

import '../api/todo_models.dart';
import 'path_utils.dart';

// todo_materialize is the 待办-指派 counterpart to internal/inbox/materialize.go
// (the Go side that lands a handoff package's attachments under a local
// `attachments/` dir and points the agent at them). When a todo is assigned to
// a live local session, instead of pasting the raw title+body into the terminal
// we render the full todo (metadata + description + comments + an attachment
// manifest) to a Markdown file inside the target session's workdir and paste a
// short "go read this file" pointer instead — so the agent gets the complete
// picture and knows the attachments exist and how to open them.
//
// Everything here is Flutter-free (dart:io + the plain todo models only) so it
// stays unit-testable without a widget harness.

// TodoMaterializeResult carries the workdir-relative paths the terminal-pointer
// text references, so buildAssignTaskText can name the file/dir the agent
// should Read without re-deriving the layout.
class TodoMaterializeResult {
  // mdRelPath is workdir-relative, e.g. `.cc-handoff/todos/<id>/todo.md`.
  final String mdRelPath;
  // attachmentsRelDir is workdir-relative, e.g. `.cc-handoff/todos/<id>/attachments`.
  final String attachmentsRelDir;
  const TodoMaterializeResult({
    required this.mdRelPath,
    required this.attachmentsRelDir,
  });
}

// _priorityLabels mirrors priorityLabels in widgets/todo_property_controls.dart,
// inlined here so this local util needn't drag in a Flutter/widgets import for
// three strings. Unknown/legacy values fall through to the raw priority string.
const _priorityLabels = {'low': '低', 'normal': '普通', 'high': '高'};

// renderTodoMarkdown is a pure function (no IO): it turns a Todo + its comments
// into the Markdown body written to todo.md. Each metadata line and each of the
// 描述/评论/📎 附件 sections only appears when it has content — an empty body or
// an empty comment/attachment list omits the whole section rather than emitting
// an empty heading.
String renderTodoMarkdown(Todo todo, {required List<TodoComment> comments}) {
  final sb = StringBuffer();
  sb.writeln('# ${todo.title}');
  sb.writeln();

  // Metadata — status/priority always have a value; due/group only when set.
  sb.writeln('- **状态**: ${todoStatusLabel(todo.status)}');
  sb.writeln('- **优先级**: ${_priorityLabels[todo.priority] ?? todo.priority}');
  if (todo.dueAt != null) {
    sb.writeln('- **截止**: ${_fmtDateTime(todo.dueAt!)}');
  }
  final group = todo.groupName;
  if (group != null && group.trim().isNotEmpty) {
    sb.writeln('- **分组**: $group');
  }

  final body = todo.bodyMd.trim();
  if (body.isNotEmpty) {
    sb.writeln();
    sb.writeln('## 描述');
    sb.writeln();
    sb.writeln(body);
  }

  if (comments.isNotEmpty) {
    sb.writeln();
    sb.writeln('## 评论');
    sb.writeln();
    for (final c in comments) {
      sb.writeln('- **${c.authorIdentity}** · ${_fmtDateTime(c.createdAt)}');
      sb.writeln();
      // Indent every line of the body so a multi-line comment stays inside the
      // list item (matches the `  {body}` continuation form).
      final indented = c.body
          .trimRight()
          .split('\n')
          .map((l) => '  $l')
          .join('\n');
      sb.writeln(indented);
    }
  }

  if (todo.attachments.isNotEmpty) {
    sb.writeln();
    sb.writeln('## 📎 附件');
    sb.writeln();
    // Same wording as internal/inbox/materialize.go's renderAttachmentsSection
    // so both sides read identically to the receiving agent.
    sb.writeln(
      '> 发送端附了以下文件,已下载到 `./attachments/`。需要时**用 Read 工具打开它们**(图片直接渲染,文本文件按文本读)。',
    );
    sb.writeln();
    for (final a in todo.attachments) {
      sb.writeln('- `attachments/${a.name}` — ${_humanSize(a.size)}');
    }
  }

  return sb.toString();
}

// materializeTodoAssignment writes renderTodoMarkdown's output to
// <workdir>/.cc-handoff/todos/<id>/todo.md and, when the todo has attachments,
// downloads each into a sibling attachments/ dir (best-effort per file, exactly
// like DownloadAttachments in the Go inbox: a single fetch/write failure only
// skips that one attachment, never aborts the rest or todo.md itself).
//
// Returns null — signalling "couldn't land the file, fall back to pasting the
// raw text" — when workdir is empty or the directory can't be created (e.g. a
// brand-new session whose process hasn't actually materialized its workdir
// yet). Re-assigning the same todo just overwrites the previous files;
// writeAsString/writeAsBytes truncate, and there's no versioning/merging.
Future<TodoMaterializeResult?> materializeTodoAssignment({
  required String workdir,
  required Todo todo,
  required List<TodoComment> comments,
  required Future<List<int>> Function(String name) fetchAttachment,
}) async {
  if (workdir.trim().isEmpty) return null;

  final relDir = pathJoin(pathJoin('.cc-handoff', 'todos'), todo.id);
  final mdRel = pathJoin(relDir, 'todo.md');
  final attachRel = pathJoin(relDir, 'attachments');

  try {
    await Directory(pathJoin(workdir, relDir)).create(recursive: true);
    await File(pathJoin(workdir, mdRel))
        .writeAsString(renderTodoMarkdown(todo, comments: comments));

    if (todo.attachments.isNotEmpty) {
      final attachAbs = pathJoin(workdir, attachRel);
      await Directory(attachAbs).create(recursive: true);
      for (final a in todo.attachments) {
        try {
          final bytes = await fetchAttachment(a.name);
          await File(pathJoin(attachAbs, a.name)).writeAsBytes(bytes);
        } catch (_) {
          // Best-effort per attachment: skip this one, keep the rest + todo.md.
        }
      }
    }
    return TodoMaterializeResult(mdRelPath: mdRel, attachmentsRelDir: attachRel);
  } catch (_) {
    // Directory create / todo.md write failed — treat as "no materialization"
    // so the caller falls back to the raw-paste path rather than erroring.
    return null;
  }
}

// buildAssignTaskText is the short message actually pasted into the terminal:
// a one-line title plus a pointer to the file (and, when present, the
// attachments dir) the agent should open with Read.
String buildAssignTaskText(Todo todo, TodoMaterializeResult result) {
  final sb = StringBuffer();
  sb.write('[待办] ${todo.title}');
  sb.write('\n\n完整内容见 ${result.mdRelPath}，用 Read 工具直接打开。');
  if (todo.attachments.isNotEmpty) {
    sb.write('\n\n附件已下载到 ${result.attachmentsRelDir}/ 下，同样用 Read 工具查看。');
  }
  return sb.toString();
}

String _fmtDateTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

// _humanSize renders bytes as "542 KB" / "1.2 MB" etc. — a Dart transcription
// of humanSize in internal/inbox/materialize.go so both manifests read alike.
String _humanSize(int n) {
  const kb = 1024;
  const mb = 1024 * 1024;
  if (n >= mb) return '${(n / mb).toStringAsFixed(1)} MB';
  if (n >= kb) return '${n ~/ kb} KB';
  return '$n B';
}
