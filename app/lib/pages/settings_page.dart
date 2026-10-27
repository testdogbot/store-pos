import 'package:flutter/material.dart';

import '../admin_api.dart';
import '../sync.dart';
import '../update_check.dart';
import 'admin_page.dart';

class SettingsPage extends StatefulWidget {
  /// embedded=true：嵌在老板后台里；firstRun=true：首次使用还没配置口令。
  final bool embedded;
  final bool firstRun;
  const SettingsPage({super.key, this.embedded = false, this.firstRun = false});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  String _version = '';
  bool _showToken = false;
  bool _saving = false;
  String? _azTail; // 条码查询 Key 末 4 位
  bool _azLoaded = false;

  @override
  void initState() {
    super.initState();
    () async {
      _url.text = await SyncService.instance.serverUrl;
      _token.text = await SyncService.instance.token;
      final v = await currentVersion();
      if (mounted) setState(() => _version = 'v${v.name}（构建 ${v.build}）');
      if (widget.embedded) _loadAz();
    }();
  }

  Future<void> _saveAndSync() async {
    setState(() => _saving = true);
    await SyncService.instance.saveSettings(_url.text, _token.text);
    final err = await SyncService.instance.syncNow();
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? '已保存并同步成功')));
    if (err == null && widget.firstRun) Navigator.pop(context);
  }

  Future<void> _loadAz() async {
    try {
      final t = await AdminApi.instance.apizeroTail();
      if (mounted) setState(() {
        _azTail = t;
        _azLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _azLoaded = true);
    }
  }

  Future<void> _editAz() async {
    final c = TextEditingController();
    final key = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('官方条码库 Key'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('在 apizero.cn 注册登录 → 控制台 → API Key，复制后粘贴到这里。填好后扫不到的商品会去中国物品编码中心官方数据里查（每天免费 5 次）。'),
          const SizedBox(height: 12),
          TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'API Key', prefixIcon: Icon(Icons.vpn_key_outlined)),
          ),
        ]),
        actions: [
          if (_azTail != null)
            TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('清除')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('保存')),
        ],
      ),
    );
    if (key == null || !mounted) return;
    try {
      final t = await AdminApi.instance.setApizeroKey(key);
      if (!mounted) return;
      setState(() => _azTail = t);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t == null ? '已清除' : '已保存，Key 有效')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        ),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: children))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final body = ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        if (widget.firstRun)
          Card(
            color: cs.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('第一次使用，请填写服务器地址和店铺口令。以后设置页会隐藏，只有老板长按「收银」标题、输入主账号密码才能进入。',
                  style: TextStyle(color: cs.onPrimaryContainer)),
            ),
          ),
        _section('云同步', [
          ValueListenableBuilder<SyncStatus>(
            valueListenable: SyncService.instance.status,
            builder: (_, st, __) {
              final ok = st.error == null && st.lastAt != null;
              final IconData icon = st.syncing
                  ? Icons.sync
                  : st.error != null
                      ? Icons.cloud_off
                      : ok
                          ? Icons.cloud_done
                          : Icons.cloud_queue;
              final Color color = st.error != null ? cs.error : (ok ? Colors.green : cs.onSurfaceVariant);
              final text = st.syncing
                  ? '正在同步…'
                  : st.error ?? (st.lastAt == null ? '尚未同步' : '已同步 · ${_ago(st.lastAt!)}');
              return Row(children: [
                Icon(icon, color: color),
                const SizedBox(width: 10),
                Expanded(child: Text(text, style: TextStyle(color: color))),
              ]);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
                labelText: '服务器地址', hintText: 'https://pos.xiaolele.eu.cc', prefixIcon: Icon(Icons.dns_outlined)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: !_showToken,
            decoration: InputDecoration(
              labelText: '店铺口令',
              prefixIcon: const Icon(Icons.key_outlined),
              suffixIcon: IconButton(
                icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showToken = !_showToken),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : _saveAndSync,
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_sync_outlined),
              label: const Text('保存并同步'),
            ),
          ),
          const SizedBox(height: 10),
          Text('不填服务器也能单机离线使用；多台手机共享库存时，所有手机填同一个地址和口令。',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
        ]),

        if (widget.embedded)
          _section('主账号', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.admin_panel_settings_outlined, color: cs.primary),
              title: const Text('修改主账号密码'),
              subtitle: const Text('进入老板后台时使用'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => changeAdminPassword(context),
            ),
          ]),
        if (widget.embedded)
          _section('条码识别', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.qr_code_2, color: cs.primary),
              title: const Text('官方条码库（中国物品编码中心）'),
              subtitle: Text(!_azLoaded
                  ? '读取中…'
                  : _azTail == null
                      ? '未设置 Key，点此填写'
                      : '已启用 · Key 尾号 $_azTail'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _editAz,
            ),
          ]),

        _section('关于', [
          Row(children: [
            Icon(Icons.storefront_outlined, color: cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('小店收银', style: TextStyle(fontWeight: FontWeight.w600)),
                Text(_version, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
              ]),
            ),
            OutlinedButton.icon(
              onPressed: () => checkForUpdate(context),
              icon: const Icon(Icons.system_update_outlined, size: 18),
              label: const Text('检查更新'),
            ),
          ]),
        ]),
      ]);
    if (widget.embedded) return body;
    return Scaffold(appBar: AppBar(title: Text(widget.firstRun ? '首次设置' : '设置')), body: body);
  }
}
