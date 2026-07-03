import 'dart:io';

import 'package:toml/toml.dart';

// One [[partner_mapping.rule]] entry (suggestEdit is a comma-separated list in
// the form).
class RuleCfg {
  String whenPathMatches;
  String suggestEdit;
  bool suggestCreate;
  RuleCfg(
      {this.whenPathMatches = '',
      this.suggestEdit = '',
      this.suggestCreate = false});
}

// RepoConfig is the editable view of a repo's `.cc-handoff.toml`. Read with
// load(); write with save() — both pure Dart via the toml package (the repo
// config has no secrets and isn't shared, so we read/write it directly). List
// fields (partners / suggest_edit / labels / types) are comma-separated in the
// form and split on save.
//
// This mirrors Go's `internal/config/config.go` Repo struct — keep the fields in
// sync: a field added to the Go struct won't surface here until added below
// (unknown keys are preserved via `raw`, just not editable).
class RepoConfig {
  // [identity]
  String me, partner, partners;
  // [paths]
  String swagger, base, repo;
  // [[partner_mapping.rule]]
  List<RuleCfg> rules;
  // [triggers]
  bool autoLaunch,
      autoLaunchNormal,
      wakeOnComment,
      muteUserPresence,
      launchInteractive,
      autoLaunchOnAlert;
  String terminalApp, launchMode, ackOnLaunch, preLaunch;
  // [inbox]
  String inboxDir;
  // [integrations.linear]
  bool linearEnabled, syncOnSubmit, syncOnPickup, syncOnComment, syncOnRetract;
  String teamKey, linearProjectId, defaultLabels, mcpPrefix, pollInterval, types;

  // the raw parsed map, kept so save() preserves any unknown top-level keys.
  final Map<String, dynamic> raw;

  RepoConfig({
    required this.raw,
    this.me = '',
    this.partner = '',
    this.partners = '',
    this.swagger = '',
    this.base = '',
    this.repo = '',
    this.rules = const [],
    this.autoLaunch = false,
    this.autoLaunchNormal = false,
    this.wakeOnComment = false,
    this.muteUserPresence = false,
    this.launchInteractive = false,
    this.autoLaunchOnAlert = false,
    this.terminalApp = '',
    this.launchMode = '',
    this.ackOnLaunch = '',
    this.preLaunch = '',
    this.inboxDir = '',
    this.linearEnabled = false,
    this.syncOnSubmit = false,
    this.syncOnPickup = false,
    this.syncOnComment = false,
    this.syncOnRetract = false,
    this.teamKey = '',
    this.linearProjectId = '',
    this.defaultLabels = '',
    this.mcpPrefix = '',
    this.pollInterval = '',
    this.types = '',
  });

  static String pathFor(String projectPath) => '$projectPath/.cc-handoff.toml';

  static Future<RepoConfig> load(String projectPath) async {
    Map<String, dynamic> m = {};
    try {
      final f = File(pathFor(projectPath));
      if (await f.exists()) {
        final parsed = TomlDocument.parse(await f.readAsString()).toMap();
        m = Map<String, dynamic>.from(parsed);
      }
    } catch (_) {}

    Map sec(Map? parent, String key) => (parent?[key] as Map?) ?? const {};
    final id = sec(m, 'identity');
    final paths = sec(m, 'paths');
    final pm = sec(m, 'partner_mapping');
    final tr = sec(m, 'triggers');
    final inbox = sec(m, 'inbox');
    final lin = sec(sec(m, 'integrations'), 'linear');
    final notif = sec(lin, 'notifications');

    final rules = ((pm['rule'] as List?) ?? const [])
        .whereType<Map>()
        .map((r) => RuleCfg(
              whenPathMatches: _s(r['when_path_matches']),
              suggestEdit: _list(r['suggest_edit']),
              suggestCreate: r['suggest_create_if_missing'] == true,
            ))
        .toList();

    return RepoConfig(
      raw: m,
      me: _s(id['me']),
      partner: _s(id['partner']),
      partners: _list(id['partners']),
      swagger: _s(paths['swagger']),
      base: _s(paths['base']),
      repo: _s(paths['repo']),
      rules: rules,
      autoLaunch: tr['auto_launch'] == true,
      autoLaunchNormal: tr['auto_launch_normal'] == true,
      wakeOnComment: tr['wake_on_comment'] == true,
      muteUserPresence: tr['mute_user_presence'] == true,
      launchInteractive: tr['launch_interactive'] == true,
      autoLaunchOnAlert: tr['auto_launch_on_alert'] == true,
      terminalApp: _s(tr['terminal_app']),
      launchMode: _s(tr['launch_mode']),
      ackOnLaunch: _s(tr['ack_on_launch']),
      preLaunch: _s(tr['pre_launch']),
      inboxDir: _s(inbox['dir']),
      linearEnabled: lin['enabled'] == true,
      teamKey: _s(lin['team_key']),
      linearProjectId: _s(lin['project_id']),
      defaultLabels: _list(lin['default_labels']),
      mcpPrefix: _s(lin['mcp_prefix']),
      syncOnSubmit: lin['sync_on_submit'] == true,
      syncOnPickup: lin['sync_on_pickup'] == true,
      syncOnComment: lin['sync_on_comment'] == true,
      syncOnRetract: lin['sync_on_retract'] == true,
      pollInterval: _s(notif['poll_interval']),
      types: _list(notif['types']),
    );
  }

