import 'dart:io';

import 'package:app/screens/repo_config_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('repo config dropdown menus are capped for compact screens', () {
    expect(repoConfigMenuMaxHeight(const Size(1024, 900)), 320);
    expect(
      repoConfigMenuMaxHeight(const Size(320, 420)),
      closeTo(243.6, 0.001),
    );
    expect(repoConfigMenuMaxHeight(const Size(320, 220)), 160);
    expect(repoConfigMenuMaxHeight(Size.zero), 320);
  });

  test('repo config dropdown width leaves room for labels', () {
    expect(repoConfigDropdownWidth(const BoxConstraints(maxWidth: 480)), 180);
    expect(
      repoConfigDropdownWidth(const BoxConstraints(maxWidth: 260)),
      closeTo(124.8, 0.001),
    );
    expect(repoConfigDropdownWidth(const BoxConstraints(maxWidth: 180)), 120);
    expect(repoConfigDropdownWidth(const BoxConstraints(maxWidth: 90)), 90);
  });

  test('repo config page constrains long title and dropdown labels', () {
    final source = File('lib/screens/repo_config_page.dart').readAsStringSync();
    final dropdown = source.substring(
      source.indexOf('Widget _dropdown('),
      source.indexOf('Widget _triggersCard('),
    );

    expect(source, contains("'项目配置 · \${widget.projectName}'"));
    expect(source, contains('maxLines: 1'));
    expect(source, contains('overflow: TextOverflow.ellipsis'));
    expect(dropdown, contains('repoConfigDropdownWidth(constraints)'));
    expect(dropdown, contains('isExpanded: true'));
    expect(dropdown, contains('menuMaxHeight: repoConfigMenuMaxHeight'));
    expect(dropdown, isNot(contains("child: Text(o.isEmpty ? '(默认)' : o)")));
  });
}
