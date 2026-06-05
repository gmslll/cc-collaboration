import 'package:dio/dio.dart';

class GitHubException implements Exception {
  final String message;
  GitHubException(this.message);
  @override
  String toString() => message;
}

// A pull-request summary (list view).
class PullRequest {
  final int number;
  final String title;
  final String author;
  final String headRef;
  final String baseRef;
  final String state;
  final bool draft;
  PullRequest(this.number, this.title, this.author, this.headRef, this.baseRef,
      this.state, this.draft);

  factory PullRequest.fromJson(Map j) => PullRequest(
        (j['number'] as num?)?.toInt() ?? 0,
        (j['title'] ?? '').toString(),
        ((j['user'] as Map?)?['login'] ?? '').toString(),
        ((j['head'] as Map?)?['ref'] ?? '').toString(),
        ((j['base'] as Map?)?['ref'] ?? '').toString(),
        (j['state'] ?? '').toString(),
        j['draft'] == true,
      );
}

// One file's change in a PR. [patch] is the unified-diff hunk (empty for binary
// / very large files, which GitHub omits).
class PrFile {
  final String filename;
  final String status; // added / modified / removed / renamed
  final int additions;
  final int deletions;
  final String patch;
  PrFile(this.filename, this.status, this.additions, this.deletions, this.patch);

  factory PrFile.fromJson(Map j) => PrFile(
        (j['filename'] ?? '').toString(),
        (j['status'] ?? '').toString(),
        (j['additions'] as num?)?.toInt() ?? 0,
        (j['deletions'] as num?)?.toInt() ?? 0,
        (j['patch'] ?? '').toString(),
      );
}

// GitHubClient is a thin read-only REST client (list PRs + their changed files)
// authenticated with a personal access token from config.toml github_token.
class GitHubClient {
  final Dio _dio;
  GitHubClient(String token)
      : _dio = Dio(BaseOptions(
          baseUrl: 'https://api.github.com',
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        ));

  // parseSlug extracts "owner/repo" from a github URL (https or git@ form);
  // null if it isn't a github.com URL.
  static String? parseSlug(String url) {
    var s = url.trim();
    if (s.isEmpty) return null;
    s = s.replaceFirst(RegExp(r'\.git/?$'), '');
    final ssh = RegExp(r'git@github\.com:(.+)$').firstMatch(s);
    if (ssh != null) return _slug(ssh.group(1)!);
    final i = s.indexOf('github.com/');
    if (i >= 0) return _slug(s.substring(i + 'github.com/'.length));
    return null;
  }

  static String? _slug(String s) {
    final parts = s.split('/').where((p) => p.isNotEmpty).toList();
    return parts.length < 2 ? null : '${parts[0]}/${parts[1]}';
  }

  Future<List<PullRequest>> listPulls(String slug,
      {String state = 'open'}) async {
    try {
      final r = await _dio.get('/repos/$slug/pulls', queryParameters: {
        'state': state,
        'per_page': 50,
        'sort': 'updated',
        'direction': 'desc',
      });
      return (r.data as List)
          .whereType<Map>()
          .map(PullRequest.fromJson)
          .toList();
    } on DioException catch (e) {
      throw GitHubException(_err(e));
    }
  }

  Future<List<PrFile>> pullFiles(String slug, int number) async {
    try {
      final r = await _dio.get('/repos/$slug/pulls/$number/files',
          queryParameters: {'per_page': 100});
      return (r.data as List).whereType<Map>().map(PrFile.fromJson).toList();
    } on DioException catch (e) {
      throw GitHubException(_err(e));
    }
  }

  String _err(DioException e) {
    final code = e.response?.statusCode;
    if (code == 401) return 'GitHub token 无效或过期(401)';
    if (code == 403) return 'GitHub 限流或无权限(403)';
    if (code == 404) return '仓库 / PR 不存在或 token 无权访问(404)';
    final data = e.response?.data;
    final msg = data is Map ? (data['message'] ?? '').toString() : '';
    return msg.isNotEmpty ? 'GitHub: $msg' : 'GitHub 请求失败(检查网络 / token)';
  }
}
