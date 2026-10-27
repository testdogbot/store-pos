import 'dart:async';

import 'package:flutter/material.dart';

import 'admin_api.dart';
import 'pages/checkout_page.dart';
import 'pages/products_page.dart';
import 'pages/settings_page.dart';
import 'sync.dart';
import 'theme.dart';
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
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
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
    AdminApi.instance.loadSaved().whenComplete(SyncService.instance.sync);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) checkForUpdate(context, silent: true);
      });
      // 首次使用还没填口令：自动打开设置
      SyncService.instance.token.then((t) {
        if (t.isEmpty && mounted) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage(firstRun: true)));
        }
      });
    });
    // 每分钟后台同步一次，拿到其他收银机的商品和价格变化
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => SyncService.instance.sync());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const pages = [CheckoutPage(), ProductsPage()];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.point_of_sale_outlined), selectedIcon: Icon(Icons.point_of_sale), label: '收银'),
          NavigationDestination(
              icon: Icon(Icons.category_outlined), selectedIcon: Icon(Icons.category), label: '商品'),
        ],
      ),
    );
  }
}
