import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../build_info.dart';
import '../theme.dart';
import '../widgets.dart';

// In-app updater: the apps ship via GitHub Releases (no app store), so this
// checks the public latest release, compares it to the build's kAppVersion, and
// — when newer — downloads the platform asset and hands it to the OS installer
// (Android) or replaces the desktop app bundle. Public repo → no token needed.
const String _repo = 'gmslll/cc-collaboration';

class UpdateInfo {
  final String version; // "0.4.1" (tag without the leading v)
  final String? assetUrl; // platform download asset, null if none for this OS
  final String assetName;
  final String releaseUrl; // release html page (fallback when no asset)
  const UpdateInfo({
    required this.version,
    required this.assetUrl,
    required this.assetName,
    required this.releaseUrl,
  });
}

class UpdateCheck {
  final UpdateInfo? update;
  final String? error;
  const UpdateCheck.update(this.update) : error = null;
  const UpdateCheck.error(this.error) : update = null;
}

// _cmpVer compares dotted numeric versions ("0.4.10" > "0.4.2"); pre-release
// suffixes on a part are ignored (split on '-').
int _cmpVer(String a, String b) {
  final pa = a.split('.'), pb = b.split('.');
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? int.tryParse(pa[i].split('-').first) ?? 0 : 0;
    final y = i < pb.length ? int.tryParse(pb[i].split('-').first) ?? 0 : 0;
    if (x != y) return x - y;
  }
  return 0;
}

bool _isNewer(String latest, String current) =>
    current != 'dev' && current.isNotEmpty && _cmpVer(latest, current) > 0;

String _versionFromTag(String tag) => tag.startsWith('v') ? tag.substring(1) : tag;

// _assetMatches picks this platform's GUI app release asset by the names
// scripts/package.* produce. Be strict on Windows: release.yml also uploads CLI
// archives named cc-handoff_v*_windows_*.zip, which are NOT app updates.
bool _assetMatches(String name, String version) {
  final n = name.toLowerCase();
  if (Platform.isAndroid) return n == 'cc-handoff-android-v$version.apk';
  if (Platform.isMacOS) return n == 'app-macos-v$version.zip';
  if (Platform.isWindows) {
    return n == 'cc-handoff-windows-${_windowsPackageArch()}-v$version.zip';
  }
  return false;
}

String _windowsPackageArch() {
  final arch = [
    Platform.environment['PROCESSOR_ARCHITECTURE'],
    Platform.environment['PROCESSOR_ARCHITEW6432'],
  ].whereType<String>().join(' ').toLowerCase();
  return arch.contains('arm64') || arch.contains('aarch64') ? 'arm64' : 'amd64';
}

String? _fallbackAssetName(String version) {
  if (Platform.isAndroid) return 'cc-handoff-android-v$version.apk';
  if (Platform.isMacOS) return 'app-macos-v$version.zip';
  if (Platform.isWindows) {
    return 'cc-handoff-windows-${_windowsPackageArch()}-v$version.zip';
  }
  return null;
}

String? _tagFromReleaseUrl(Uri uri) {
  final parts = uri.pathSegments;
  final i = parts.indexOf('tag');
  if (i >= 0 && i + 1 < parts.length) return parts[i + 1];
  return null;
}

// _latestTagViaWeb resolves GitHub's public /releases/latest redirect. This is
// deliberately separate from the REST API because unauthenticated API calls are
// easily rate-limited on shared networks; the web redirect is enough to decide
// whether a newer version exists.
Future<String> _latestTagViaWeb(Dio dio) async {
  final res = await dio.get(
    'https://github.com/$_repo/releases/latest',
    options: Options(
      followRedirects: false,
      validateStatus: (s) => s != null && s >= 200 && s < 400,
    ),
  );
  final loc = res.headers.value('location');
  final uri = loc == null
      ? res.realUri
      : res.realUri.resolve(loc);
  final tag = _tagFromReleaseUrl(uri);
  if (tag == null || tag.isEmpty) {
    throw StateError('无法解析 GitHub 最新版本');
  }
  return tag;
}

