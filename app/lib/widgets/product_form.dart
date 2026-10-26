import 'package:flutter/material.dart';

import '../db.dart';
import '../models.dart';

/// 新建/编辑商品。新建时可顺便填初始库存（记为一笔入库流水）。
Future<Product?> showProductForm(BuildContext context, {required String barcode, Product? existing}) {
  final name = TextEditingController(text: existing?.name ?? '');
  final price = TextEditingController(text: existing == null ? '' : (existing.priceCents / 100).toStringAsFixed(2));
  final qty = TextEditingController(text: existing == null ? '0' : '${existing.stock}');
  final formKey = GlobalKey<FormState>();

  return showDialog<Product>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(existing == null ? '新商品' : '编辑商品'),
      content: Form(
        key: formKey,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Align(alignment: Alignment.centerLeft, child: Text('条码：$barcode')),
          TextFormField(
            controller: name,
            autofocus: true,
            decoration: const InputDecoration(labelText: '商品名称'),
            validator: (v) => (v == null || v.trim().isEmpty) ? '请填写名称' : null,
          ),
          TextFormField(
            controller: price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '售价（元）'),
            validator: (v) => parseYuan(v ?? '') == null ? '请填写正确价格' : null,
          ),
          TextFormField(
            controller: qty,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: existing == null ? '初始库存' : '实际库存（盘点）'),
            validator: (v) => int.tryParse(v ?? '') == null ? '请填写整数' : null,
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () async {
            if (!formKey.currentState!.validate()) return;
            final prod = Product(
              barcode: barcode,
              name: name.text.trim(),
              priceCents: parseYuan(price.text)!,
              stock: existing?.stock ?? 0,
            );
            await AppDb.instance.saveProduct(prod);
            final q = int.parse(qty.text);
            if (existing == null) {
              if (q != 0) await AppDb.instance.stockIn(barcode, q);
            } else {
              await AppDb.instance.setStock(barcode, q);
            }
            final saved = await AppDb.instance.findProduct(barcode);
            if (ctx.mounted) Navigator.pop(ctx, saved);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
}
