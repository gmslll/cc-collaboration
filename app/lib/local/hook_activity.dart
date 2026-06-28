class HookActivity {
  final DateTime at;
  final String event;
  final String toolName;
  final int? exitCode;
  final String source;
  final String model;
  final String prompt;
  final String toolInput;
  final String toolResponse;
  final String lastAssistantMessage;

  HookActivity({
    required this.at,
    required this.event,
    this.toolName = '',
    this.exitCode,
    this.source = '',
    this.model = '',
    this.prompt = '',
    this.toolInput = '',
    this.toolResponse = '',
    this.lastAssistantMessage = '',
  });

  factory HookActivity.fromJson(Map<dynamic, dynamic> m) => HookActivity(
    at: DateTime.tryParse((m['at'] ?? '').toString()) ?? DateTime.now(),
    event: (m['event'] ?? '').toString(),
    toolName: (m['tool_name'] ?? '').toString(),
    exitCode: m['exit_code'] is num ? (m['exit_code'] as num).toInt() : null,
    source: (m['source'] ?? '').toString(),
    model: (m['model'] ?? '').toString(),
    prompt: (m['prompt'] ?? '').toString(),
    toolInput: (m['tool_input'] ?? '').toString(),
    toolResponse: (m['tool_response'] ?? '').toString(),
    lastAssistantMessage: (m['last_assistant_message'] ?? '').toString(),
  );

  factory HookActivity.fromWire(Map<dynamic, dynamic> m) => HookActivity(
    at: DateTime.tryParse((m['at'] ?? '').toString()) ?? DateTime.now(),
    event: (m['event'] ?? '').toString(),
    toolName: (m['toolName'] ?? '').toString(),
    exitCode: m['exitCode'] is num ? (m['exitCode'] as num).toInt() : null,
    source: (m['source'] ?? '').toString(),
    model: (m['model'] ?? '').toString(),
    prompt: (m['prompt'] ?? '').toString(),
    toolInput: (m['toolInput'] ?? '').toString(),
    toolResponse: (m['toolResponse'] ?? '').toString(),
    lastAssistantMessage: (m['lastAssistantMessage'] ?? '').toString(),
  );

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'event': event,
    'toolName': toolName,
    'exitCode': exitCode,
    'source': source,
    'model': model,
    'prompt': prompt,
    'toolInput': toolInput,
    'toolResponse': toolResponse,
    'lastAssistantMessage': lastAssistantMessage,
  };

  String get title {
    if (toolName.isNotEmpty) {
      final code = exitCode == null ? '' : ' · exit $exitCode';
      return '$event · $toolName$code';
    }
    if (source.isNotEmpty) return '$event · $source';
    return event;
  }

  String get detail {
    for (final s in [prompt, toolInput, toolResponse, lastAssistantMessage]) {
      final t = s.trim();
      if (t.isNotEmpty) return t;
    }
    return model;
  }
}
