import 'dart:async';

import 'package:flutter/material.dart';

import 'pages/checkout_page.dart';
import 'pages/products_page.dart';
import 'pages/settings_page.dart';
import 'pages/stock_in_page.dart';
import 'sync.dart';
import 'update_check.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const StorePosApp());
}

class StorePosApp extends StatelessWidget {
  const StorePosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '小店收银',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    SyncService.instance.sync();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) checkForUpdate(context, silent: true);
      });
    });
    // 每分钟后台同步一次，拿到其他收银机的库存变化
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => SyncService.instance.sync());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const pages = [CheckoutPage(), StockInPage(), ProductsPage(), SettingsPage()];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.point_of_sale), label: '收银'),
          NavigationDestination(icon: Icon(Icons.inventory), label: '入库'),
          NavigationDestination(icon: Icon(Icons.list_alt), label: '商品'),
          NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}
