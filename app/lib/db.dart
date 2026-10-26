import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';

const _uuid = Uuid();

/// 本地数据库：先记账，有网再同步。
/// 库存 = 服务器库存 + 本地未同步的流水。
class AppDb {
  AppDb._();
  static final AppDb instance = AppDb._();
  Database? _db;

  Future<Database> get db async => _db ??= await _open();

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'store_pos.db');
    return openDatabase(path, version: 1, onCreate: (db, _) async {
      await db.execute('''
        CREATE TABLE products(
          barcode TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          price_cents INTEGER NOT NULL DEFAULT 0,
          stock INTEGER NOT NULL DEFAULT 0,
          dirty INTEGER NOT NULL DEFAULT 0
        )''');
      await db.execute('''
        CREATE TABLE movements(
          id TEXT PRIMARY KEY,
          barcode TEXT NOT NULL,
          delta INTEGER NOT NULL,
          type TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0
        )''');
      await db.execute('''
        CREATE TABLE sales(
          id TEXT PRIMARY KEY,
          total_cents INTEGER NOT NULL,
          items TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0
        )''');
    });
  }

  Future<Product?> findProduct(String barcode) async {
    final rows = await (await db).query('products', where: 'barcode = ?', whereArgs: [barcode]);
    return rows.isEmpty ? null : Product.fromMap(rows.first);
  }

  Future<List<Product>> allProducts({String keyword = ''}) async {
    final rows = await (await db).query(
      'products',
      where: keyword.isEmpty ? null : 'name LIKE ? OR barcode LIKE ?',
      whereArgs: keyword.isEmpty ? null : ['%$keyword%', '%$keyword%'],
      orderBy: 'name',
    );
    return rows.map(Product.fromMap).toList();
  }

  /// 新建或修改商品资料（名称、价格）。
  Future<void> saveProduct(Product prod) async {
    await (await db).insert(
      'products',
      {'barcode': prod.barcode, 'name': prod.name, 'price_cents': prod.priceCents, 'stock': prod.stock, 'dirty': 1},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 记一笔库存流水并更新本地库存。type: sale / stock_in / adjust
  Future<void> addMovement(Transaction txn, String barcode, int delta, String type) async {
    await txn.insert('movements', {
      'id': _uuid.v4(),
      'barcode': barcode,
      'delta': delta,
      'type': type,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    await txn.rawUpdate('UPDATE products SET stock = stock + ? WHERE barcode = ?', [delta, barcode]);
  }

  Future<void> stockIn(String barcode, int qty) async {
    await (await db).transaction((txn) => addMovement(txn, barcode, qty, 'stock_in'));
  }

  /// 盘点：把库存直接改成实际数量（记一条 adjust 流水）。
  Future<void> setStock(String barcode, int actual) async {
    final prod = await findProduct(barcode);
    if (prod == null || prod.stock == actual) return;
    await (await db).transaction((txn) => addMovement(txn, barcode, actual - prod.stock, 'adjust'));
  }

  /// 结账：写销售记录，并逐个扣库存。
  Future<void> checkout(List<CartItem> cart) async {
    final total = cart.fold<int>(0, (s, i) => s + i.subtotal);
    await (await db).transaction((txn) async {
      await txn.insert('sales', {
        'id': _uuid.v4(),
        'total_cents': total,
        'items': jsonEncode([
          for (final i in cart)
            {'barcode': i.product.barcode, 'name': i.product.name, 'price_cents': i.product.priceCents, 'qty': i.qty}
        ]),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      for (final i in cart) {
        await addMovement(txn, i.product.barcode, -i.qty, 'sale');
      }
    });
  }

  Future<Map<String, int>> todaySummary() async {
    final start = DateTime.now();
    final since = DateTime(start.year, start.month, start.day).millisecondsSinceEpoch;
    final r = await (await db).rawQuery(
        'SELECT COUNT(*) AS n, COALESCE(SUM(total_cents),0) AS total FROM sales WHERE created_at >= ?', [since]);
    return {'count': (r.first['n'] as num).toInt(), 'total': (r.first['total'] as num).toInt()};
  }
}
