import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 处理一次扫码，返回要在相机页底部显示的提示（null 表示忽略）。
typedef ScanHandler = Future<String?> Function(String code);

/// 扫码输入：蓝牙/USB 扫码枪直接输入并回车；点相机图标进入手机摄像头【连续扫码】。
class ScanInput extends StatefulWidget {
  final ValueChanged<String> onScanned;

  /// 连续扫码时每个条码的处理函数；不传则用 onScanned。
  final ScanHandler? onContinuousScan;
  final String hint;
  const ScanInput({super.key, required this.onScanned, this.onContinuousScan, this.hint = '扫码或输入条码'});

  @override
  State<ScanInput> createState() => _ScanInputState();
}

class _ScanInputState extends State<ScanInput> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  void _submit(String v) {
    final code = v.trim();
    _ctrl.clear();
    _focus.requestFocus();
    if (code.isNotEmpty) widget.onScanned(code);
  }

  Future<void> _openCamera() async {
    final handler = widget.onContinuousScan ??
        (code) async {
          widget.onScanned(code);
          return '已扫描 $code';
        };
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CameraScanPage(onCode: handler)),
    );
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      focusNode: _focus,
      autofocus: true,
      textInputAction: TextInputAction.done,
      onSubmitted: _submit,
      decoration: InputDecoration(
        hintText: widget.hint,
        prefixIcon: const Icon(Icons.qr_code_scanner),
        suffixIcon: IconButton(
          tooltip: '摄像头连续扫码',
          icon: const Icon(Icons.camera_alt),
          onPressed: _openCamera,
        ),
        border: const OutlineInputBorder(),
      ),
    );
  }
}

/// 连续扫码页：相机一直开着，每扫到一个条码就处理一次，直到点「完成」。
/// 同一个条码要先移出画面再对准才会再算一次，避免一直对着重复计数。
class CameraScanPage extends StatefulWidget {
  final ScanHandler onCode;
  const CameraScanPage({super.key, required this.onCode});
  @override
  State<CameraScanPage> createState() => _CameraScanPageState();
}

class _CameraScanPageState extends State<CameraScanPage> {
  final _controller = MobileScannerController(formats: const [
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.upcA,
    BarcodeFormat.upcE,
    BarcodeFormat.code128,
    BarcodeFormat.code39,
    BarcodeFormat.qrCode,
  ]);

  bool _busy = false;
  String? _lastCode;
  DateTime _lastSeen = DateTime(2000);
  DateTime _lastAccepted = DateTime(2000);
  int _count = 0;
  String _message = '对准商品条码，扫到会“嘀”一声并自动累加';
  bool _flash = false;

  static const _goneGap = Duration(milliseconds: 700); // 条码离开画面多久算“移开了”
  static const _minRepeat = Duration(milliseconds: 1200); // 同码两次计数最短间隔

  Future<void> _onDetect(BarcodeCapture capture) async {
    final code = capture.barcodes.firstOrNull?.rawValue?.trim();
    if (code == null || code.isEmpty) return;
    final now = DateTime.now();

    if (code == _lastCode) {
      final moved = now.difference(_lastSeen) > _goneGap;
      final waited = now.difference(_lastAccepted) > _minRepeat;
      _lastSeen = now;
      if (!(moved && waited)) return;
    }
    if (_busy) return;

    _busy = true;
    _lastCode = code;
    _lastSeen = now;
    _lastAccepted = now;
    HapticFeedback.mediumImpact();
    SystemSound.play(SystemSoundType.click);

    try {
      // 处理期间暂停相机（比如新商品要弹出建档表单）
      await _controller.stop();
      final msg = await widget.onCode(code);
      if (!mounted) return;
      setState(() {
        if (msg != null) {
          _count++;
          _message = msg;
          _flash = true;
        }
      });
      Future.delayed(const Duration(milliseconds: 250), () {
        if (mounted) setState(() => _flash = false);
      });
    } finally {
      _lastSeen = DateTime.now();
      if (mounted) await _controller.start();
      _busy = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('连续扫码（已扫 $_count）'),
        actions: [
          IconButton(icon: const Icon(Icons.flashlight_on), onPressed: () => _controller.toggleTorch()),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成')),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: Stack(fit: StackFit.expand, children: [
            MobileScanner(controller: _controller, onDetect: _onDetect),
            Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 280,
                height: 160,
                decoration: BoxDecoration(
                  border: Border.all(color: _flash ? Colors.greenAccent : Colors.white70, width: _flash ? 5 : 2),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ]),
        ),
        SafeArea(
          top: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: _flash ? Colors.green.shade100 : Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(_message, style: const TextStyle(fontSize: 20), textAlign: TextAlign.center),
          ),
        ),
      ]),
    );
  }
}
