import 'package:flutter/material.dart';

import '../db.dart';
import '../sync.dart';
import '../widgets/product_form.dart';
import '../widgets/scan_input.dart';

class StockInPage extends StatefulWidget {
  const StockInPage({super.key});
  @override
  State<StockInPage> createState() => _StockInPageState();
}

class _StockInPageState extends State<StockInPage> {
  final List<String> _log = [];

  Future<void> _onScan(String code) async {
    final prod = await AppDb.instance.findProduct(code);
    if (!mounted) return;
    if (prod == null) {
      final created = await showProductForm(context, barcode: code);
      if (created != null) setState(() => _log.insert(0, '新建 ${created.name}，库存 ${created.stock}'));
    } else {
      final qtyCtrl = TextEditingController(text: '1');
      final qty = await showDialog<int>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('入库：${prod.name}'),
          content: TextField(
            controller: qtyCtrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: '数量（当前库存 ${prod.stock}）'),
            onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(qtyCtrl.text)), child: const Text('入库')),
          ],
        ),
      );
      if (qty == null || qty == 0) return;
      await AppDb.instance.stockIn(code, qty);
      setState(() => _log.insert(0, '${prod.name} +$qty → ${prod.stock + qty}'));
    }
    SyncService.instance.sync();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码入库')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: ScanInput(onScanned: _onScan, hint: '扫描要入库的商品')),
        Expanded(
          child: ListView(children: [for (final l in _log) ListTile(dense: true, title: Text(l))]),
        ),
      ]),
    );
  }
}
