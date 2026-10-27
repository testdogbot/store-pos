import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../beep.dart';

/// 处理一次扫码，返回要在相机页底部显示的提示（null 表示忽略）。
typedef ScanHandler = Future<String?> Function(String code);

/// 打开相机扫码：有连续处理函数就连续扫，否则扫一个就返回。
Future<void> openCameraScan(BuildContext context,
    {required ValueChanged<String> onScanned, ScanHandler? onContinuousScan}) async {
  if (onContinuousScan == null) {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => CameraScanPage(onCode: (c) async => c, single: true)),
    );
    if (code != null && code.trim().isNotEmpty) onScanned(code.trim());
    return;
  }
  await Navigator.push(context, MaterialPageRoute(builder: (_) => CameraScanPage(onCode: onContinuousScan)));
}

/// 手动输入条码的小弹窗。
Future<void> manualBarcode(BuildContext context, ValueChanged<String> onScanned) async {
  final c = TextEditingController();
  final code = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('手动输入条码'),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(prefixIcon: Icon(Icons.dialpad), hintText: '条码数字'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('确定')),
      ],
    ),
  );
  if (code != null && code.trim().isNotEmpty) onScanned(code.trim());
}

/// 页面中心的大扫码按钮：点一下打开相机，下面有「手动输入条码」。
class ScanHub extends StatefulWidget {
  final ValueChanged<String> onScanned;
  final ScanHandler? onContinuousScan;
  final String title;
  final String subtitle;
  const ScanHub(
      {super.key, required this.onScanned, this.onContinuousScan, required this.title, required this.subtitle});
  @override
  State<ScanHub> createState() => _ScanHubState();
}

class _ScanHubState extends State<ScanHub> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 220,
            height: 220,
            child: Stack(alignment: Alignment.center, children: [
              AnimatedBuilder(
                animation: _pulse,
                builder: (_, __) {
                  final t = _pulse.value;
                  return Container(
                    width: 150 + 70 * t,
                    height: 150 + 70 * t,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle, color: cs.primary.withValues(alpha: 0.18 * (1 - t))),
                  );
                },
              ),
              Material(
                color: cs.primary,
                shape: const CircleBorder(),
                elevation: 6,
                shadowColor: cs.primary.withValues(alpha: 0.5),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => openCameraScan(context,
                      onScanned: widget.onScanned, onContinuousScan: widget.onContinuousScan),
                  child: SizedBox(
                    width: 150,
                    height: 150,
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.qr_code_scanner, size: 60, color: cs.onPrimary),
                      const SizedBox(height: 6),
                      Text('点击扫码',
                          style: TextStyle(color: cs.onPrimary, fontWeight: FontWeight.w700, fontSize: 16)),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          Text(widget.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(widget.subtitle, style: TextStyle(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => manualBarcode(context, widget.onScanned),
            icon: const Icon(Icons.keyboard_outlined, size: 18),
            label: const Text('手动输入条码'),
          ),
        ]),
      ),
    );
  }
}

/// 列表不为空时顶部的小扫码条。
class ScanBar extends StatelessWidget {
  final ValueChanged<String> onScanned;
  final ScanHandler? onContinuousScan;
  final String label;
  const ScanBar({super.key, required this.onScanned, this.onContinuousScan, this.label = '继续扫码'});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: FilledButton.tonalIcon(
          onPressed: () => openCameraScan(context, onScanned: onScanned, onContinuousScan: onContinuousScan),
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(label),
        ),
      ),
      const SizedBox(width: 8),
      IconButton.filledTonal(
        tooltip: '手动输入条码',
        style: IconButton.styleFrom(minimumSize: const Size(52, 52)),
        onPressed: () => manualBarcode(context, onScanned),
        icon: const Icon(Icons.keyboard_outlined),
      ),
    ]);
  }
}

/// 扫码枪（蓝牙/USB 键盘模式）监听：没有输入框也能接收，收到回车就当一次扫码。
/// 只在本页可见、且没有输入框在打字时生效。
class HardwareScanListener extends StatefulWidget {
  final ValueChanged<String> onCode;
  final Widget child;
  const HardwareScanListener({super.key, required this.onCode, required this.child});
  @override
  State<HardwareScanListener> createState() => _HardwareScanListenerState();
}

