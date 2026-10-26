import 'package:flutter/material.dart';

import '../db.dart';
import '../models.dart';
import '../sync.dart';
import '../widgets/product_form.dart';
import '../widgets/scan_input.dart';

class CheckoutPage extends StatefulWidget {
  const CheckoutPage({super.key});
  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  final List<CartItem> _cart = [];

  int get _total => _cart.fold(0, (s, i) => s + i.subtotal);

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
      } else {
        item = CartItem(prod!);
        _cart.insert(0, item);
      }
    });
    return '${item.product.name} ×${item.qty}\n合计 ${yuan(_total)}';
  }

  Future<void> _checkout() async {
    if (_cart.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认收款'),
        content: Text('应收 ${yuan(_total)}', style: const TextStyle(fontSize: 28)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('已收款')),
        ],
      ),
    );
    if (ok != true) return;
    await AppDb.instance.checkout(_cart);
    final low = _cart.where((i) => i.product.stock - i.qty <= 0).map((i) => i.product.name).toList();
    setState(_cart.clear);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(low.isEmpty ? '结账完成' : '结账完成。库存已空：${low.join('、')}'),
    ));
    SyncService.instance.sync();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('收银')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: ScanInput(onScanned: _onScan, onContinuousScan: _onScan)),
        Expanded(
          child: _cart.isEmpty
              ? const Center(child: Text('扫描商品条码开始收银'))
              : ListView.separated(
                  itemCount: _cart.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, idx) {
                    final item = _cart[idx];
                    return ListTile(
                      title: Text(item.product.name),
                      subtitle: Text('${yuan(item.product.priceCents)}  ·  库存 ${item.product.stock}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () => setState(() {
                            if (--item.qty <= 0) _cart.removeAt(idx);
                          }),
                        ),
                        Text('${item.qty}', style: const TextStyle(fontSize: 18)),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: () => setState(() => item.qty++),
                        ),
                      ]),
                    );
                  },
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(child: Text('合计 ${yuan(_total)}', style: Theme.of(context).textTheme.headlineSmall)),
              if (_cart.isNotEmpty)
                TextButton(onPressed: () => setState(_cart.clear), child: const Text('清空')),
              FilledButton.icon(
                onPressed: _cart.isEmpty ? null : _checkout,
                icon: const Icon(Icons.point_of_sale),
                label: const Text('结账'),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
