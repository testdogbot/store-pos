import 'package:flutter/material.dart';

import '../db.dart';
import '../models.dart';
import '../sync.dart';
import '../theme.dart';
import '../widgets/product_form.dart';
import '../widgets/product_thumb.dart';
import '../widgets/scan_input.dart';

class _LogEntry {
  final String name;
  final String? image;
  final String text;
  final bool created;
  final DateTime at = DateTime.now();
  _LogEntry(this.name, this.image, this.text, {this.created = false});
}

class StockInPage extends StatefulWidget {
  const StockInPage({super.key});
  @override
  State<StockInPage> createState() => _StockInPageState();
}

class _StockInPageState extends State<StockInPage> {
  final List<_LogEntry> _log = [];
  final Map<String, int> _session = {};
  bool _syncQueued = false;

  int get _sessionTotal => _session.values.fold(0, (a, b) => a + b);

  void _syncSoon() {
    SyncService.instance.notifyChanged();
    if (_syncQueued) return;
    _syncQueued = true;
    Future.delayed(const Duration(seconds: 3), () {
      _syncQueued = false;
      SyncService.instance.sync();
    });
  }

  void _addLog(_LogEntry e) {
    if (mounted) setState(() => _log.insert(0, e));
  }

  /// 摄像头连续扫码入库：每扫一次 +1，不弹数量框；新商品弹建档表单。
  Future<String?> _onContinuous(String code) async {
    final prod = await AppDb.instance.findProduct(code);
    if (!mounted) return null;
    String msg;
    if (prod == null) {
      final created = await showProductForm(context, barcode: code);
      if (created == null) return null;
      msg = '新建 ${created.name}，库存 ${created.stock}';
      _addLog(_LogEntry(created.name, created.imagePath, '新建，库存 ${created.stock}', created: true));
    } else {
      await AppDb.instance.stockIn(code, 1);
      _session[code] = (_session[code] ?? 0) + 1;
      msg = '${prod.name} +1 → ${prod.stock + 1}（本次共 +${_session[code]}）';
      _addLog(_LogEntry(prod.name, prod.imagePath, '+1  →  库存 ${prod.stock + 1}'));
    }
    _syncSoon();
    return msg;
  }

  Future<void> _onScan(String code) async {
    final prod = await AppDb.instance.findProduct(code);
    if (!mounted) return;
    if (prod == null) {
      final created = await showProductForm(context, barcode: code);
      if (created != null) {
        _addLog(_LogEntry(created.name, created.imagePath, '新建，库存 ${created.stock}', created: true));
      }
    } else {
      final qty = await showDialog<int>(context: context, builder: (_) => _QtyDialog(product: prod));
      if (qty == null || qty == 0) return;
      await AppDb.instance.stockIn(code, qty);
      _session[code] = (_session[code] ?? 0) + qty;
      _addLog(_LogEntry(prod.name, prod.imagePath, '${qty > 0 ? '+' : ''}$qty  →  库存 ${prod.stock + qty}'));
    }
    _syncSoon();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫码入库'),
        actions: [
          if (_log.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text('本次 +$_sessionTotal 件',
                    style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700)),
              ),
            ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: ScanInput(onScanned: _onScan, onContinuousScan: _onContinuous, hint: '扫描要入库的商品'),
        ),
        Expanded(
          child: _log.isEmpty
              ? const EmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: '扫码入库',
                  subtitle: '扫码枪扫一次可输入数量；相机连续扫码每扫一次 +1',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: _log.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final e = _log[i];
                    final t = '${e.at.hour.toString().padLeft(2, '0')}:${e.at.minute.toString().padLeft(2, '0')}';
                    return Card(
                      child: ListTile(
                        leading: ProductThumb(e.image, size: 44),
                        title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(e.text),
                        trailing: e.created
                            ? Chip(label: const Text('新建'), visualDensity: VisualDensity.compact)
                            : Text(t, style: TextStyle(color: cs.onSurfaceVariant)),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

/// 入库数量：可直接输入，也可点常用数量。
class _QtyDialog extends StatefulWidget {
  final Product product;
  const _QtyDialog({required this.product});
  @override
  State<_QtyDialog> createState() => _QtyDialogState();
}

class _QtyDialogState extends State<_QtyDialog> {
  final _ctrl = TextEditingController(text: '1');

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    return AlertDialog(
      title: Text('入库：${p.name}'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          ProductThumb(p.imagePath, size: 48),
          const SizedBox(width: 12),
          Text('当前库存 ${p.stock}'),
        ]),
        const SizedBox(height: 16),
        TextField(
          controller: _ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '入库数量'),
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: [
          for (final n in const [1, 6, 12, 24, 48]) ActionChip(label: Text('$n'), onPressed: () => _ctrl.text = '$n'),
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, int.tryParse(_ctrl.text)), child: const Text('入库')),
      ],
    );
  }
}
