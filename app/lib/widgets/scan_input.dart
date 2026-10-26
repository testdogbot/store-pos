import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 扫码输入：蓝牙/USB 扫码枪直接输入并回车；也可点相机图标用手机摄像头扫。
class ScanInput extends StatefulWidget {
  final ValueChanged<String> onScanned;
  final String hint;
  const ScanInput({super.key, required this.onScanned, this.hint = '扫码或输入条码'});

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
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const CameraScanPage()),
    );
    if (code != null) _submit(code);
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
        suffixIcon: IconButton(icon: const Icon(Icons.camera_alt), onPressed: _openCamera),
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class CameraScanPage extends StatefulWidget {
  const CameraScanPage({super.key});
  @override
  State<CameraScanPage> createState() => _CameraScanPageState();
}

class _CameraScanPageState extends State<CameraScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('对准条码')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          final code = capture.barcodes.firstOrNull?.rawValue;
          if (code == null) return;
          _done = true;
          Navigator.pop(context, code);
        },
      ),
    );
  }
}
