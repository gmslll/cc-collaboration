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
  String teamKey, defaultLabels, mcpPrefix, pollInterval, types;

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
    if (me.isNotEmpty) id['me'] = me;
    if (partner.isNotEmpty) id['partner'] = partner;
    final partnersList = _split(partners);
    if (partnersList.isNotEmpty) id['partners'] = partnersList;
    _section(m, 'identity', id);

    final p = <String, dynamic>{};
    if (swagger.isNotEmpty) p['swagger'] = swagger;
    if (base.isNotEmpty) p['base'] = base;
    if (repo.isNotEmpty) p['repo'] = repo;
    _section(m, 'paths', p);

    final ruleList = rules
        .where((r) => r.whenPathMatches.trim().isNotEmpty)
        .map((r) {
      final rm = <String, dynamic>{
        'when_path_matches': r.whenPathMatches.trim()
      };
      final se = _split(r.suggestEdit);
      if (se.isNotEmpty) rm['suggest_edit'] = se;
      if (r.suggestCreate) rm['suggest_create_if_missing'] = true;
      return rm;
    }).toList();
    if (ruleList.isNotEmpty) {
      m['partner_mapping'] = {'rule': ruleList};
    } else {
      m.remove('partner_mapping');
    }

    final tr = <String, dynamic>{'auto_launch': autoLaunch};
    if (autoLaunchNormal) tr['auto_launch_normal'] = true;
    if (wakeOnComment) tr['wake_on_comment'] = true;
    if (muteUserPresence) tr['mute_user_presence'] = true;
    if (launchInteractive) tr['launch_interactive'] = true;
    if (autoLaunchOnAlert) tr['auto_launch_on_alert'] = true;
    if (terminalApp.isNotEmpty) tr['terminal_app'] = terminalApp;
    if (launchMode.isNotEmpty) tr['launch_mode'] = launchMode;
    if (ackOnLaunch.isNotEmpty) tr['ack_on_launch'] = ackOnLaunch;
    if (preLaunch.isNotEmpty) tr['pre_launch'] = preLaunch;
    m['triggers'] = tr;

    if (inboxDir.isNotEmpty) {
      m['inbox'] = {'dir': inboxDir};
    } else {
      m.remove('inbox');
    }

    final lin = <String, dynamic>{};
    if (linearEnabled) lin['enabled'] = true;
    if (teamKey.isNotEmpty) lin['team_key'] = teamKey;
    final labels = _split(defaultLabels);
    if (labels.isNotEmpty) lin['default_labels'] = labels;
    if (mcpPrefix.isNotEmpty) lin['mcp_prefix'] = mcpPrefix;
    if (syncOnSubmit) lin['sync_on_submit'] = true;
    if (syncOnPickup) lin['sync_on_pickup'] = true;
    if (syncOnComment) lin['sync_on_comment'] = true;
    if (syncOnRetract) lin['sync_on_retract'] = true;
    final notif = <String, dynamic>{};
    if (pollInterval.isNotEmpty) notif['poll_interval'] = pollInterval;
    final typesList = _split(types);
    if (typesList.isNotEmpty) notif['types'] = typesList;
    if (notif.isNotEmpty) lin['notifications'] = notif;
    if (lin.isNotEmpty) {
      m['integrations'] = {'linear': lin};
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

String _s(dynamic v) => (v ?? '').toString();
String _list(dynamic v) =>
    v is List ? v.map((e) => e.toString()).join(', ') : '';
List<String> _split(String s) =>
    s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