class _HardwareScanListenerState extends State<HardwareScanListener> {
  final _buf = StringBuffer();
  DateTime _last = DateTime(2000);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _active() {
    if (!mounted || !TickerMode.valuesOf(context).enabled) return false; // IndexedStack 里不可见
    if (ModalRoute.of(context)?.isCurrent != true) return false; // 上面有弹窗/其他页面
    final f = FocusManager.instance.primaryFocus?.context?.widget;
    if (f is EditableText) return false; // 正在输入框里打字
    return true;
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !_active()) return false;
    final now = DateTime.now();
    if (now.difference(_last) > const Duration(milliseconds: 300)) _buf.clear(); // 太慢的不是扫码枪
    _last = now;
    if (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final code = _buf.toString().trim();
      _buf.clear();
      if (code.isNotEmpty) {
        Beep.play();
        widget.onCode(code);
      }
      return code.isNotEmpty;
    }
    final ch = e.character;
    if (ch != null && ch.length == 1 && ch.codeUnitAt(0) >= 0x20) {
      _buf.write(ch);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 连续扫码页：相机一直开着，每扫到一个条码就处理一次，直到点「完成」。
/// 同一个条码要先移出画面再对准才会再算一次，避免一直对着重复计数。
class CameraScanPage extends StatefulWidget {
  final ScanHandler onCode;
  final bool single; // true：扫到一个条码就关闭并返回它
  const CameraScanPage({super.key, required this.onCode, this.single = false});
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
    if (_busy) return;
    String? code;
    for (final b in capture.barcodes) {
      final v = b.rawValue?.trim();
      if (v == null || v.isEmpty) continue;
      if (!isPlausibleBarcode(v, b.format)) continue; // 校验位不对 = 扫错了，直接丢弃等下一帧
      code = v;
      break;
    }
    if (code == null) return;
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
    Beep.play();
    if (widget.single) {
      Navigator.pop(context, code);
      return;
    }

    try {
      // 不再停开相机（重启相机要近一秒），处理期间靠 _busy 忽略新画面
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
        title: Text(widget.single ? '扫描条码' : '连续扫码（已扫 $_count）'),
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

/// 带相机按钮的条码输入框（商品页「新增商品」弹窗里用）。
class ScanInput extends StatefulWidget {
  final ValueChanged<String> onScanned;
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
    if (code.isNotEmpty) widget.onScanned(code);
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
          tooltip: '摄像头扫码',
          icon: const Icon(Icons.camera_alt),
          onPressed: () => openCameraScan(context, onScanned: _submit, onContinuousScan: widget.onContinuousScan),
        ),
      ),
    );
  }
}


/// 商品条码校验：EAN-13 / EAN-8 / UPC-A 必须校验位正确；UPC-E 只看长度；
/// 其他码制（店内码、二维码）不校验。
bool isPlausibleBarcode(String v, BarcodeFormat f) {
  final digits = RegExp(r'^\d+$').hasMatch(v);
  switch (f) {
    case BarcodeFormat.ean13:
      return digits && v.length == 13 && gtinCheckOk(v);
    case BarcodeFormat.ean8:
      return digits && v.length == 8 && gtinCheckOk(v);
    case BarcodeFormat.upcA:
      return digits && (v.length == 12 || v.length == 13) && gtinCheckOk(v);
    case BarcodeFormat.upcE:
      return digits && (v.length == 6 || v.length == 7 || v.length == 8);
    default:
      if (digits && (v.length == 8 || v.length == 12 || v.length == 13)) return gtinCheckOk(v);
      return true;
  }
}

/// GTIN 通用校验位算法（适用于 8/12/13/14 位）。
bool gtinCheckOk(String v) {
  var sum = 0;
  final body = v.substring(0, v.length - 1);
  for (var i = 0; i < body.length; i++) {
    final d = body.codeUnitAt(body.length - 1 - i) - 48;
    sum += (i % 2 == 0) ? d * 3 : d;
  }
  return (10 - sum % 10) % 10 == v.codeUnitAt(v.length - 1) - 48;
}
