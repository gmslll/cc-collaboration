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
// (Android) or reveals it (desktop; an ad-hoc/un-notarized macOS app can't
// self-install silently). Public repo → no token needed.
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

// _assetMatches picks this platform's release asset by the names scripts/package.*
// produce: <App>-macos-v*.zip / cc-handoff-windows-*-v*.zip / *-android-*.apk.
bool _assetMatches(String name) {
  final n = name.toLowerCase();
  if (Platform.isAndroid) return n.endsWith('.apk');
  if (Platform.isMacOS) return n.contains('macos') && n.endsWith('.zip');
  if (Platform.isWindows) return n.contains('windows') && n.endsWith('.zip');
  return false;
}

// checkForUpdate returns the latest release when it's newer than this build (and
// resolves this platform's asset), else null. Never throws.
Future<UpdateInfo?> checkForUpdate() async {
  try {
    final res = await Dio().get(
      'https://api.github.com/repos/$_repo/releases/latest',
      options: Options(
        headers: {'Accept': 'application/vnd.github+json'},
        responseType: ResponseType.json,
      ),
    );
    final data = res.data as Map;
    final tag = (data['tag_name'] ?? '').toString();
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    if (!_isNewer(version, kAppVersion)) return null;
    String? url;
    var name = '';
    for (final a in (data['assets'] as List? ?? []).whereType<Map>()) {
      final n = (a['name'] ?? '').toString();
      if (_assetMatches(n)) {
        url = (a['browser_download_url'] ?? '').toString();
        name = n;
        break;
      }
    }
    return UpdateInfo(
      version: version,
      assetUrl: url,
      assetName: name,
      releaseUrl: (data['html_url'] ?? '').toString(),
    );
  } catch (_) {
    return null; // offline / rate-limited / parse error — stay quiet
  }
}

// checkForUpdatesUi runs a check and, when a newer version exists, prompts to
// download + install. silent suppresses the "已是最新" / failure feedback (for the
// automatic on-launch check); pass false for a user-tapped "检查更新".
Future<void> checkForUpdatesUi(BuildContext context, {bool silent = true}) async {
  final info = await checkForUpdate();
  if (!context.mounted) return;
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
      title: Text('发现新版本 ${info.version}'),
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
  // Android installs from temp; desktop downloads to ~/Downloads so the user
  // can find/keep it.
  final dir = Platform.isAndroid
      ? await getTemporaryDirectory()
      : (await getDownloadsDirectory()) ?? await getTemporaryDirectory();
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
  } else {
    // Desktop: open the zip (macOS Archive Utility unzips it) + reveal it; the
    // user drags the new .app into 应用程序. An ad-hoc app can't self-replace.
    await _openExternally(path);
    if (context.mounted) {
      snack(context, '已下载到「下载」文件夹并解压，请把新版拖入「应用程序」覆盖旧版');
    }
  }
}

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
