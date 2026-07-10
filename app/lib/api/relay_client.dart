import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'models.dart';
import 'todo_models.dart';

// RelayClient is a thin HTTP client over the relay's /v1 API (Bearer auth).
// Shared data only — local ops (pickup/worktree/terminal) go through the
// cc-handoff CLI + the PTY, not here.
class RelayClient {
  final Dio _dio;

  RelayClient(String baseUrl, String token)
    : _dio = Dio(
        BaseOptions(
          baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
          headers: {'Authorization': 'Bearer $token'},
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
        ),
      );

  Future<List<ListItem>> handoffs({String as = 'recipient'}) async {
    final r = await _dio.get('/v1/handoffs', queryParameters: {'as': as});
    return _asList(
      r.data,
      'items',
    ).map((e) => ListItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<ListItem>> projectHandoffs({
    String? project,
    int limit = 100,
  }) async {
    final r = await _dio.get(
      '/v1/handoffs',
      queryParameters: {
        'scope': 'project',
        'project': ?project,
        'limit': limit,
      },
    );
    return _asList(
      r.data,
      'items',
    ).map((e) => ListItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Package> get(String id) async {
    final r = await _dio.get('/v1/handoffs/${_pathSegment(id)}');
    return Package.fromJson(r.data as Map<String, dynamic>);
  }

  // capsules lists the plaza: every public capsule + the caller's own private
  // ones, newest first.
  Future<List<CapsuleListItem>> capsules() async {
    final r = await _dio.get('/v1/capsules');
    return _asList(
      r.data,
      'capsules',
    ).map((e) => CapsuleListItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  // deleteCapsule / patchCapsule are owner-only edits of one's own plaza capsule.
  Future<void> deleteCapsule(String id) =>
      _dio.delete('/v1/capsules/${_pathSegment(id)}');

  Future<void> patchCapsule(String id, {String? visibility, String? summary}) {
    final data = <String, String>{};
    if (visibility != null) data['visibility'] = visibility;
    if (summary != null) data['summary'] = summary;
    return _dio.patch('/v1/capsules/${_pathSegment(id)}', data: data);
  }

  Future<Status> status(String id) async {
    final r = await _dio.get('/v1/handoffs/${_pathSegment(id)}/status');
    return Status.fromJson(r.data as Map<String, dynamic>);
  }

  // prompt returns the server pre-rendered full pickup prompt (markdown text).
  Future<String> prompt(String id) async {
    final r = await _dio.get(
      '/v1/handoffs/${_pathSegment(id)}/prompt',
      options: Options(responseType: ResponseType.plain),
    );
    return r.data?.toString() ?? '';
  }

  Future<List<int>> attachment(String id, String name) async {
    final r = await _dio.get(
      '/v1/handoffs/${_pathSegment(id)}/attachments/${_pathSegment(name)}',
      options: Options(responseType: ResponseType.bytes),
    );
    return (r.data as List).cast<int>();
  }

  Future<List<Comment>> comments(String id) async {
    final r = await _dio.get('/v1/handoffs/${_pathSegment(id)}/comments');
    return _asList(
      r.data,
      'comments',
    ).map((e) => Comment.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Comment> postComment(String id, String body) async {
    final r = await _dio.post(
      '/v1/handoffs/${_pathSegment(id)}/comment',
      data: {'body': body},
    );
    return Comment.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> ack(String id) =>
      _dio.post('/v1/handoffs/${_pathSegment(id)}/ack');

  Future<void> retract(String id, String reason) => _dio.post(
    '/v1/handoffs/${_pathSegment(id)}/retract',
    data: {'reason': reason},
  );

  Future<void> reassign(String id, String to, String reason) => _dio.post(
    '/v1/handoffs/${_pathSegment(id)}/reassign',
    data: {'to': to, 'reason': reason},
  );

  // --- todos ---

  // todos lists either personal or team todos (never both — TodoStore.refresh
  // issues one call per scope and merges locally). scope=project with no
  // [project] filter returns the union of every project the caller belongs to.
  Future<List<Todo>> todos({
    required String scope, // personal | project | assigned | all
    String? project,
    String? status,
    String? group,
    int? limit,
  }) async {
    final r = await _dio.get(
      '/v1/todos',
      queryParameters: {
        'scope': scope.trim(),
        'project': ?_trimOrNull(project),
        'status': ?_trimOrNull(status),
        'group': ?_trimOrNull(group),
        'limit': ?limit,
      },
    );
    return _asList(
      r.data,
      'items',
    ).map((e) => Todo.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Todo> todo(String id) async {
    final r = await _dio.get('/v1/todos/${_pathSegment(id)}');
    return Todo.fromJson(r.data as Map<String, dynamic>);
  }

  Future<Todo> createTodo({
    required String title,
    String bodyMd = '',
    String priority = 'normal',
    String? projectId,
    String recurrence = '',
    DateTime? dueAt,
    String? workspaceName,
    String? repoName,
    String? groupName,
  }) async {
    final r = await _dio.post(
      '/v1/todos',
      data: {
        'title': title,
        'body_md': bodyMd,
        'priority': priority.trim(),
        'project_id': ?_trimOrNull(projectId),
        'recurrence': recurrence.trim(),
        if (dueAt != null) 'due_at': dueAt.toUtc().toIso8601String(),
        'workspace_name': ?_trimOrNull(workspaceName),
        'repo_name': ?_trimOrNull(repoName),
        'group_name': ?_trimOrNull(groupName),
      },
    );
    return Todo.fromJson(r.data as Map<String, dynamic>);
  }

  // updateTodo only sends fields the caller actually passed — except due_at,
  // which needs [clearDueAt] to distinguish "leave it alone" (key omitted)
  // from "clear it" (key present with a JSON null value). workspaceName/
  // repoName/groupName follow the plain-optional pattern (null = leave
  // alone): pass an empty string, not null, to clear an existing value.
  Future<Todo> updateTodo(
    String id, {
    String? title,
    String? bodyMd,
    String? priority,
    String? recurrence,
    DateTime? dueAt,
    bool clearDueAt = false,
    String? workspaceName,
    String? repoName,
    String? groupName,
  }) async {
    final r = await _dio.patch(
      '/v1/todos/${_pathSegment(id)}',
      data: {
        'title': ?title,
        'body_md': ?bodyMd,
        'priority': ?_trimOptional(priority),
        'recurrence': ?_trimOptional(recurrence),
        if (clearDueAt)
          'due_at': null
        else if (dueAt != null)
          'due_at': dueAt.toUtc().toIso8601String(),
        'workspace_name': ?_trimOptional(workspaceName),
        'repo_name': ?_trimOptional(repoName),
        'group_name': ?_trimOptional(groupName),
      },
    );
    return Todo.fromJson(r.data as Map<String, dynamic>);
  }

  // --- todo groups (free-form string field, no separate table) ---

  // todoGroups lists the distinct, non-empty group names in use —
  // personal-scoped when projectId is omitted, or scoped to that one team
  // project otherwise. Mirrors store.Store.ListTodoGroups' scoping exactly;
  // there's no "union of every project" mode.
  Future<List<String>> todoGroups({String? projectId}) async {
    final r = await _dio.get(
      '/v1/todos/groups',
      queryParameters: {'project': ?_trimOrNull(projectId)},
    );
    return _asList(r.data, 'groups').cast<String>();
  }

  Future<void> renameTodoGroup(
    String oldName,
    String newName, {
    String? projectId,
  }) => _dio.post(
    '/v1/todos/groups/rename',
    data: {
      'project_id': _trimOptional(projectId) ?? '',
      'old_name': oldName.trim(),
      'new_name': newName.trim(),
    },
  );

  Future<void> clearTodoGroup(String name, {String? projectId}) => _dio.post(
    '/v1/todos/groups/clear',
    data: {'project_id': _trimOptional(projectId) ?? '', 'name': name.trim()},
  );

  Future<Todo> setTodoStatus(String id, TodoStatus status) async {
    final r = await _dio.post(
      '/v1/todos/${_pathSegment(id)}/status',
      data: {'status': todoStatusName(status)},
    );
    return Todo.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> deleteTodo(String id) =>
      _dio.delete('/v1/todos/${_pathSegment(id)}');

  // assignTodo also doubles as "assign to a team member" (assigneeIdentity
  // only) and "assign to a specific local session" (all three set) — the
  // local-session-dispatch path additionally calls SessionOverviewStore's
  // dispatchHandler to actually deliver the task text (that's Track G/I, not
  // this client — this call only syncs visibility for other viewers).
  // assigneeAgentSessionId/assigneeWorkdir/assigneeAgentKind are the
  // permanent-resume trio (see Todo.assigneeAgentSessionId) — pass them
  // alongside assigneeSessionId when the target is a live agent session so
  // "打开/恢复会话" can respawn it with --resume long after the bus session
  // id itself has gone stale.
  Future<Todo> assignTodo(
    String id, {
    String? assigneeIdentity,
    String? assigneeSessionId,
    String? assigneeSessionLabel,
    String? assigneeAgentSessionId,
    String? assigneeWorkdir,
    String? assigneeAgentKind,
  }) async {
    final identity = _trimOptional(assigneeIdentity);
    final clearAssignment = identity == null || identity.isEmpty;
    final sessionId = clearAssignment ? null : _trimOrNull(assigneeSessionId);
    final sessionLabel = clearAssignment
        ? null
        : _trimOrNull(assigneeSessionLabel);
    final agentSessionId = clearAssignment
        ? null
        : _trimOrNull(assigneeAgentSessionId);
    final workdir = clearAssignment ? null : _trimOrNull(assigneeWorkdir);
    final agentKind = clearAssignment ? null : _trimOrNull(assigneeAgentKind);
    final r = await _dio.post(
      '/v1/todos/${_pathSegment(id)}/assign',
      data: {
        'assignee_identity': ?identity,
        'assignee_session_id': ?sessionId,
        'assignee_session_label': ?sessionLabel,
        'assignee_agent_session_id': ?agentSessionId,
        'assignee_workdir': ?workdir,
        'assignee_agent_kind': ?agentKind,
      },
    );
    return Todo.fromJson(r.data as Map<String, dynamic>);
  }

  Future<List<TodoComment>> todoComments(String id) async {
    final r = await _dio.get('/v1/todos/${_pathSegment(id)}/comments');
    return _asList(
      r.data,
      'comments',
    ).map((e) => TodoComment.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<TodoComment> postTodoComment(String id, String body) async {
    final r = await _dio.post(
      '/v1/todos/${_pathSegment(id)}/comment',
      data: {'body': body},
    );
    return TodoComment.fromJson(r.data as Map<String, dynamic>);
  }

  // uploadTodoAttachment sends the raw bytes as the request body (not
  // multipart) with a X-Content-Sha256 header — identical wire protocol to
  // handoff attachments. Must pass a Uint8List (not a plain List<int>) so
  // dio skips its JSON transformer and writes the bytes verbatim.
  Future<void> uploadTodoAttachment(String id, String name, List<int> bytes) {
    final body = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return _dio.post(
      '/v1/todos/${_pathSegment(id)}/attachments/${_pathSegment(name)}',
      data: body,
      options: Options(
        contentType: 'application/octet-stream',
        headers: {'X-Content-Sha256': sha256.convert(body).toString()},
      ),
    );
  }

  Future<List<int>> todoAttachment(String id, String name) async {
    final r = await _dio.get(
      '/v1/todos/${_pathSegment(id)}/attachments/${_pathSegment(name)}',
      options: Options(responseType: ResponseType.bytes),
    );
    return (r.data as List).cast<int>();
  }

  // --- multi-tenant (F3) ---

  Future<Me> me() async {
    final r = await _dio.get('/v1/me');
    return Me.fromJson(r.data as Map<String, dynamic>);
  }

  Future<List<OnlineUser>> onlineUsers() async {
    final r = await _dio.get('/v1/users/online');
    return _asList(
      r.data,
      'users',
    ).map((e) => OnlineUser.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Organization>> organizations() async {
    final r = await _dio.get('/v1/orgs');
    return _asList(
      r.data,
      'organizations',
    ).map((e) => Organization.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<OrganizationDetail> organization(String id) async {
    final r = await _dio.get('/v1/orgs/${_idSegment(id)}');
    return OrganizationDetail.fromJson(r.data as Map<String, dynamic>);
  }

  Future<Organization> createOrganization(String name) async {
    final r = await _dio.post('/v1/orgs', data: {'name': name.trim()});
    return Organization.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> deleteOrganization(String id) =>
      _dio.delete('/v1/orgs/${_idSegment(id)}');

  Future<void> addOrganizationMember(String id, String identity, String role) =>
      _dio.post(
        '/v1/orgs/${_idSegment(id)}/members',
        data: {'identity': identity.trim(), 'role': role.trim()},
      );

  Future<void> removeOrganizationMember(String id, String identity) =>
      _dio.delete('/v1/orgs/${_idSegment(id)}/members/${_idSegment(identity)}');

  Future<Invitation> inviteOrganizationMember(
    String id,
    String identity,
    String role,
  ) async {
    final r = await _dio.post(
      '/v1/orgs/${_idSegment(id)}/invitations',
      data: {'identity': identity.trim(), 'role': role.trim()},
    );
    return Invitation.fromJson(_asStringMap(r.data?['invitation']));
  }

  Future<void> cancelOrganizationInvitation(String id, String invitationId) =>
      _dio.delete(
        '/v1/orgs/${_idSegment(id)}/invitations/${_idSegment(invitationId)}',
      );

  Future<List<Invitation>> invitations() async {
    final r = await _dio.get('/v1/invitations');
    return _asList(
      r.data,
      'invitations',
    ).map((e) => Invitation.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> acceptInvitation(String id) =>
      _dio.post('/v1/invitations/${_idSegment(id)}/accept');

  Future<void> declineInvitation(String id) =>
      _dio.post('/v1/invitations/${_idSegment(id)}/decline');

  // --- per-identity synced settings (see internal/relay/settings.go) ---

  // getSetting returns the caller's synced setting blob for [key], or null when
  // unset. The relay stores an opaque JSON value scoped to the identity; the
  // Todo board's view config (todo.view) is an object, so this decodes to a Map.
  Future<Map<String, dynamic>?> getSetting(String key) async {
    final r = await _dio.get('/v1/settings/${_pathSegment(key)}');
    final data = r.data as Map<String, dynamic>;
    if (data['found'] != true) return null;
    final v = data['value'];
    return v is Map<String, dynamic> ? v : null;
  }

  Future<void> putSetting(String key, Map<String, dynamic> value) =>
      _dio.put('/v1/settings/${_pathSegment(key)}', data: {'value': value});

  // --- cross-user session messaging ---

  // publishSessions advertises this app's currently-open terminal sessions so
  // peers can target a specific one. Transient on the relay (TTL'd).
  Future<void> publishSessions(List<Map<String, dynamic>> sessions) =>
      _dio.post('/v1/sessions', data: {'sessions': sessions});

  // userSessions fetches another user's currently-open sessions (empty if
  // they're offline / haven't published).
  Future<List<RemoteSession>> userSessions(String identity) async {
    final r = await _dio.get('/v1/users/${_idSegment(identity)}/sessions');
    return _asList(
      r.data,
      'sessions',
    ).map((e) => RemoteSession.fromJson(e as Map<String, dynamic>)).toList();
  }

  // sendMessage delivers [body] to a specific session on [recipient]'s machine
  // (transient; the recipient's app confirms before injecting).
  Future<void> sendMessage(
    String recipient,
    String sessionId,
    String body, {
    String? project,
    String? projectId,
  }) => _dio.post(
    '/v1/messages',
    data: {
      'recipient': recipient.trim(),
      'session_id': sessionId.trim(),
      'body': body,
      'project': ?_trimOrNull(project),
      'project_id': ?_trimOrNull(projectId),
    },
  );

  Future<List<Project>> projects() async {
    final r = await _dio.get('/v1/projects');
    return _asList(
      r.data,
      'projects',
    ).map((e) => Project.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Project> createProject(String name, {String? orgId}) async {
    final teamId = _trimOrNull(orgId);
    final r = await _dio.post(
      '/v1/projects',
      data: {'name': name.trim(), 'org_id': ?teamId},
    );
    return Project.fromJson(r.data as Map<String, dynamic>);
  }

  Future<ProjectDetail> project(String id) async {
    final r = await _dio.get('/v1/projects/${_idSegment(id)}');
    return ProjectDetail.fromJson(r.data as Map<String, dynamic>);
  }

  Future<List<ProjectDetail>> cloneableProjectDetails() async {
    final summaries = await projects();
    final details = await Future.wait([
      for (final summary in summaries) project(summary.id),
    ]);
    return details
        .where((detail) => detail.cloneableRepos.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> renameProject(String id, String name) =>
      _dio.patch('/v1/projects/${_idSegment(id)}', data: {'name': name.trim()});

  Future<void> deleteProject(String id) =>
      _dio.delete('/v1/projects/${_idSegment(id)}');

  Future<void> mapRepo(String id, String repoName) => _dio.post(
    '/v1/projects/${_idSegment(id)}/repos',
    data: {'repo_name': repoName.trim()},
  );

  Future<ProjectRepo> upsertProjectRepo(
    String id,
    String repoName,
    String cloneUrl,
  ) async {
    final r = await _dio.post(
      '/v1/projects/${_idSegment(id)}/repos',
      data: {'repo_name': repoName.trim(), 'clone_url': cloneUrl.trim()},
    );
    return ProjectRepo.fromJson(_asStringMap(r.data?['repo']));
  }

  Future<void> unmapRepo(String id, String repoName) => _dio.delete(
    '/v1/projects/${_idSegment(id)}/repos',
    queryParameters: {'repo_name': repoName.trim()},
  );

  Future<void> addMember(String id, String identity, String role) => _dio.post(
    '/v1/projects/${_idSegment(id)}/members',
    data: {'identity': identity.trim(), 'role': role.trim()},
  );

  Future<void> removeMember(String id, String identity) => _dio.delete(
    '/v1/projects/${_idSegment(id)}/members/${_idSegment(identity)}',
  );

  Future<Invitation> inviteProjectMember(
    String id,
    String identity,
    String role,
  ) async {
    final r = await _dio.post(
      '/v1/projects/${_idSegment(id)}/invitations',
      data: {'identity': identity.trim(), 'role': role.trim()},
    );
    return Invitation.fromJson(_asStringMap(r.data?['invitation']));
  }

  Future<void> cancelProjectInvitation(
    String id,
    String invitationId,
  ) => _dio.delete(
    '/v1/projects/${_idSegment(id)}/invitations/${_idSegment(invitationId)}',
  );

  Future<void> changePassword(String oldPw, String newPw) =>
      _dio.post('/v1/password', data: {'old': oldPw, 'new': newPw});

  Future<List<MachineToken>> tokens() async {
    final r = await _dio.get('/v1/tokens');
    return _asList(
      r.data,
      'tokens',
    ).map((e) => MachineToken.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<String> createToken(String label) async {
    final r = await _dio.post('/v1/tokens', data: {'label': label});
    return (r.data['token'] ?? '').toString();
  }

  Future<void> deleteToken(String id) =>
      _dio.delete('/v1/tokens/${_pathSegment(id)}');

  Future<List<User>> users() async {
    final r = await _dio.get('/v1/users');
    return _asList(
      r.data,
      'users',
    ).map((e) => User.fromJson(e as Map<String, dynamic>)).toList();
  }

  // createUser returns the generated password if the server made one.
  Future<String?> createUser(
    String identity, {
    String? password,
    bool isAdmin = false,
  }) async {
    final r = await _dio.post(
      '/v1/users',
      data: {
        'identity': identity.trim(),
        if (password != null && password.isNotEmpty) 'password': password,
        'is_admin': isAdmin,
      },
    );
    final d = r.data;
    return d is Map ? d['password']?.toString() : null;
  }

  Future<void> setUserAdmin(String identity, bool isAdmin) => _dio.post(
    '/v1/users/${_idSegment(identity)}/admin',
    data: {'is_admin': isAdmin},
  );

  Future<void> setUserDisabled(String identity, bool disabled) => _dio.post(
    '/v1/users/${_idSegment(identity)}/disable',
    data: {'disabled': disabled},
  );

  Future<void> deleteUser(String identity) =>
      _dio.delete('/v1/users/${_idSegment(identity)}');

  Future<String> resetPassword(String identity) async {
    final r = await _dio.post(
      '/v1/users/${_idSegment(identity)}/reset-password',
    );
    return (r.data['password'] ?? '').toString();
  }
}

String _idSegment(String value) => _pathSegment(value.trim());

String _pathSegment(String value) => Uri.encodeComponent(value);

class LoginResult {
  final String token, identity;
  final bool isAdmin;
  LoginResult(this.token, this.identity, this.isAdmin);
}

// AuthException carries a short, user-facing message (its toString IS that
// message) so the login screen can show "该账号已注册" instead of a raw
// DioException dump.
class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

// login posts to /v1/login (which is outside the auth middleware) on a
// tokenless client and returns the session token.
Future<LoginResult> login(String baseUrl, String identity, String password) =>
    _authPost(baseUrl, '/v1/login', identity, password);

// register posts to /v1/register (also outside the auth middleware) to
// self-register a new account, returning a ready-to-use session token just like
// login — so the caller can sign in immediately after registering.
Future<LoginResult> register(
  String baseUrl,
  String identity,
  String password,
) => _authPost(baseUrl, '/v1/register', identity, password);

// _authPost runs the shared login/register request on a tokenless client and
// maps failures to a clean AuthException (server's plain-text body, or a
// friendly message for the common 409/401 and connection errors).
Future<LoginResult> _authPost(
  String baseUrl,
  String path,
  String identity,
  String password,
) async {
  final dio = Dio(BaseOptions(baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), '')));
  final cleanIdentity = identity.trim();
  try {
    final r = await dio.post(
      path,
      data: {'identity': cleanIdentity, 'password': password},
    );
    final d = (r.data as Map).cast<String, dynamic>();
    return LoginResult(
      (d['token'] ?? '').toString(),
      (d['identity'] ?? cleanIdentity).toString(),
      d['is_admin'] == true,
    );
  } on DioException catch (e) {
    throw AuthException(_authErrText(e));
  }
}

String _authErrText(DioException e) {
  final resp = e.response;
  if (resp != null) {
    if (resp.statusCode == 409) return '该账号已注册,请直接登录或换一个 identity';
    if (resp.statusCode == 401) return 'identity 或密码错误';
    final body = resp.data?.toString().trim() ?? '';
    if (body.isNotEmpty) return body;
    return '服务器返回 ${resp.statusCode}';
  }
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
      return '无法连接 relay,请检查地址';
    default:
      return e.message ?? '请求失败';
  }
}

String? _trimOrNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

String? _trimOptional(String? value) => value?.trim();

// _asList tolerates either a bare JSON array or a wrapped object
// ({"items":[...]} / {"comments":[...]}); falls back to the first list value.
List _asList(dynamic data, String key) {
  if (data is List) return data;
  if (data is Map) {
    final v = data[key];
    if (v is List) return v;
    for (final x in data.values) {
      if (x is List) return x;
    }
  }
  return const [];
}

Map<String, dynamic> _asStringMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return const {};
}
