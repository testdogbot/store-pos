import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sync.dart';

/// 主账号（老板）接口：营业额查看与修改。密码只保存在内存里，退出 App 就要重新输入。
class AdminApi {
  AdminApi._();
  static final AdminApi instance = AdminApi._();
  String? password;

  Future<Map<String, String>> _headers() async => {
        'authorization': 'Bearer ${await SyncService.instance.token}',
        'content-type': 'application/json',
        if (password != null) 'x-admin-password': password!,
      };

  Future<Map<String, dynamic>> _call(String method, String path, [Object? body]) async {
    final url = Uri.parse('${await SyncService.instance.serverUrl}$path');
    final h = await _headers();
    late http.Response r;
    final b = body == null ? null : jsonEncode(body);
    switch (method) {
      case 'GET':
        r = await http.get(url, headers: h).timeout(const Duration(seconds: 15));
      case 'POST':
        r = await http.post(url, headers: h, body: b).timeout(const Duration(seconds: 15));
      case 'PUT':
        r = await http.put(url, headers: h, body: b).timeout(const Duration(seconds: 15));
      default:
        r = await http.delete(url, headers: h).timeout(const Duration(seconds: 15));
    }
    final data = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    if (r.statusCode == 401) throw AdminError('店铺口令不对，请先在设置里填写正确的口令');
    if (r.statusCode != 200) throw AdminError('${data['error'] ?? 'HTTP ${r.statusCode}'}');
    return data;
  }

  Future<bool> hasAdmin() async => (await _call('GET', '/admin/status'))['has_admin'] == true;
  Future<void> setup(String pw) async {
    await _call('POST', '/admin/setup', {'password': pw});
    password = pw;
  }

  Future<void> login(String pw) async {
    password = pw;
    try {
      await _call('GET', '/admin/login');
    } catch (_) {
      password = null;
      rethrow;
    }
  }

  Future<void> changePassword(String pw) async {
    await _call('POST', '/admin/password', {'password': pw});
    password = pw;
  }

  /// 条码查询 Key（ApiZero）：返回 null 表示未设置，否则返回末 4 位
  Future<String?> apizeroTail() async {
    final d = await _call('GET', '/admin/apizero');
    return d['has_key'] == true ? (d['tail'] as String? ?? '****') : null;
  }

  Future<String?> setApizeroKey(String key) async {
    final d = await _call('POST', '/admin/apizero', {'key': key});
    return d['has_key'] == true ? d['tail'] as String? : null;
  }

  Future<List<DaySummary>> summary(int days) async {
    final d = await _call('GET', '/admin/summary?days=$days');
    return [
      for (final x in (d['days'] as List).cast<Map<String, dynamic>>())
        DaySummary(DateTime.fromMillisecondsSinceEpoch((x['start'] as num).toInt()), (x['count'] as num).toInt(),
            (x['total_cents'] as num).toInt())
    ];
  }

  Future<List<SaleRecord>> sales(DateTime from, DateTime to) async {
    final d = await _call(
        'GET', '/admin/sales?from=${from.millisecondsSinceEpoch}&to=${to.millisecondsSinceEpoch}');
    return [for (final x in (d['sales'] as List).cast<Map<String, dynamic>>()) SaleRecord.fromJson(x)];
  }

  Future<void> editSale(String id, int totalCents, String note) =>
      _call('PUT', '/admin/sales/${Uri.encodeComponent(id)}', {'total_cents': totalCents, 'note': note});
  Future<void> deleteSale(String id, {bool restock = false}) =>
      _call('DELETE', '/admin/sales/${Uri.encodeComponent(id)}${restock ? '?restock=1' : ''}');
  Future<void> addSale(int totalCents, String note, DateTime at) =>
      _call('POST', '/admin/sales', {'total_cents': totalCents, 'note': note, 'created_at': at.millisecondsSinceEpoch});
}

class AdminError implements Exception {
  final String message;
  AdminError(this.message);
  @override
  String toString() => message;
}

class DaySummary {
  final DateTime start;
  final int count;
  final int totalCents;
  DaySummary(this.start, this.count, this.totalCents);
}

class SaleRecord {
  final String id;
  final int totalCents;
  final int? originalTotalCents;
  final List<Map<String, dynamic>> items;
  final DateTime at;
  final String? note;
  final String? device;
  SaleRecord.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        totalCents = (j['total_cents'] as num).toInt(),
        originalTotalCents = (j['original_total_cents'] as num?)?.toInt(),
        items = (j['items'] as List).cast<Map<String, dynamic>>(),
        at = DateTime.fromMillisecondsSinceEpoch((j['created_at'] as num).toInt()),
        note = j['note'] as String?,
        device = j['device'] as String?;

  String get summary {
    if (items.isEmpty) return note?.isNotEmpty == true ? note! : '手动记账';
    final first = items.take(2).map((i) => '${i['name']}×${i['qty']}').join('、');
    final n = items.fold<int>(0, (s, i) => s + ((i['qty'] as num?)?.toInt() ?? 0));
    return items.length > 2 ? '$first 等 $n 件' : first;
  }
}
