import 'package:flutter/material.dart';

import '../db.dart';
import '../models.dart';
import '../sync.dart';
import '../widgets/product_form.dart';

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key});
  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  List<Product> _items = [];
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await AppDb.instance.allProducts(keyword: _keyword);
    if (mounted) setState(() => _items = items);
  }

  Future<void> _refresh() async {
    final err = await SyncService.instance.sync();
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('商品与库存')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search), hintText: '搜索名称或条码', border: OutlineInputBorder()),
            onChanged: (v) {
              _keyword = v.trim();
              _load();
            },
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: _items.length,
              itemBuilder: (_, i) {
                final p = _items[i];
                return ListTile(
                  title: Text(p.name),
                  subtitle: Text('${p.barcode}  ·  ${yuan(p.priceCents)}'),
                  trailing: Text('库存 ${p.stock}',
                      style: TextStyle(color: p.stock <= 0 ? Colors.red : null, fontWeight: FontWeight.bold)),
                  onTap: () async {
                    await showProductForm(context, barcode: p.barcode, existing: p);
                    _load();
                  },
                );
              },
            ),
          ),
        ),
      ]),
    );
  }
}
