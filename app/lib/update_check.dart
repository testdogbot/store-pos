import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'sync.dart';

class AppVersion {
  final String name; // 例如 1.0.3
  final int build; // 例如 3
  AppVersion(this.name, this.build);
}

class LatestRelease {
  final int build;
  final String title;
  final String notes;
  LatestRelease(this.build, this.title, this.notes);
}

Future<AppVersion> currentVersion() async {
  final info = await PackageInfo.fromPlatform();
  return AppVersion(info.version, int.tryParse(info.buildNumber) ?? 0);
}

/// 从自己的 Worker 查最新版本（Worker 代理 GitHub Releases，国内更稳）。
Future<LatestRelease?> fetchLatest() async {
  try {
    final url = await SyncService.instance.serverUrl;
    final r = await http.get(Uri.parse('$url/app/latest')).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return LatestRelease((d['build'] as num).toInt(), '${d['version']}', '${d['notes'] ?? ''}');
  } catch (_) {
    return null;
  }
}

/// App 内直接下载新版 APK（显示进度），下载完拉起系统安装界面，点「更新」即可覆盖安装。
Future<void> downloadAndInstall(BuildContext context, LatestRelease latest) async {
  final progress = ValueNotifier<double?>(null);
  final status = ValueNotifier<String>('正在下载…');
  var cancelled = false;
  http.Client? client;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text('更新到 ${latest.title}'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, v, __) => LinearProgressIndicator(value: v),
        ),
        const SizedBox(height: 12),
        ValueListenableBuilder<String>(valueListenable: status, builder: (_, s, __) => Text(s)),
      ]),
      actions: [
        TextButton(
          onPressed: () {
            cancelled = true;
            client?.close();
            Navigator.pop(ctx);
          },
          child: const Text('取消'),
        ),
      ],
    ),
  );

  String? error;
  try {
    final url = await SyncService.instance.serverUrl;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/store-pos-${latest.build}.apk');
    client = http.Client();
    final resp = await client.send(http.Request('GET', Uri.parse('$url/app/download')));
    if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
    final total = resp.contentLength ?? 0;
    final sink = file.openWrite();
    var got = 0;
    try {
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) {
          progress.value = got / total;
          status.value = '${(got / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB';
        }
      }
    } finally {
      await sink.close();
    }
    if (total > 0 && got != total) throw '下载不完整';
    status.value = '下载完成，正在打开安装…';
    final r = await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
    if (r.type != ResultType.done) throw r.message;
  } catch (e) {
    if (!cancelled) error = '$e';
  } finally {
    client?.close();
  }
  if (cancelled || !context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  if (error != null) {
    final useBrowser = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('App 内更新失败'),
        content: Text('$error\n\n可以改用浏览器下载安装。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('用浏览器下载')),
        ],
      ),
    );
    if (useBrowser == true) await openDownload();
  }
}

Future<void> openDownload() async {
  final url = await SyncService.instance.serverUrl;
  await launchUrl(Uri.parse('$url/app/download'), mode: LaunchMode.externalApplication);
}

/// 有新版本就弹窗；silent=true 时没有新版本不提示。
Future<void> checkForUpdate(BuildContext context, {bool silent = false}) async {
  final cur = await currentVersion();
  final latest = await fetchLatest();
  if (!context.mounted) return;
  if (latest == null) {
    if (!silent) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('检查更新失败，请稍后再试')));
    return;
  }
  if (latest.build <= cur.build) {
    if (!silent) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已是最新版本 v${cur.name}')));
    }
    return;
  }
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('发现新版本'),
      content: Text('当前 v${cur.name}（${cur.build}）\n最新 ${latest.title}'
          '${latest.notes.trim().isEmpty ? '' : '\n\n${latest.notes.trim()}'}'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('以后再说')),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            downloadAndInstall(context, latest);
          },
          child: const Text('立即更新'),
        ),
      ],
    ),
  );
}
