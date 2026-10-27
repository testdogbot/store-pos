import 'package:flutter/material.dart';

import '../admin_api.dart';
import '../models.dart';
import '../sync.dart';
import 'settings_page.dart';

/// 隐藏入口：长按收银页标题 → 输入主账号密码 → 进入管理后台。
Future<void> openAdmin(BuildContext context) async {
  final api = AdminApi.instance;
  if ((await SyncService.instance.token).isEmpty) {
    // 还没配置店铺口令：直接进设置页先配置
    if (context.mounted) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage(firstRun: true)));
    }
    return;
  }
  if (api.password == null) {
    bool has;
    try {
      has = await api.hasAdmin();
    } catch (e) {
      if (context.mounted) _snack(context, '$e');
      return;
    }
    if (!context.mounted) return;
    final ok = await showDialog<bool>(context: context, builder: (_) => _PasswordDialog(setup: !has));
    if (ok != true) return;
  }
  if (context.mounted) {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminPage()));
  }
}

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

class _PasswordDialog extends StatefulWidget {
  final bool setup;
  final bool change;
  const _PasswordDialog({this.setup = false, this.change = false});
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  String? _err;
  bool _busy = false;
  bool get _twice => widget.setup || widget.change;

  Future<void> _submit() async {
    final pw = _pw.text.trim();
    if (pw.length < 4) {
      setState(() => _err = '密码至少 4 位');
      return;
    }
    if (_twice && pw != _pw2.text.trim()) {
      setState(() => _err = '两次输入不一致');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      if (widget.change) {
        await AdminApi.instance.changePassword(pw);
      } else if (widget.setup) {
        await AdminApi.instance.setup(pw);
      } else {
        await AdminApi.instance.login(pw);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _busy = false;
        _err = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.admin_panel_settings_outlined),
      title: Text(widget.change ? '修改主账号密码' : widget.setup ? '设置主账号密码' : '主账号登录'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (widget.setup)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('第一次使用，请设置老板专用密码。之后进入营业额管理和设置都要输入它。'),
          ),
        TextField(
          controller: _pw,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.visiblePassword,
          decoration: InputDecoration(labelText: _twice ? '新密码' : '主账号密码', prefixIcon: const Icon(Icons.lock_outline)),
          onSubmitted: (_) {
            if (!_twice) _submit();
          },
        ),
        if (_twice) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _pw2,
            obscureText: true,
            decoration: const InputDecoration(labelText: '再输一次', prefixIcon: Icon(Icons.lock_outline)),
            onSubmitted: (_) => _submit(),
          ),
        ],
        if (_err != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? '请稍候…' : '确定')),
      ],
    );
  }
}

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});
  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('老板后台'),
        actions: [
          IconButton(
            tooltip: '退出主账号',
            icon: const Icon(Icons.logout),
            onPressed: () {
              AdminApi.instance.password = null;
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: IndexedStack(index: _tab, children: const [_RevenueTab(), SettingsPage(embedded: true)]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bar_chart_outlined), selectedIcon: Icon(Icons.bar_chart), label: '营业额'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}

/// 修改主账号密码（设置页里用）。
Future<void> changeAdminPassword(BuildContext context) async {
  final ok = await showDialog<bool>(context: context, builder: (_) => const _PasswordDialog(change: true));
  if (ok == true && context.mounted) _snack(context, '主账号密码已修改');
}

class _RevenueTab extends StatefulWidget {
  const _RevenueTab();
  @override
  State<_RevenueTab> createState() => _RevenueTabState();
}

class _RevenueTabState extends State<_RevenueTab> {
  int _range = 7;
  List<DaySummary> _days = [];
  int _selected = -1; // 选中的日期下标
  List<SaleRecord> _sales = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool keepSelection = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await SyncService.instance.syncNow(); // 先把本机未上传的销售推上去
      final days = await AdminApi.instance.summary(_range);
      final sel = keepSelection && _selected >= 0 && _selected < days.length ? _selected : days.length - 1;
      final day = days[sel].start;
      final sales = await AdminApi.instance.sales(day, day.add(const Duration(days: 1)));
      if (!mounted) return;
      setState(() {
        _days = days;
        _selected = sel;
        _sales = sales;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _selectDay(int i) async {
    setState(() => _selected = i);
    final day = _days[i].start;
    try {
      final s = await AdminApi.instance.sales(day, day.add(const Duration(days: 1)));
      if (mounted && _selected == i) setState(() => _sales = s);
    } catch (e) {
      if (mounted) _snack(context, '$e');
    }
  }

  String _md(DateTime d) => '${d.month}月${d.day}日';
  String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Future<void> _edit(SaleRecord s) async {
    final res = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text('${_md(s.at)} ${_hm(s.at)} · ${yuan(s.totalCents)}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(s.items.isEmpty
                ? (s.note ?? '手动记账')
                : s.items.map((i) => '${i['name']} ×${i['qty']}  ${yuan(((i['price_cents'] as num?)?.toInt() ?? 0) * ((i['qty'] as num?)?.toInt() ?? 0))}').join('\n')),
          ),
          const Divider(),
          ListTile(
              leading: const Icon(Icons.edit_outlined), title: const Text('修改金额'), onTap: () => Navigator.pop(ctx, 'edit')),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
            title: Text('删除这笔', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!mounted || res == null) return;
    try {
      if (res == 'edit') {
        final r = await _amountDialog(title: '修改金额', initial: s.totalCents, note: s.note ?? '');
        if (r == null) return;
        await AdminApi.instance.editSale(s.id, r.$1, r.$2);
        if (mounted) _snack(context, '已改为 ${yuan(r.$1)}');
      } else {
        final restock = await _confirmDelete(s);
        if (restock == null) return;
        await AdminApi.instance.deleteSale(s.id, restock: restock);
        await SyncService.instance.syncNow();
        if (mounted) _snack(context, '已删除');
      }
      await _load(keepSelection: true);
    } catch (e) {
      if (mounted) _snack(context, '$e');
    }
  }

  /// 返回 null=取消，false=删除（已不再管理库存）
  Future<bool?> _confirmDelete(SaleRecord s) {
    const restock = false;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('删除这笔营业额？'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_md(s.at)} ${_hm(s.at)}  ${yuan(s.totalCents)}'),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, restock),
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );
  }

  Future<(int, String)?> _amountDialog({required String title, int? initial, String note = ''}) {
    final amount = TextEditingController(text: initial == null ? '' : (initial / 100).toStringAsFixed(2));
    final noteC = TextEditingController(text: note);
    return showDialog<(int, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(labelText: '金额（元）', prefixText: '¥ '),
          ),
          const SizedBox(height: 12),
          TextField(controller: noteC, decoration: const InputDecoration(labelText: '备注（可选）')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final c = parseYuan(amount.text);
              if (c == null) return;
              Navigator.pop(ctx, (c, noteC.text.trim()));
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _addManual() async {
    final r = await _amountDialog(title: '手动记一笔', note: '');
    if (r == null) return;
    final day = _days.isEmpty ? DateTime.now() : _days[_selected].start;
    final now = DateTime.now();
    final at = DateUtils.isSameDay(day, now)
        ? now
        : DateTime(day.year, day.month, day.day, 12);
    try {
      await AdminApi.instance.addSale(r.$1, r.$2.isEmpty ? '手动记账' : r.$2, at);
      if (mounted) _snack(context, '已记入 ${yuan(r.$1)}');
      await _load(keepSelection: true);
    } catch (e) {
      if (mounted) _snack(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading && _days.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _days.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off, size: 48, color: cs.error),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: _load, child: const Text('重试')),
        ]),
      );
    }
    final rangeTotal = _days.fold<int>(0, (s, d) => s + d.totalCents);
    final rangeCount = _days.fold<int>(0, (s, d) => s + d.count);
    final sel = _days[_selected];
    final maxV = _days.fold<int>(1, (m, d) => d.totalCents > m ? d.totalCents : m);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addManual,
        icon: const Icon(Icons.add),
        label: const Text('记一笔'),
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(keepSelection: true),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(colors: [cs.primary, cs.tertiary]),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(DateUtils.isSameDay(sel.start, DateTime.now()) ? '今日营业额' : '${_md(sel.start)}营业额',
                    style: TextStyle(color: cs.onPrimary.withValues(alpha: 0.85))),
                const Spacer(),
                if (_loading)
                  SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary)),
              ]),
              const SizedBox(height: 6),
              Text(yuan(sel.totalCents),
                  style: TextStyle(color: cs.onPrimary, fontSize: 34, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('${sel.count} 笔 · 近 $_range 天共 ${yuan(rangeTotal)}（$rangeCount 笔）',
                  style: TextStyle(color: cs.onPrimary.withValues(alpha: 0.9))),
            ]),
          ),
          const SizedBox(height: 12),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 7, label: Text('近7天')),
              ButtonSegment(value: 30, label: Text('近30天')),
            ],
            selected: {_range},
            onSelectionChanged: (s) {
              _range = s.first;
              _load();
            },
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
              child: SizedBox(
                height: 150,
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  for (var i = 0; i < _days.length; i++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _selectDay(i),
                        child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                          if (_range == 7)
                            Text(_days[i].totalCents == 0 ? '' : (_days[i].totalCents / 100).toStringAsFixed(0),
                                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
                          const SizedBox(height: 2),
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            margin: EdgeInsets.symmetric(horizontal: _range == 7 ? 8 : 1.5),
                            height: 4 + 100 * _days[i].totalCents / maxV,
                            decoration: BoxDecoration(
                              color: i == _selected ? cs.primary : cs.primary.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _range == 7 || i % 5 == 0 || i == _days.length - 1 ? '${_days[i].start.day}' : '',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: i == _selected ? FontWeight.w700 : FontWeight.normal,
                                color: i == _selected ? cs.primary : cs.onSurfaceVariant),
                          ),
                        ]),
                      ),
                    ),
                ]),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
            child: Row(children: [
              Text('${_md(sel.start)}明细', style: const TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              Text('点一笔可修改或删除', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ]),
          ),
          if (_sales.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text('这天还没有营业记录', style: TextStyle(color: cs.onSurfaceVariant))),
            )
          else
            for (final s in _sales)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    onTap: () => _edit(s),
                    leading: CircleAvatar(
                      backgroundColor: cs.primaryContainer,
                      child: Icon(s.items.isEmpty ? Icons.edit_note : Icons.receipt_long_outlined,
                          color: cs.onPrimaryContainer, size: 20),
                    ),
                    title: Text(s.summary, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text([
                      _hm(s.at),
                      if (s.originalTotalCents != null) '原 ${yuan(s.originalTotalCents!)}',
                      if (s.note != null && s.note!.isNotEmpty && s.items.isNotEmpty) s.note!,
                    ].join(' · ')),
                    trailing: Text(yuan(s.totalCents),
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: cs.primary)),
                  ),
                ),
              ),
        ]),
      ),
    );
  }
}
