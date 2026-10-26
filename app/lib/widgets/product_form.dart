import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../db.dart';
import '../models.dart';
import '../sync.dart';
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

/// 删除商品前二次确认。
Future<bool> confirmDeleteProduct(BuildContext context, Product p) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除商品？'),
      content: Text('「${p.name}」将从所有手机上删除，已有的销售记录不受影响。以后再扫这个条码可以重新添加。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// 新建/编辑商品。新建时自动按条码查商品名称、参考价、图片并预填；可附带商品图片。
Future<Product?> showProductForm(BuildContext context, {required String barcode, Product? existing}) {
  return showDialog<Product>(
    context: context,
    builder: (_) => _ProductFormDialog(barcode: barcode, existing: existing),
  );
}

class _ProductFormDialog extends StatefulWidget {
  final String barcode;
  final Product? existing;
  const _ProductFormDialog({required this.barcode, this.existing});
  @override
  State<_ProductFormDialog> createState() => _ProductFormDialogState();
}

class _ProductFormDialogState extends State<_ProductFormDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _price = TextEditingController(
      text: widget.existing == null ? '' : (widget.existing!.priceCents / 100).toStringAsFixed(2));
  late final _qty = TextEditingController(text: widget.existing == null ? '0' : '${widget.existing!.stock}');
  final _formKey = GlobalKey<FormState>();
  final _priceFocus = FocusNode();
  Uint8List? _newImage;
  bool _looking = false;
  String? _lookupNote;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.existing == null) _lookup();
  }

  Future<void> _lookup() async {
    setState(() => _looking = true);
    final d = await SyncService.instance.lookupBarcode(widget.barcode);
    if (!mounted) return;
    if (d == null) {
      setState(() {
        _looking = false;
        _lookupNote = '条码库没查到，请手动填写';
      });
      return;
    }
    final name = '${d['display_name'] ?? d['name'] ?? ''}'.trim();
    final price = (d['price_cents'] as num?)?.toInt();
    setState(() {
      _looking = false;
      if (_name.text.trim().isEmpty && name.isNotEmpty) _name.text = name;
      if (_price.text.trim().isEmpty && price != null && price > 0) {
        _price.text = (price / 100).toStringAsFixed(2);
      }
      _lookupNote = price != null && price > 0 ? '已自动识别，售价为参考价，请核对' : '已自动识别，请填写售价';
    });
    if (price == null || price <= 0) _priceFocus.requestFocus();
    final img = d['image_url'] as String?;
    if (img != null && _newImage == null) {
      final bytes = await SyncService.instance.fetchLookupImage(img);
      if (bytes != null && mounted && _newImage == null) setState(() => _newImage = Uint8List.fromList(bytes));
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final barcode = widget.barcode;
    final existing = widget.existing;
    final prod = Product(
      barcode: barcode,
      name: _name.text.trim(),
      priceCents: parseYuan(_price.text)!,
      stock: existing?.stock ?? 0,
    );
    await AppDb.instance.saveProduct(prod);
    if (_newImage != null) await AppDb.instance.saveImageBytes(barcode, _newImage!);
    final q = int.parse(_qty.text);
    if (existing == null) {
      if (q != 0) await AppDb.instance.stockIn(barcode, q);
    } else {
      await AppDb.instance.setStock(barcode, q);
    }
    final saved = await AppDb.instance.findProduct(barcode);
    if (mounted) Navigator.pop(context, saved);
  }

  @override
  void dispose() {
    _priceFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final existing = widget.existing;
    return AlertDialog(
      title: Text(existing == null ? '新商品' : '编辑商品'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            GestureDetector(
              onTap: () async {
                final img = await pickProductImage(context);
                if (img != null) setState(() => _newImage = img);
              },
              child: Stack(alignment: Alignment.bottomRight, children: [
                _newImage != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(_newImage!, width: 120, height: 120, fit: BoxFit.cover),
                      )
                    : ProductThumb(existing?.imagePath, size: 120),
                const CircleAvatar(radius: 16, child: Icon(Icons.photo_camera, size: 18)),
              ]),
            ),
            const SizedBox(height: 4),
            Text(_newImage == null && existing?.imagePath == null ? '点击添加图片' : '点击更换图片',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: Text('条码：${widget.barcode}')),
            if (_looking || _lookupNote != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  if (_looking)
                    const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Icon(Icons.auto_awesome, size: 16, color: cs.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_looking ? '正在识别商品…' : _lookupNote!,
                        style: TextStyle(fontSize: 12, color: cs.primary)),
                  ),
                ]),
              ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _name,
              autofocus: false,
              decoration: const InputDecoration(labelText: '商品名称'),
              validator: (v) => (v == null || v.trim().isEmpty) ? '请填写名称' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _price,
              focusNode: _priceFocus,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: '售价（元）', prefixText: '¥ '),
              validator: (v) => parseYuan(v ?? '') == null ? '请填写正确价格' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _qty,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: existing == null ? '初始库存' : '实际库存（盘点）'),
              validator: (v) => int.tryParse(v ?? '') == null ? '请填写整数' : null,
            ),
          ]),
        ),
      ),
      actions: [
        if (existing != null)
          TextButton(
            onPressed: _saving
                ? null
                : () async {
                    if (await confirmDeleteProduct(context, existing)) {
                      await AppDb.instance.deleteProduct(existing.barcode);
                      if (mounted) Navigator.pop(context);
                    }
                  },
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: const Text('删除'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('保存')),
      ],
    );
  }
}
