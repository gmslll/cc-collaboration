import 'package:dio/dio.dart';

import 'models.dart';

// RelayClient is a thin HTTP client over the relay's /v1 API (Bearer auth).
// Shared data only — local ops (pickup/worktree/terminal) go through the
// cc-handoff CLI + the PTY, not here.
class RelayClient {
  final Dio _dio;

  RelayClient(String baseUrl, String token)
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
          headers: {'Authorization': 'Bearer $token'},
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
        ));

  Future<List<ListItem>> handoffs({String as = 'recipient'}) async {
    final r = await _dio.get('/v1/handoffs', queryParameters: {'as': as});
    return _asList(r.data, 'items')
        .map((e) => ListItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Package> get(String id) async {
    final r = await _dio.get('/v1/handoffs/$id');
    return Package.fromJson(r.data as Map<String, dynamic>);
  }

  Future<Status> status(String id) async {
    final r = await _dio.get('/v1/handoffs/$id/status');
    return Status.fromJson(r.data as Map<String, dynamic>);
  }

  // prompt returns the server pre-rendered full pickup prompt (markdown text).
  Future<String> prompt(String id) async {
    final r = await _dio.get('/v1/handoffs/$id/prompt',
        options: Options(responseType: ResponseType.plain));
    return r.data?.toString() ?? '';
  }

  Future<List<int>> attachment(String id, String name) async {
    final r = await _dio.get(
        '/v1/handoffs/$id/attachments/${Uri.encodeComponent(name)}',
        options: Options(responseType: ResponseType.bytes));
    return (r.data as List).cast<int>();
  }

  Future<List<Comment>> comments(String id) async {
    final r = await _dio.get('/v1/handoffs/$id/comments');
    return _asList(r.data, 'comments')
        .map((e) => Comment.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Comment> postComment(String id, String body) async {
    final r = await _dio.post('/v1/handoffs/$id/comment', data: {'body': body});
    return Comment.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> ack(String id) => _dio.post('/v1/handoffs/$id/ack');

  Future<void> retract(String id, String reason) =>
      _dio.post('/v1/handoffs/$id/retract', data: {'reason': reason});

  Future<void> reassign(String id, String to, String reason) =>
      _dio.post('/v1/handoffs/$id/reassign', data: {'to': to, 'reason': reason});

  // --- multi-tenant (F3) ---

  Future<Me> me() async {
    final r = await _dio.get('/v1/me');
    return Me.fromJson(r.data as Map<String, dynamic>);
  }

  Future<List<OnlineUser>> onlineUsers() async {
    final r = await _dio.get('/v1/users/online');
    return _asList(r.data, 'users')
        .map((e) => OnlineUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Project>> projects() async {
    final r = await _dio.get('/v1/projects');
    return _asList(r.data, 'projects')
        .map((e) => Project.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Project> createProject(String name) async {
    final r = await _dio.post('/v1/projects', data: {'name': name});
    return Project.fromJson(r.data as Map<String, dynamic>);
  }

  Future<ProjectDetail> project(String id) async {
    final r = await _dio.get('/v1/projects/$id');
    return ProjectDetail.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> renameProject(String id, String name) =>
      _dio.patch('/v1/projects/$id', data: {'name': name});

  Future<void> deleteProject(String id) => _dio.delete('/v1/projects/$id');

  Future<void> mapRepo(String id, String repoName) =>
      _dio.post('/v1/projects/$id/repos', data: {'repo_name': repoName});

  Future<void> unmapRepo(String id, String repoName) => _dio.delete(
      '/v1/projects/$id/repos',
      queryParameters: {'repo_name': repoName});

  Future<void> addMember(String id, String identity, String role) => _dio.post(
      '/v1/projects/$id/members',
      data: {'identity': identity, 'role': role});

  Future<void> removeMember(String id, String identity) => _dio
      .delete('/v1/projects/$id/members/${Uri.encodeComponent(identity)}');

  Future<void> changePassword(String oldPw, String newPw) =>
      _dio.post('/v1/password', data: {'old': oldPw, 'new': newPw});

  Future<List<MachineToken>> tokens() async {
    final r = await _dio.get('/v1/tokens');
    return _asList(r.data, 'tokens')
        .map((e) => MachineToken.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<String> createToken(String label) async {
    final r = await _dio.post('/v1/tokens', data: {'label': label});
    return (r.data['token'] ?? '').toString();
  }

  Future<void> deleteToken(String id) => _dio.delete('/v1/tokens/$id');

  Future<List<User>> users() async {
    final r = await _dio.get('/v1/users');
    return _asList(r.data, 'users')
        .map((e) => User.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // createUser returns the generated password if the server made one.
  Future<String?> createUser(String identity,
      {String? password, bool isAdmin = false}) async {
    final r = await _dio.post('/v1/users', data: {
      'identity': identity,
      if (password != null && password.isNotEmpty) 'password': password,
      'is_admin': isAdmin,
    });
    final d = r.data;
    return d is Map ? d['password']?.toString() : null;
  }

  Future<void> setUserAdmin(String identity, bool isAdmin) => _dio.post(
      '/v1/users/${Uri.encodeComponent(identity)}/admin',
      data: {'is_admin': isAdmin});

  Future<void> setUserDisabled(String identity, bool disabled) => _dio.post(
      '/v1/users/${Uri.encodeComponent(identity)}/disable',
      data: {'disabled': disabled});

  Future<String> resetPassword(String identity) async {
    final r = await _dio
        .post('/v1/users/${Uri.encodeComponent(identity)}/reset-password');
    return (r.data['password'] ?? '').toString();
  }
}

class LoginResult {
  final String token, identity;
  final bool isAdmin;
  LoginResult(this.token, this.identity, this.isAdmin);
}

// login posts to /v1/login (which is outside the auth middleware) on a
// tokenless client and returns the session token.
Future<LoginResult> login(String baseUrl, String identity, String password) async {
  final dio = Dio(BaseOptions(baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), '')));
  final r =
      await dio.post('/v1/login', data: {'identity': identity, 'password': password});
  final d = (r.data as Map).cast<String, dynamic>();
  return LoginResult((d['token'] ?? '').toString(),
      (d['identity'] ?? identity).toString(), d['is_admin'] == true);
}

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
