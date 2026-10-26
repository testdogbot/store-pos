import 'package:flutter/material.dart';

import '../db.dart';
import '../models.dart';
import '../sync.dart';
import '../theme.dart';
import '../widgets/product_form.dart';
import '../widgets/product_thumb.dart';
import '../widgets/scan_input.dart';
import 'admin_page.dart';

class CheckoutPage extends StatefulWidget {
  const CheckoutPage({super.key});
  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  final List<CartItem> _cart = [];

  int get _total => _cart.fold(0, (s, i) => s + i.subtotal);
  int get _count => _cart.fold(0, (s, i) => s + i.qty);

  /// 返回连续扫码页显示的提示；null 表示没加进购物车。
  Future<String?> _onScan(String code) async {
    var prod = await AppDb.instance.findProduct(code);
    if (prod == null) {
      if (!mounted) return null;
      prod = await showProductForm(context, barcode: code);
      if (prod == null) return null;
    }
    late CartItem item;
    setState(() {
      final existing = _cart.where((i) => i.product.barcode == code).firstOrNull;
      if (existing != null) {
        existing.qty++;
        item = existing;
        _cart
          ..remove(existing)
          ..insert(0, existing);
      } else {
        item = CartItem(prod!);
        _cart.insert(0, item);
      }
    });
    return '${item.product.name} ×${item.qty}\n合计 ${yuan(_total)}';
  }

  Future<void> _checkout() async {
    if (_cart.isEmpty) return;
    final ok = await showDialog<bool>(context: context, builder: (_) => _PayDialog(total: _total));
    if (ok != true) return;
    await AppDb.instance.checkout(_cart);
    final low = _cart.where((i) => i.product.stock - i.qty <= 0).map((i) => i.product.name).toList();
    final total = _total;
    setState(_cart.clear);
    SyncService.instance.notifyChanged();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(low.isEmpty ? '收款 ${yuan(total)}，结账完成' : '结账完成。已缺货：${low.join('、')}'),
    ));
    SyncService.instance.sync();
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空购物车？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) setState(_cart.clear);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        // 隐藏入口：长按标题进入老板后台
        title: GestureDetector(
          onLongPress: () => openAdmin(context),
          child: const Text('收银'),
        ),
        actions: [
          ValueListenableBuilder<SyncStatus>(
            valueListenable: SyncService.instance.status,
            builder: (_, st, __) => Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                st.syncing
                    ? Icons.cloud_sync_outlined
                    : st.error != null
                        ? Icons.cloud_off_outlined
                        : Icons.cloud_done_outlined,
                size: 20,
                color: st.error != null ? cs.error : cs.onSurfaceVariant,
              ),
            ),
          ),
          if (_cart.isNotEmpty)
            TextButton.icon(onPressed: _confirmClear, icon: const Icon(Icons.delete_sweep_outlined), label: const Text('清空')),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: ScanInput(onScanned: _onScan, onContinuousScan: _onScan),
        ),
        Expanded(
          child: _cart.isEmpty
              ? const EmptyState(
                  icon: Icons.qr_code_scanner,
                  title: '扫描商品条码开始收银',
                  subtitle: '扫码枪直接扫，或点输入框右侧相机连续扫码',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: _cart.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, idx) {
                    final item = _cart[idx];
                    return Dismissible(
                      key: ValueKey(item.product.barcode),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(14)),
                        child: Icon(Icons.delete_outline, color: cs.onErrorContainer),
                      ),
                      onDismissed: (_) => setState(() => _cart.remove(item)),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(children: [
                            ProductThumb(item.product.imagePath, size: 56),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(item.product.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                                const SizedBox(height: 4),
                                Text('${yuan(item.product.priceCents)} × ${item.qty} = ${yuan(item.subtotal)}',
                                    style: TextStyle(color: cs.onSurfaceVariant)),
                              ]),
                            ),
                            _QtyStepper(
                              qty: item.qty,
                              onMinus: () => setState(() {
                                if (--item.qty <= 0) _cart.remove(item);
                              }),
                              onPlus: () => setState(() => item.qty++),
                            ),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
        ),
        Material(
          color: cs.surfaceContainer,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('共 $_count 件', style: TextStyle(color: cs.onSurfaceVariant)),
                    Text(yuan(_total),
                        style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: cs.primary)),
                  ]),
                ),
                SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: _cart.isEmpty ? null : _checkout,
                    icon: const Icon(Icons.payments_outlined),
                    label: const Text('结账'),
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 28)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _QtyStepper extends StatelessWidget {
  final int qty;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const _QtyStepper({required this.qty, required this.onMinus, required this.onPlus});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(24)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.remove), onPressed: onMinus),
        SizedBox(
          width: 28,
          child: Text('$qty', textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        ),
        IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add), onPressed: onPlus),
      ]),
    );
  }
}

/// 收款：输入实收金额（或点快捷金额），自动算找零。
class _PayDialog extends StatefulWidget {
  final int total;
  const _PayDialog({required this.total});
  @override
  State<_PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<_PayDialog> {
  final _paid = TextEditingController();
  int? _paidCents;

  void _set(int cents) {
    _paid.text = (cents / 100).toStringAsFixed(cents % 100 == 0 ? 0 : 2);
    setState(() => _paidCents = cents);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final change = _paidCents == null ? null : _paidCents! - widget.total;
    final quick = <int>{widget.total, 1000, 2000, 5000, 10000}.where((c) => c >= widget.total).toList()..sort();
    return AlertDialog(
      title: const Text('收款'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('应收', style: TextStyle(color: cs.onSurfaceVariant)),
        Text(yuan(widget.total), style: TextStyle(fontSize: 36, fontWeight: FontWeight.w800, color: cs.primary)),
        const SizedBox(height: 16),
        TextField(
          controller: _paid,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: '实收（元，可不填）', prefixText: '¥ '),
          onChanged: (v) => setState(() => _paidCents = parseYuan(v)),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in quick)
            ActionChip(label: Text(c == widget.total ? '刚好' : yuan(c)), onPressed: () => _set(c)),
        ]),
        if (change != null) ...[
          const SizedBox(height: 16),
          Text(
            change >= 0 ? '找零 ${yuan(change)}' : '还差 ${yuan(-change)}',
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w700, color: change >= 0 ? Colors.green.shade700 : cs.error),
          ),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(
          onPressed: change != null && change < 0 ? null : () => Navigator.pop(context, true),
          child: const Text('确认收款'),
        ),
      ],
    );
  }
}
