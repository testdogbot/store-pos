import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../db.dart';
import '../models.dart';
import 'product_thumb.dart';

/// 拍照或从相册选图，自动压缩到 800px、JPEG 75%（一般几十 KB）。
Future<Uint8List?> pickProductImage(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.photo_camera),
          title: const Text('拍照'),
          onTap: () => Navigator.pop(ctx, ImageSource.camera),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library),
          title: const Text('从相册选择'),
          onTap: () => Navigator.pop(ctx, ImageSource.gallery),
        ),
      ]),
    ),
  );
  if (source == null) return null;
  final x = await ImagePicker().pickImage(source: source, maxWidth: 800, maxHeight: 800, imageQuality: 75);
  return x?.readAsBytes();
}

/// 新建/编辑商品。新建时可顺便填初始库存（记为一笔入库流水）。可附带商品图片。
Future<Product?> showProductForm(BuildContext context, {required String barcode, Product? existing}) {
  final name = TextEditingController(text: existing?.name ?? '');
  final price = TextEditingController(text: existing == null ? '' : (existing.priceCents / 100).toStringAsFixed(2));
  final qty = TextEditingController(text: existing == null ? '0' : '${existing.stock}');
  final formKey = GlobalKey<FormState>();
  Uint8List? newImage;

  return showDialog<Product>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(existing == null ? '新商品' : '编辑商品'),
        content: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              GestureDetector(
                onTap: () async {
                  final img = await pickProductImage(ctx);
                  if (img != null) setState(() => newImage = img);
                },
                child: Stack(alignment: Alignment.bottomRight, children: [
                  newImage != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(newImage!, width: 120, height: 120, fit: BoxFit.cover),
                        )
                      : ProductThumb(existing?.imagePath, size: 120),
                  const CircleAvatar(radius: 16, child: Icon(Icons.photo_camera, size: 18)),
                ]),
              ),
              const SizedBox(height: 4),
              Text(newImage == null && existing?.imagePath == null ? '点击添加图片' : '点击更换图片',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              Align(alignment: Alignment.centerLeft, child: Text('条码：$barcode')),
              TextFormField(
                controller: name,
                autofocus: existing == null,
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
              if (newImage != null) await AppDb.instance.saveImageBytes(barcode, newImage!);
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
    ),
  );
}