Future<UpdateInfo> _releaseInfo(Dio dio, String tag, String version) async {
  String? url;
  var name = '';
  var releaseUrl = 'https://github.com/$_repo/releases/tag/$tag';
  try {
    final res = await dio.get(
      'https://api.github.com/repos/$_repo/releases/tags/$tag',
      options: Options(
        headers: {'Accept': 'application/vnd.github+json'},
        responseType: ResponseType.json,
      ),
    );
    final data = res.data as Map;
    final htmlUrl = (data['html_url'] ?? '').toString();
    if (htmlUrl.isNotEmpty) releaseUrl = htmlUrl;
    for (final a in (data['assets'] as List? ?? []).whereType<Map>()) {
      final n = (a['name'] ?? '').toString();
      if (_assetMatches(n, version)) {
        url = (a['browser_download_url'] ?? '').toString();
        name = n;
        break;
      }
    }
  } catch (_) {
    // Latest tag is already known via the web redirect. If REST is rate-limited
    // or offline, still surface the update and open the release page as fallback.
  }
  final fallbackName = _fallbackAssetName(version);
  if ((url == null || url.isEmpty) && fallbackName != null) {
    name = fallbackName;
    url = 'https://github.com/$_repo/releases/download/$tag/$fallbackName';
  }
  return UpdateInfo(
    version: version,
    assetUrl: url,
    assetName: name,
    releaseUrl: releaseUrl,
  );
}

// checkForUpdate returns a newer release when one exists, null when current, or
// an error when the check itself failed. Manual checks must not turn failures
// (offline / GitHub rate limit / parse errors) into a false "已是最新".
Future<UpdateCheck> checkForUpdate() async {
  if (kAppVersion == 'dev' || kAppVersion.isEmpty) {
    return const UpdateCheck.update(null);
  }
  final dio = Dio();
  try {
    final tag = await _latestTagViaWeb(dio);
    final version = _versionFromTag(tag);
    if (!_isNewer(version, kAppVersion)) {
      return const UpdateCheck.update(null);
    }
    return UpdateCheck.update(await _releaseInfo(dio, tag, version));
  } catch (e) {
    return UpdateCheck.error(errorText(e));
  }
}

// checkForUpdatesUi runs a check and, when a newer version exists, prompts to
// download + install. silent suppresses the "已是最新" / failure feedback (for the
// automatic on-launch check); pass false for a user-tapped "检查更新".
Future<void> checkForUpdatesUi(BuildContext context, {bool silent = true}) async {
  final check = await checkForUpdate();
  if (!context.mounted) return;
  if (check.error != null) {
    if (!silent) {
      snack(context, '检查更新失败：${check.error}', background: CcColors.danger);
    }
    return;
  }
  final info = check.update;
  if (info == null) {
    if (!silent) {
      snack(
        context,
        kAppVersion == 'dev' ? '开发版,跳过更新检查' : '已是最新版本（$kAppVersion）',
      );
    }
    return;
  }
  final go = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(
        '发现新版本 ${info.version}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: Text('当前 $kAppVersion → ${info.version}'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('下载安装'),
        ),
      ],
    ),
  );
  if (go == true && context.mounted) await _downloadAndInstall(context, info);
}

Future<void> _openExternally(String target) async {
  // Desktop only (dart:io). Android/iOS go through OpenFilex / the asset flow.
  if (Platform.isMacOS) {
    await Process.run('open', [target]);
  } else if (Platform.isWindows) {
    await Process.run('explorer', [target]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [target]);
  }
}

