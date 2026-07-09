import 'dart:async';
import 'dart:io';

import 'package:app/api/github_client.dart';
import 'package:app/screens/github_pr_page.dart';
import 'package:app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('GitHub PR app bar title is width constrained', () {
    final source = File('lib/screens/github_pr_page.dart').readAsStringSync();

    expect(
      source,
      isNot(contains("title: Text('GitHub PR · \${widget.name}')")),
    );
    expect(
      source,
      contains("'GitHub PR · \${widget.name}',\n          maxLines: 1"),
    );
    expect(source, contains('overflow: TextOverflow.ellipsis'));
  });

  testWidgets('stale GitHub PR load cannot overwrite a newer repo', (
    tester,
  ) async {
    final loader = _DelayedPullLoader();

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: GitHubPrPage(
          githubUrl: 'https://github.com/acme/first',
          name: 'first',
          loadToken: () async => 'tok',
          listPulls: loader.list,
        ),
      ),
    );
    await tester.pump();
    expect(loader.requestedSlugs, ['acme/first']);

    await tester.pumpWidget(
      MaterialApp(
        theme: ccTheme(),
        home: GitHubPrPage(
          githubUrl: 'https://github.com/acme/second',
          name: 'second',
          loadToken: () async => 'tok',
          listPulls: loader.list,
        ),
      ),
    );
    await tester.pump();
    expect(loader.requestedSlugs, ['acme/first', 'acme/second']);

    loader.complete('acme/second', [_pr(2, 'second repo PR')]);
    await tester.pumpAndSettle();
    expect(find.text('second repo PR'), findsOneWidget);
    expect(find.text('first repo PR'), findsNothing);

    loader.complete('acme/first', [_pr(1, 'first repo PR')]);
    await tester.pumpAndSettle();
    expect(find.text('second repo PR'), findsOneWidget);
    expect(find.text('first repo PR'), findsNothing);
  });
}

PullRequest _pr(int number, String title) =>
    PullRequest(number, title, 'dev', 'feature', 'main', 'open', false);

class _DelayedPullLoader {
  final requestedSlugs = <String>[];
  final _requests = <String, Completer<List<PullRequest>>>{};

  Future<List<PullRequest>> list(String slug) {
    requestedSlugs.add(slug);
    final completer = Completer<List<PullRequest>>();
    _requests[slug] = completer;
    return completer.future;
  }

  void complete(String slug, List<PullRequest> pulls) {
    _requests[slug]!.complete(pulls);
  }
}
