import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'sync.dart';

/// 主账号（老板）接口：营业额查看与修改、删除/修改商品。
/// 默认密码只在内存里；勾选“这台是老板手机”后记在本机，店员手机不记。
class AdminApi {
  AdminApi._();
  static final AdminApi instance = AdminApi._();
  String? password;

  bool get isAdmin => password != null;

  /// 启动时读取本机记住的主账号密码。
  Future<void> loadSaved() async {
    password ??= (await SharedPreferences.getInstance()).getString('admin_pw');
  }

  Future<bool> get remembered async => (await SharedPreferences.getInstance()).containsKey('admin_pw');

  Future<void> remember(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    if (on && password != null) {
      await prefs.setString('admin_pw', password!);
    } else {
      await prefs.remove('admin_pw');
    }
  }

  /// 退出主账号：本机变回店员。
  Future<void> logout() async {
    password = null;
    await (await SharedPreferences.getInstance()).remove('admin_pw');
  }

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
    if (await remembered) await remember(true);
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
  /// 一键补图：服务器分批给没图的商品找图，返回补上的数量和仍缺图的条码。
  Future<({int filled, List<String> missed})> backfillImages({void Function(int filled, int remaining)? onProgress}) async {
    var filled = 0;
    final missed = <String>[];
    String? after = '';
    while (after != null) {
      final d = await _call('POST', '/admin/backfill-images?limit=8&after=${Uri.encodeComponent(after)}');
      filled += (d['filled'] as num).toInt();
      missed.addAll((d['missed'] as List).cast<String>());
      after = d['next'] as String?;
      onProgress?.call(filled, (d['remaining'] as num).toInt());
    }
    return (filled: filled, missed: missed);
  }

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