Future<void> _downloadAndInstall(BuildContext context, UpdateInfo info) async {
  // No asset built for this platform → just open the release page to download.
  if (info.assetUrl == null || info.assetUrl!.isEmpty) {
    await _openExternally(info.releaseUrl);
    return;
  }
  // Installers/self-updaters run from temp. Keeping Windows zips in Downloads
  // used to force a manual install; now Windows self-replaces like macOS.
  final dir = await getTemporaryDirectory();
  final path = '${dir.path}/${info.assetName}';
  if (!context.mounted) return;

  final progress = ValueNotifier<double>(0);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DownloadDialog(progress: progress, name: info.assetName),
  );
  try {
    await Dio().download(
      info.assetUrl!,
      path,
      onReceiveProgress: (r, t) {
        if (t > 0) progress.value = r / t;
      },
    );
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context).pop(); // close progress
      snack(context, '下载失败：$e', background: CcColors.danger);
    }
    progress.dispose();
    return;
  }
  if (!context.mounted) {
    progress.dispose();
    return;
  }
  Navigator.of(context).pop(); // close progress
  progress.dispose();

  if (Platform.isAndroid) {
    // Hands the APK to the system package installer (needs the
    // REQUEST_INSTALL_PACKAGES permission, declared in AndroidManifest).
    final r = await OpenFilex.open(path);
    if (r.type != ResultType.done && context.mounted) {
      snack(context, '已下载，但无法调起安装器（${r.message}）。请在「下载」里手动安装。');
    }
  } else if (Platform.isMacOS) {
    await _installMacOSUpdate(context, path);
  } else if (Platform.isWindows) {
    await _installWindowsUpdate(context, path);
  } else {
    // Linux: open the downloaded archive for manual install.
    await _openExternally(path);
    if (context.mounted) {
      snack(context, '已下载更新包，请按系统提示安装');
    }
  }
}

Future<void> _installWindowsUpdate(BuildContext context, String zipPath) async {
  final currentExe = File(Platform.resolvedExecutable);
  final currentDir = currentExe.parent;
  final exeName = currentExe.path.split(Platform.pathSeparator).last;
  final temp = await Directory.systemTemp.createTemp('cc-handoff-update-');
  if (!context.mounted) return;

  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('准备安装更新'),
      content: const Text('应用将退出，自动替换为新版后重新打开。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('重启安装'),
        ),
      ],
    ),
  );
  if (ok != true) return;

  final script = File('${temp.path}${Platform.pathSeparator}install-update.ps1');
  final stagedDir = '${currentDir.path}.new';
  final backupDir = '${currentDir.path}.old';
  final logPath = '${temp.path}${Platform.pathSeparator}install-update.log';
  await script.writeAsString('''
\$ErrorActionPreference = 'Stop'
\$pidToWait = $pid
\$zipPath = ${_ps(zipPath)}
\$currentDir = ${_ps(currentDir.path)}
\$stagedDir = ${_ps(stagedDir)}
\$backupDir = ${_ps(backupDir)}
\$exeName = ${_ps(exeName)}
\$logPath = ${_ps(logPath)}

while (Get-Process -Id \$pidToWait -ErrorAction SilentlyContinue) {
  Start-Sleep -Milliseconds 200
}

try {
  Set-Location -LiteralPath ([System.IO.Path]::GetTempPath())
  if (Test-Path -LiteralPath \$stagedDir) {
    Remove-Item -LiteralPath \$stagedDir -Recurse -Force
  }
  if (Test-Path -LiteralPath \$backupDir) {
    Remove-Item -LiteralPath \$backupDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path \$stagedDir | Out-Null
  Expand-Archive -LiteralPath \$zipPath -DestinationPath \$stagedDir -Force
  Move-Item -LiteralPath \$currentDir -Destination \$backupDir
  Move-Item -LiteralPath \$stagedDir -Destination \$currentDir
  Remove-Item -LiteralPath \$backupDir -Recurse -Force
  Start-Process -FilePath (Join-Path \$currentDir \$exeName)
} catch {
  \$msg = "\$(Get-Date -Format o) update failed: \$_"
  Add-Content -LiteralPath \$logPath -Value \$msg
  if (!(Test-Path -LiteralPath \$currentDir) -and (Test-Path -LiteralPath \$backupDir)) {
    Move-Item -LiteralPath \$backupDir -Destination \$currentDir
  }
  if (Test-Path -LiteralPath (Join-Path \$currentDir \$exeName)) {
    Start-Process -FilePath (Join-Path \$currentDir \$exeName)
  }
  exit 1
}
''');
  await Process.start(
    'powershell.exe',
    [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
    ],
    workingDirectory: temp.path,
    mode: ProcessStartMode.detached,
  );
  exit(0);
}

