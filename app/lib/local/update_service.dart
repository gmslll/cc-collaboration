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

// _assetMatches picks this platform's release asset by the names scripts/package.*
// produce: <App>-macos-v*.zip / cc-handoff-windows-*-v*.zip / *-android-*.apk.
bool _assetMatches(String name) {
  final n = name.toLowerCase();
  if (Platform.isAndroid) return n.endsWith('.apk');
  if (Platform.isMacOS) return n.contains('macos') && n.endsWith('.zip');
  if (Platform.isWindows) return n.contains('windows') && n.endsWith('.zip');
  return false;
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
      if (_assetMatches(n)) {
        url = (a['browser_download_url'] ?? '').toString();
        name = n;
        break;
      }
    }
  } catch (_) {
    // Latest tag is already known via the web redirect. If REST is rate-limited
    // or offline, still surface the update and open the release page as fallback.
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
