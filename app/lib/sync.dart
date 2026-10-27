import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'admin_api.dart';
import 'db.dart';

/// 与 Cloudflare Worker 同步：推送本地未同步的商品/流水/销售，拉回服务器最新商品。
/// 店员手机只能新增商品；修改、删除要带主账号密码，服务器会拒绝并把正确数据推回来。
class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();
  bool _running = false;

  /// 数据有变化（同步完成、结账、入库）时 +1，页面监听它自动刷新。
  final ValueNotifier<int> changes = ValueNotifier(0);
  /// 同步状态：null=未同步过；lastError 为空表示正常。
  final ValueNotifier<SyncStatus> status = ValueNotifier(const SyncStatus());

  void notifyChanged() => changes.value++;

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

  /// 上传本机新拍的商品图，下载其他手机传上来的图。
  Future<String?> _syncImages(String url, String tk) async {
    final db = await AppDb.instance.db;
    final headers = {'authorization': 'Bearer $tk'};

    final dirty = await db.query('products',
        columns: ['barcode', 'image_path'], where: 'image_dirty = 1 AND image_path IS NOT NULL');
    for (final r in dirty) {
      final barcode = r['barcode'] as String;
      final path = r['image_path'] as String;
      final f = File(path);
      if (!await f.exists()) {
        await db.update('products', {'image_dirty': 0}, where: 'barcode = ?', whereArgs: [barcode]);
        continue;
      }
      final resp = await http
          .put(Uri.parse('$url/images/${Uri.encodeComponent(barcode)}'),
              headers: {...headers, 'content-type': 'image/jpeg'}, body: await f.readAsBytes())
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return '图片上传失败：HTTP ${resp.statusCode}';
      final ver = ((jsonDecode(resp.body) as Map)['image_ver'] as num).toInt();
      // 上传期间如果又换了图，保持 dirty 等下次再传
      await db.rawUpdate(
          'UPDATE products SET image_dirty = 0, image_ver = ?, image_local_ver = ? WHERE barcode = ? AND image_path = ?',
          [ver, ver, barcode, path]);
    }

    final need = await db.query('products',
        columns: ['barcode', 'image_ver'], where: 'image_ver > image_local_ver AND image_dirty = 0', limit: 30);
    for (final r in need) {
      final barcode = r['barcode'] as String;
      final resp = await http
          .get(Uri.parse('$url/images/${Uri.encodeComponent(barcode)}'), headers: headers)
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode == 404) {
        await db.rawUpdate('UPDATE products SET image_local_ver = image_ver WHERE barcode = ?', [barcode]);
        continue;
      }
      if (resp.statusCode != 200) return '图片下载失败：HTTP ${resp.statusCode}';
      final ver = int.tryParse(resp.headers['x-image-ver'] ?? '') ?? (r['image_ver'] as num).toInt();
      await AppDb.instance.saveImageBytes(barcode, resp.bodyBytes, fromServer: true, ver: ver);
    }
    return null;
  }

  /// 条码查商品信息（Worker 缓存 + 公共条码库）。查不到或没网返回 null。
  Future<Map<String, dynamic>?> lookupBarcode(String code) async {
    final url = await serverUrl;
    if (url.isEmpty) return null;
    try {
      final r = await http.get(Uri.parse('$url/lookup/${Uri.encodeComponent(code)}'),
          headers: {'authorization': 'Bearer ${await token}'}).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      return d['found'] == true ? d : null;
    } catch (_) {
      return null;
    }
  }

  /// 下载公共条码库里的商品图片（经 Worker 代理）。
  Future<List<int>?> fetchLookupImage(String imageUrl) async {
    final url = await serverUrl;
    try {
      final r = await http
          .get(Uri.parse('$url/proxy-image?url=${Uri.encodeComponent(imageUrl)}'))
          .timeout(const Duration(seconds: 15));
      return r.statusCode == 200 && r.bodyBytes.isNotEmpty ? r.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }

  /// 手动同步：如果后台同步正在进行，等它结束后再同步一次，保证用的是最新设置。
  Future<String?> syncNow() async {
    while (_running) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if ((await serverUrl).isEmpty) return '未填写服务器地址';
    return sync();
  }

  /// 返回 null 表示成功（或未配置服务器），否则返回错误信息。
  Future<String?> sync() async {
    final url = await serverUrl;
    if (url.isEmpty || _running) return null;
    _running = true;
    status.value = SyncStatus(syncing: true, lastAt: status.value.lastAt, error: status.value.error);
    final err = await _doSync(url);
    _running = false;
    status.value = SyncStatus(lastAt: err == null ? DateTime.now() : status.value.lastAt, error: err);
    notifyChanged();
    return err;
  }

  Future<String?> _doSync(String url) async {
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
            headers: {
              'content-type': 'application/json',
              'authorization': 'Bearer ${await token}',
              if (AdminApi.instance.password != null) 'x-admin-password': AdminApi.instance.password!,
            },
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
            INSERT INTO products(barcode, name, price_cents, stock, dirty, image_ver, deleted) VALUES(?,?,?,?,0,?,?)
            ON CONFLICT(barcode) DO UPDATE SET
              deleted = CASE WHEN products.dirty = 1 THEN products.deleted ELSE excluded.deleted END,
              name = CASE WHEN products.dirty = 1 THEN products.name ELSE excluded.name END,
              price_cents = CASE WHEN products.dirty = 1 THEN products.price_cents ELSE excluded.price_cents END,
              stock = excluded.stock,
              image_ver = MAX(products.image_ver, excluded.image_ver)''',
              [p['barcode'], p['name'], p['price_cents'], localStock, (p['image_ver'] as num?)?.toInt() ?? 0,
               (p['deleted'] as num?)?.toInt() ?? 0]);
        }
      });
      await prefs.setInt('last_sync', (data['server_time'] as num).toInt());
      return await _syncImages(url, await token);
    } catch (e) {
      return '同步失败：$e';
    }
  }
}

class SyncStatus {
  final bool syncing;
  final DateTime? lastAt;
  final String? error;
  const SyncStatus({this.syncing = false, this.lastAt, this.error});
}
