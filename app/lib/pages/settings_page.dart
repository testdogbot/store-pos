import 'package:flutter/material.dart';

import '../db.dart';
import '../models.dart';
import '../sync.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  Map<String, int>? _today;

  @override
  void initState() {
    super.initState();
    () async {
      _url.text = await SyncService.instance.serverUrl;
      _token.text = await SyncService.instance.token;
      final t = await AppDb.instance.todaySummary();
      if (mounted) setState(() => _today = t);
    }();
  }

  Future<void> _saveAndSync() async {
    await SyncService.instance.saveSettings(_url.text, _token.text);
    final err = await SyncService.instance.sync();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? '已保存并同步')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (_today != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.today),
              title: Text('今日营业额 ${yuan(_today!['total']!)}'),
              subtitle: Text('共 ${_today!['count']} 笔'),
            ),
          ),
        const SizedBox(height: 16),
        Text('云同步（Cloudflare）', style: Theme.of(context).textTheme.titleMedium),
        TextField(
          controller: _url,
          decoration: const InputDecoration(labelText: '服务器地址', hintText: 'https://pos.xiaolele.eu.cc'),
        ),
        TextField(
          controller: _token,
          obscureText: true,
          decoration: const InputDecoration(labelText: '店铺口令（API_TOKEN）'),
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: _saveAndSync, child: const Text('保存并同步')),
        const SizedBox(height: 8),
        const Text('不填服务器也能单机离线使用；多台手机共享库存时，所有手机填同一个地址和口令。'),
      ]),
    );
  }
}