  Future<void> save(String projectPath) async {
    final m = Map<String, dynamic>.from(raw);

    final id = <String, dynamic>{};
    _putStr(id, 'me', me);
    _putStr(id, 'partner', partner);
    _putList(id, 'partners', partners);
    _section(m, 'identity', id);

    final p = <String, dynamic>{};
    _putStr(p, 'swagger', swagger);
    _putStr(p, 'base', base);
    _putStr(p, 'repo', repo);
    _section(m, 'paths', p);

    final ruleList = rules
        .where((r) => r.whenPathMatches.trim().isNotEmpty)
        .map((r) {
      final rm = <String, dynamic>{
        'when_path_matches': r.whenPathMatches.trim()
      };
      _putList(rm, 'suggest_edit', r.suggestEdit);
      if (r.suggestCreate) rm['suggest_create_if_missing'] = true;
      return rm;
    }).toList();
    if (ruleList.isNotEmpty) {
      m['partner_mapping'] = {'rule': ruleList};
    } else {
      m.remove('partner_mapping');
    }

    // auto_launch has no omitempty in Go — always write it; the rest omit.
    final tr = <String, dynamic>{'auto_launch': autoLaunch};
    _putBool(tr, 'auto_launch_normal', autoLaunchNormal);
    _putBool(tr, 'wake_on_comment', wakeOnComment);
    _putBool(tr, 'mute_user_presence', muteUserPresence);
    _putBool(tr, 'launch_interactive', launchInteractive);
    _putBool(tr, 'auto_launch_on_alert', autoLaunchOnAlert);
    _putStr(tr, 'terminal_app', terminalApp);
    _putStr(tr, 'launch_mode', launchMode);
    _putStr(tr, 'ack_on_launch', ackOnLaunch);
    _putStr(tr, 'pre_launch', preLaunch);
    m['triggers'] = tr;

    if (inboxDir.isNotEmpty) {
      m['inbox'] = {'dir': inboxDir};
    } else {
      m.remove('inbox');
    }

    final lin = <String, dynamic>{};
    _putBool(lin, 'enabled', linearEnabled);
    _putStr(lin, 'team_key', teamKey);
    _putStr(lin, 'project_id', linearProjectId);
    _putList(lin, 'default_labels', defaultLabels);
    _putStr(lin, 'mcp_prefix', mcpPrefix);
    _putBool(lin, 'sync_on_submit', syncOnSubmit);
    _putBool(lin, 'sync_on_pickup', syncOnPickup);
    _putBool(lin, 'sync_on_comment', syncOnComment);
    _putBool(lin, 'sync_on_retract', syncOnRetract);
    final notif = <String, dynamic>{};
    _putStr(notif, 'poll_interval', pollInterval);
    _putList(notif, 'types', types);
    if (notif.isNotEmpty) lin['notifications'] = notif;
    final integrations =
        Map<String, dynamic>.from((m['integrations'] as Map?) ?? const {});
    if (lin.isNotEmpty) {
      integrations['linear'] = lin;
    } else {
      integrations.remove('linear');
    }
    if (integrations.isNotEmpty) {
      m['integrations'] = integrations;
    } else {
      m.remove('integrations');
    }

    final out = TomlDocument.fromMap(m).toString();
    await File(pathFor(projectPath)).writeAsString(out);
  }
}

void _section(Map<String, dynamic> m, String key, Map<String, dynamic> sec) {
  if (sec.isEmpty) {
    m.remove(key);
  } else {
    m[key] = sec;
  }
}

// _putStr/_putBool/_putList apply Go's omitempty: only write non-default values.
void _putStr(Map<String, dynamic> m, String k, String v) {
  if (v.isNotEmpty) m[k] = v;
}

void _putBool(Map<String, dynamic> m, String k, bool v) {
  if (v) m[k] = true;
}

void _putList(Map<String, dynamic> m, String k, String csv) {
  final l = _split(csv);
  if (l.isNotEmpty) m[k] = l;
}

String _s(dynamic v) => (v ?? '').toString();
String _list(dynamic v) =>
    v is List ? v.map((e) => e.toString()).join(', ') : '';
List<String> _split(String s) =>
    s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
