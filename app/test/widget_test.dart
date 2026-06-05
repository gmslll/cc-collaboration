import 'dart:io';

import 'package:app/api/models.dart';
import 'package:app/local/repo_config.dart';
import 'package:app/widgets.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ListItem.fromJson parses fields + defaults kind', () {
    final it = ListItem.fromJson({
      'id': 'h1',
      'sender': 'a@x',
      'urgency': 'urgent',
      'state': 'pending',
      'repo_name': 'repo',
      'headline': 'hi',
      'created_at': '2026-01-01T00:00:00Z',
    });
    expect(it.id, 'h1');
    expect(it.sender, 'a@x');
    expect(it.urgency, 'urgent');
    expect(it.kind, 'delivery'); // omitted → default
    expect(it.repoName, 'repo');
  });

  test('Package.fromJson parses nested api_delta / git / attachments', () {
    final p = Package.fromJson({
      'id': 'h1',
      'sender': 'a',
      'recipient': 'b',
      'summary_md': '# hi',
      'repo': {'name': 'r', 'branch': 'main'},
      'module_paths': ['a/b'],
      'attachments': [
        {'name': 'f.txt', 'size': 12, 'sha256': 'x'}
      ],
      'git': {
        'commits': [
          {'sha': 'abc', 'subject': 's'}
        ],
        'changed_paths': ['x.go']
      },
      'api_delta': {
        'added': [
          {'method': 'GET', 'path': '/v1/x', 'summary': 'sum'}
        ]
      },
    });
    expect(p.repo.name, 'r');
    expect(p.modulePaths, ['a/b']);
    expect(p.attachments.single.name, 'f.txt');
    expect(p.attachments.single.size, 12);
    expect(p.git!.commits.single.sha, 'abc');
    expect(p.git!.changedPaths, ['x.go']);
    expect(p.apiDelta!.added.single.method, 'GET');
    expect(p.apiDelta!.isEmpty, isFalse);
  });

  test('Me.fromJson + ProjectRole', () {
    final me = Me.fromJson({
      'identity': 'a',
      'is_admin': true,
      'projects': [
        {'id': 'p1', 'name': 'P', 'role': 'owner'}
      ]
    });
    expect(me.isAdmin, isTrue);
    expect(me.projects.single.role, 'owner');
  });

  test('Status.fromJson handles null picked_at', () {
    final s = Status.fromJson({
      'state': 'pending',
      'comment_count': 3,
      'created_at': '2026-01-01T00:00:00Z',
    });
    expect(s.state, 'pending');
    expect(s.pickedAt, isNull);
    expect(s.commentCount, 3);
  });

  test('errorText maps DioException to friendly text', () {
    final timeout = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionTimeout);
    expect(errorText(timeout), contains('超时'));

    final forbidden = DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.badResponse,
      response: Response(requestOptions: RequestOptions(path: '/'), statusCode: 403),
    );
    expect(errorText(forbidden), contains('权限'));

    expect(errorText('boom'), 'boom');
  });

  test('RepoConfig save→load round-trips (.cc-handoff.toml)', () async {
    final dir = await Directory.systemTemp.createTemp('repocfg');
    try {
      final c = RepoConfig(
        raw: const {},
        partner: 'alex@frontend',
        partners: 'a@x, b@y',
        base: 'origin/main',
        autoLaunch: true,
        terminalApp: 'iterm2',
        linearEnabled: true,
        teamKey: 'ENG',
        types: 'mention',
        rules: [
          RuleCfg(
              whenPathMatches: '^x/', suggestEdit: 'a.ts, b.ts', suggestCreate: true)
        ],
      );
      await c.save(dir.path);
      final back = await RepoConfig.load(dir.path);
      expect(back.partner, 'alex@frontend');
      expect(back.partners, 'a@x, b@y');
      expect(back.base, 'origin/main');
      expect(back.autoLaunch, isTrue);
      expect(back.terminalApp, 'iterm2');
      expect(back.linearEnabled, isTrue);
      expect(back.teamKey, 'ENG');
      expect(back.types, 'mention');
      expect(back.rules.length, 1);
      expect(back.rules.first.whenPathMatches, '^x/');
      expect(back.rules.first.suggestCreate, isTrue);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
