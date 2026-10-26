import 'package:flutter/material.dart';

import '../db.dart';
import '../models.dart';
import '../sync.dart';
import '../theme.dart';
import '../widgets/product_form.dart';
import '../widgets/product_thumb.dart';
import '../widgets/scan_input.dart';

enum _Filter { all, low, out }

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key});
  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  List<Product> _all = [];
  String _keyword = '';
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    _load();
    SyncService.instance.changes.addListener(_load);
  }

  @override
  void dispose() {
    SyncService.instance.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final items = await AppDb.instance.allProducts(keyword: _keyword);
    if (mounted) setState(() => _all = items);
  }

  List<Product> get _shown => switch (_filter) {
        _Filter.all => _all,
        _Filter.low => _all.where((p) => p.stock > 0 && p.stock <= 5).toList(),
        _Filter.out => _all.where((p) => p.stock <= 0).toList(),
      };

  Future<void> _refresh() async {
    final err = await SyncService.instance.sync();
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
    await _load();
  }

  Future<void> _add() async {
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增商品'),
        content: SizedBox(
          width: 360,
          child: ScanInput(hint: '扫描或输入条码', onScanned: (c) => Navigator.pop(ctx, c)),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消'))],
      ),
    );
    if (code == null || !mounted) return;
    final existing = await AppDb.instance.findProduct(code);
    if (!mounted) return;
    await showProductForm(context, barcode: code, existing: existing);
    SyncService.instance.notifyChanged();
    SyncService.instance.sync();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lowN = _all.where((p) => p.stock > 0 && p.stock <= 5).length;
    final outN = _all.where((p) => p.stock <= 0).length;
    final shown = _shown;
    return Scaffold(
      appBar: AppBar(title: const Text('商品与库存')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('新增商品'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: '搜索名称或条码'),
            onChanged: (v) {
              _keyword = v.trim();
              _load();
            },
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
            ChoiceChip(
              label: Text('全部 ${_all.length}'),
              selected: _filter == _Filter.all,
              onSelected: (_) => setState(() => _filter = _Filter.all),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: Text('库存紧张 $lowN'),
              selected: _filter == _Filter.low,
              onSelected: (_) => setState(() => _filter = _Filter.low),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: Text('缺货 $outN'),
              selected: _filter == _Filter.out,
              onSelected: (_) => setState(() => _filter = _Filter.out),
            ),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: shown.isEmpty
                ? ListView(physics: const AlwaysScrollableScrollPhysics(), children: const [
                    SizedBox(height: 80),
                    EmptyState(icon: Icons.inventory_2_outlined, title: '没有商品', subtitle: '下拉同步，或点右下角新增'),
                  ])
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                    itemCount: shown.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final p = shown[i];
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () async {
                            await showProductForm(context, barcode: p.barcode, existing: p);
                            SyncService.instance.notifyChanged();
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Row(children: [
                              ProductThumb(p.imagePath, size: 56),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(p.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 4),
                                  Text(p.barcode, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
                                ]),
                              ),
                              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                Text(yuan(p.priceCents),
                                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: cs.primary)),
                                const SizedBox(height: 4),
                                StockChip(p.stock),
                              ]),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}
