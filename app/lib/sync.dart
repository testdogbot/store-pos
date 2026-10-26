import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'db.dart';

/// 与 Cloudflare Worker 同步：推送本地未同步的商品/流水/销售，拉回服务器最新商品和库存。
class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();
  bool _running = false;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<String> get serverUrl async => (await _prefs).getString('server_url') ?? 'https://pos.xiaolele.eu.cc';
  Future<String> get token async => (await _prefs).getString('api_token') ?? '';

  Future<void> saveSettings(String url, String apiToken) async {
    final prefs = await _prefs;
    await prefs.setString('server_url', url.trim().replaceAll(RegExp(r'/+$'), ''));
    await prefs.setString('api_token', apiToken.trim());
  }

  Future<String> _deviceId() async {
    final prefs = await _prefs;
    var id = prefs.getString('device_id');
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString('device_id', id);
    }
    return id;
  }

  /// 返回 null 表示成功（或未配置服务器），否则返回错误信息。
  Future<String?> sync() async {
    final url = await serverUrl;
    if (url.isEmpty || _running) return null;
    _running = true;
    try {
      final db = await AppDb.instance.db;
      final prefs = await _prefs;
      final since = prefs.getInt('last_sync') ?? 0;

      final products = await db.query('products', where: 'dirty = 1');
      final movements = await db.query('movements', where: 'synced = 0');
      final sales = await db.query('sales', where: 'synced = 0');

      final resp = await http
          .post(
            Uri.parse('$url/sync'),
            headers: {'content-type': 'application/json', 'authorization': 'Bearer ${await token}'},
            body: jsonEncode({
              'device': await _deviceId(),
              'since': since,
              'products': products,
              'movements': movements,
              'sales': [
                for (final s in sales) {...s, 'items': jsonDecode(s['items'] as String)}
              ],
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return '同步失败：HTTP ${resp.statusCode}';
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;

      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final m in movements) {
          batch.update('movements', {'synced': 1}, where: 'id = ?', whereArgs: [m['id']]);
        }
        for (final s in sales) {
          batch.update('sales', {'synced': 1}, where: 'id = ?', whereArgs: [s['id']]);
        }
        for (final p in products) {
          batch.update('products', {'dirty': 0}, where: 'barcode = ?', whereArgs: [p['barcode']]);
        }
        await batch.commit(noResult: true);

        // 服务器库存 + 本地在同步期间新产生、尚未上传的流水
        for (final p in (data['products'] as List).cast<Map<String, dynamic>>()) {
          final pending = await txn.rawQuery(
              'SELECT COALESCE(SUM(delta),0) AS d FROM movements WHERE barcode = ? AND synced = 0', [p['barcode']]);
          final localStock = (p['stock'] as num).toInt() + (pending.first['d'] as num).toInt();
          await txn.rawInsert('''
            INSERT INTO products(barcode, name, price_cents, stock, dirty) VALUES(?,?,?,?,0)
            ON CONFLICT(barcode) DO UPDATE SET
              name = CASE WHEN products.dirty = 1 THEN products.name ELSE excluded.name END,
              price_cents = CASE WHEN products.dirty = 1 THEN products.price_cents ELSE excluded.price_cents END,
              stock = excluded.stock''', [p['barcode'], p['name'], p['price_cents'], localStock]);
        }
      });
      await prefs.setInt('last_sync', (data['server_time'] as num).toInt());
      return null;
    } catch (e) {
      return '同步失败：$e';
    } finally {
      _running = false;
    }
  }
}
