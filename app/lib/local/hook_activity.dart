class HookActivity {
  final DateTime at;
  final String event;
  final String sessionId;
  final String turnId;
  final String cwd;
  final String transcriptPath;
  final String permissionMode;
  final String agentId;
  final String agentType;
  final String agentTranscriptPath;
  final String toolName;
  final String toolUseId;
  final int? exitCode;
  final String source;
  final String trigger;
  final bool stopActive;
  final String model;
  final String prompt;
  final String toolInput;
  final String toolResponse;
  final String lastAssistantMessage;
  final String summary;

  HookActivity({
    required this.at,
    required this.event,
    this.sessionId = '',
    this.turnId = '',
    this.cwd = '',
    this.transcriptPath = '',
    this.permissionMode = '',
    this.agentId = '',
    this.agentType = '',
    this.agentTranscriptPath = '',
    this.toolName = '',
    this.toolUseId = '',
    this.exitCode,
    this.source = '',
    this.trigger = '',
    this.stopActive = false,
    this.model = '',
    this.prompt = '',
    this.toolInput = '',
    this.toolResponse = '',
    this.lastAssistantMessage = '',
    this.summary = '',
  });

  factory HookActivity.fromJson(Map<dynamic, dynamic> m) => HookActivity(
    at: DateTime.tryParse((m['at'] ?? '').toString()) ?? DateTime.now(),
    event: (m['event'] ?? '').toString(),
    sessionId: (m['session_id'] ?? '').toString(),
    turnId: (m['turn_id'] ?? '').toString(),
    cwd: (m['cwd'] ?? '').toString(),
    transcriptPath: (m['transcript_path'] ?? '').toString(),
    permissionMode: (m['permission_mode'] ?? '').toString(),
    agentId: (m['agent_id'] ?? '').toString(),
    agentType: (m['agent_type'] ?? '').toString(),
    agentTranscriptPath: (m['agent_transcript_path'] ?? '').toString(),
    toolName: (m['tool_name'] ?? '').toString(),
    toolUseId: (m['tool_use_id'] ?? '').toString(),
    exitCode: m['exit_code'] is num ? (m['exit_code'] as num).toInt() : null,
    source: (m['source'] ?? '').toString(),
    trigger: (m['trigger'] ?? '').toString(),
    stopActive: m['stop_active'] == true,
    model: (m['model'] ?? '').toString(),
    prompt: (m['prompt'] ?? '').toString(),
    toolInput: (m['tool_input'] ?? '').toString(),
    toolResponse: (m['tool_response'] ?? '').toString(),
    lastAssistantMessage: (m['last_assistant_message'] ?? '').toString(),
    summary: (m['summary'] ?? '').toString(),
  );

  factory HookActivity.fromWire(Map<dynamic, dynamic> m) => HookActivity(
    at: DateTime.tryParse((m['at'] ?? '').toString()) ?? DateTime.now(),
    event: (m['event'] ?? '').toString(),
    sessionId: (m['sessionId'] ?? '').toString(),
    turnId: (m['turnId'] ?? '').toString(),
    cwd: (m['cwd'] ?? '').toString(),
    transcriptPath: (m['transcriptPath'] ?? '').toString(),
    permissionMode: (m['permissionMode'] ?? '').toString(),
    agentId: (m['agentId'] ?? '').toString(),
    agentType: (m['agentType'] ?? '').toString(),
    agentTranscriptPath: (m['agentTranscriptPath'] ?? '').toString(),
    toolName: (m['toolName'] ?? '').toString(),
    toolUseId: (m['toolUseId'] ?? '').toString(),
    exitCode: m['exitCode'] is num ? (m['exitCode'] as num).toInt() : null,
    source: (m['source'] ?? '').toString(),
    trigger: (m['trigger'] ?? '').toString(),
    stopActive: m['stopActive'] == true,
    model: (m['model'] ?? '').toString(),
    prompt: (m['prompt'] ?? '').toString(),
    toolInput: (m['toolInput'] ?? '').toString(),
    toolResponse: (m['toolResponse'] ?? '').toString(),
    lastAssistantMessage: (m['lastAssistantMessage'] ?? '').toString(),
    summary: (m['summary'] ?? '').toString(),
  );

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'event': event,
    'sessionId': sessionId,
    'turnId': turnId,
    'cwd': cwd,
    'transcriptPath': transcriptPath,
    'permissionMode': permissionMode,
    'agentId': agentId,
    'agentType': agentType,
    'agentTranscriptPath': agentTranscriptPath,
    'toolName': toolName,
    'toolUseId': toolUseId,
    'exitCode': exitCode,
    'source': source,
    'trigger': trigger,
    'stopActive': stopActive,
    'model': model,
    'prompt': prompt,
    'toolInput': toolInput,
    'toolResponse': toolResponse,
    'lastAssistantMessage': lastAssistantMessage,
    'summary': summary,
  };

  HookActivity overviewSummary() => HookActivity(
    at: at,
    event: event,
    sessionId: sessionId,
    turnId: turnId,
    cwd: cwd,
    permissionMode: permissionMode,
    agentId: agentId,
    agentType: agentType,
    toolName: toolName,
    toolUseId: toolUseId,
    exitCode: exitCode,
    source: source,
    trigger: trigger,
    stopActive: stopActive,
    model: model,
    prompt: _clip(prompt, 180),
    toolInput: _clip(toolInput, 180),
    toolResponse: _clip(toolResponse, 180),
    lastAssistantMessage: _clip(lastAssistantMessage, 180),
    summary: _clip(summary, 180),
  );

  String get title {
    if (toolName.isNotEmpty) {
      final code = exitCode == null ? '' : ' · exit $exitCode';
      return '$event · $toolName$code';
    }
    if (source.isNotEmpty) return '$event · $source';
    if (trigger.isNotEmpty) return '$event · $trigger';
    if (agentType.isNotEmpty) return '$event · $agentType';
    return event;
  }

  String get detail {
    for (final s in [
      prompt,
      toolInput,
      toolResponse,
      lastAssistantMessage,
      summary,
      permissionMode,
      model,
      cwd,
    ]) {
      final t = s.trim();
      if (t.isNotEmpty) return t;
    }
    return '';
  }
}

String _clip(String s, int max) {
  final t = s.trim();
  return t.length <= max ? t : '${t.substring(0, max)}...';
}
