import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
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
            openDownload();
          },
          child: const Text('下载更新'),
        ),
      ],
    ),
  );
}
