class CliException implements Exception {
  final String message;
  CliException(this.message);
  @override
  String toString() => message;
}

class Cli {
  static Future<String> todoImportLinear({
    required String teamKey,
    String? linearProjectId,
    String? projectId,
    String? workingDirectory,
  }) async {
    throw CliException('当前平台不支持本机 CLI 操作');
  }

  static Future<void> configSet({
    String? relayUrl,
    String? token,
    String? identity,
    String? agent,
    String? workspaceRoot,
    String? gradeCommand,
    String? linearToken,
    String? githubToken,
    String? terminalApp,
    bool? publishSessions,
    String? claudeCommand,
    String? codexCommand,
  }) async {
    throw CliException('当前平台不支持本机 CLI 操作');
  }
}