Future<void> _installMacOSUpdate(BuildContext context, String zipPath) async {
  final currentApp = _currentMacAppBundle();
  if (currentApp == null) {
    await _openExternally(zipPath);
    if (context.mounted) snack(context, '已下载更新包，请手动解压安装');
    return;
  }

  final temp = await Directory.systemTemp.createTemp('cc-handoff-update-');
  final unzip =
      await Process.run('/usr/bin/ditto', ['-x', '-k', zipPath, temp.path]);
  if (unzip.exitCode != 0) {
    await _openExternally(zipPath);
    if (context.mounted) snack(context, '自动解压失败，请手动安装');
    return;
  }
  final newApp = await _findFirstApp(temp);
  if (newApp == null) {
    await _openExternally(zipPath);
    if (context.mounted) snack(context, '更新包里没有找到 .app，请手动安装');
    return;
  }
  if (!context.mounted) return;

  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('准备安装更新'),
      content: const Text('应用将退出，自动替换为新版后重新打开。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('重启安装'),
        ),
      ],
    ),
  );
  if (ok != true) return;

  final script = File('${temp.path}/install-update.zsh');
  final stagedApp = '${currentApp.path}.new';
  final backupApp = '${currentApp.path}.old';
  await script.writeAsString('''
#!/bin/zsh
set -e
while kill -0 $pid 2>/dev/null; do
  sleep 0.2
done
rm -rf ${_sh(stagedApp)} ${_sh(backupApp)}
/usr/bin/ditto ${_sh(newApp.path)} ${_sh(stagedApp)}
mv ${_sh(currentApp.path)} ${_sh(backupApp)}
mv ${_sh(stagedApp)} ${_sh(currentApp.path)}
rm -rf ${_sh(backupApp)}
/usr/bin/open ${_sh(currentApp.path)}
''');
  await Process.run('/bin/chmod', ['700', script.path]);
  await Process.start(
    '/bin/zsh',
    [script.path],
    mode: ProcessStartMode.detached,
  );
  exit(0);
}

Directory? _currentMacAppBundle() {
  var dir = File(Platform.resolvedExecutable).parent;
  while (true) {
    if (dir.path.endsWith('.app')) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

Future<Directory?> _findFirstApp(Directory root) async {
  final queue = <Directory>[root];
  while (queue.isNotEmpty) {
    final dir = queue.removeAt(0);
    await for (final e in dir.list(followLinks: false)) {
      if (e is Directory) {
        if (e.path.endsWith('.app')) return e;
        queue.add(e);
      }
    }
  }
  return null;
}

String _sh(String s) => "'${s.replaceAll("'", "'\\''")}'";

String _ps(String s) => "'${s.replaceAll("'", "''")}'";

class _DownloadDialog extends StatelessWidget {
  final ValueNotifier<double> progress;
  final String name;
  const _DownloadDialog({required this.progress, required this.name});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('下载更新中…'),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, p, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CcType.code(size: 11.5, color: CcColors.muted),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: p == 0 ? null : p),
            const SizedBox(height: 6),
            Text('${(p * 100).toStringAsFixed(0)}%'),
          ],
        ),
      ),
    );
  }
}
