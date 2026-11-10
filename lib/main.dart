import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;
import 'package:niim_blue_flutter/niim_blue_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NiimbotAutoPrintApp());
}

class NiimbotAutoPrintApp extends StatelessWidget {
  const NiimbotAutoPrintApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Niimbot Auto Print',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const PrintHomePage(),
    );
  }
}

class PrintHomePage extends StatefulWidget {
  const PrintHomePage({super.key});

  @override
  State<PrintHomePage> createState() => _PrintHomePageState();
}

class _PrintHomePageState extends State<PrintHomePage> {
  // B1のMACアドレス。スキャンで見つからない場合はこれで直接接続する。
  static const String _b1Mac = '03:31:08:B6:88:2E';

  // 50x30mm @203dpi
  static const int _labelWidthPx = 400;
  static const int _labelHeightPx = 240;

  final AppLinks _appLinks = AppLinks();

  StreamSubscription<Uri>? _linkSubscription;
  bool _busy = false;
  final List<String> _lines = ['待機中。Termuxから印刷リクエストを受け付けます。'];
  String _lastPath = '';

  @override
  void initState() {
    super.initState();
    _linkSubscription = _appLinks.uriLinkStream.listen(
      _handleIncomingUri,
      onError: (Object error) => _setStatus('リンク受信エラー: $error'),
    );
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  // 経過を上書きせず積み上げて表示する(エラー時も検出台数などが残る)。
  void _setStatus(String value) {
    if (!mounted) return;
    setState(() {
      _lines.add(value);
      if (_lines.length > 30) _lines.removeAt(0);
    });
  }

  Future<void> _handleIncomingUri(Uri uri) async {
    if (uri.scheme != 'niimbotautoprint' || uri.host != 'print') return;
    final path = uri.queryParameters['path'];
    if (path == null || path.trim().isEmpty) {
      _setStatus('エラー: path パラメータがありません。');
      return;
    }
    await _printFile(path);
  }

  Future<bool> _requestImagePermission() async {
    final status = await Permission.photos.request();
    if (status.isGranted || status.isLimited) return true;
    _setStatus('画像の読み取り権限がありません。アプリ設定で写真と動画へのアクセスを許可してください。');
    return false;
  }

  Future<bool> _requestBluetoothPermission() async {
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final scan = results[Permission.bluetoothScan]?.isGranted ?? false;
    final connect = results[Permission.bluetoothConnect]?.isGranted ?? false;
    if (scan && connect) return true;
    _setStatus('Bluetooth権限(付近のデバイス)がありません。'
        'アプリ設定 > 権限 > 付近のデバイス を許可してください。');
    return false;
  }

  Future<void> _printFile(String path) async {
    if (_busy) {
      _setStatus('別の印刷処理が実行中です。少し待ってから再送してください。');
      return;
    }
    _busy = true;
    _lastPath = path;
    NiimbotBluetoothClient? client;
    try {
      _setStatus('画像を確認中: $path');

      if (!await _requestImagePermission()) return;
      if (!await _requestBluetoothPermission()) return;

      final imageFile = File(path);
      if (!await imageFile.exists()) {
        throw Exception('画像ファイルが見つかりません: $path');
      }
      final bytes = await imageFile.readAsBytes();
      if (bytes.isEmpty) throw Exception('画像ファイルが空です。');

      // --- BLEで検索 ---
      _setStatus('NIIMBOT B1をBLEで検索中...');
      List<BluetoothDevice> devices = [];
      try {
        devices = await NiimbotBluetoothClient.listDevices(
          timeout: const Duration(seconds: 8),
        );
      } catch (e) {
        _setStatus('検索で例外: $e');
      }
      _setStatus('NIIMBOT機器を${devices.length}台検出'
          '${devices.isEmpty ? '' : '\n${devices.map((d) => '${d.platformName} ${d.remoteId.str}').join('\n')}'}');

      // MAC一致を優先 → 無ければ先頭 → 無ければMAC直指定
      final BluetoothDevice device = devices.firstWhere(
        (d) => d.remoteId.str.toUpperCase() == _b1Mac,
        orElse: () =>
            devices.isNotEmpty ? devices.first : BluetoothDevice.fromId(_b1Mac),
      );

      // --- 接続 ---
      _setStatus('B1に接続中: ${device.remoteId.str}');
      client = NiimbotBluetoothClient();
      client.setDevice(device);
      await client.connect().timeout(
            const Duration(seconds: 25),
            onTimeout: () => throw TimeoutException('B1接続がタイムアウトしました。'),
          );
      _setStatus('B1接続成功');

      client.stopHeartbeat();
      client.setPacketInterval(0);

      // --- 印刷 ---
      _setStatus('50×30mmラベルに印刷中...');
      final task = client.createPrintTask(
        PrintOptions(
          totalPages: 1,
          density: 3,
          labelType: LabelType.withGaps,
          statusPollIntervalMs: 100,
          statusTimeoutMs: 8000,
        ),
      );
      if (task == null) {
        throw Exception('プリンタの機種を判別できませんでした。');
      }

      // 元画像は 5:3(例: 400x240)で作成すること。
      final page = PrintPage(_labelWidthPx, _labelHeightPx);
      page.addImageFromBuffer(
        ImageFromBufferOptions(
          x: 0,
          y: 0,
          width: _labelWidthPx,
          height: _labelHeightPx,
          buffer: bytes,
          threshold: 128,
        ),
      );

      await task.printInit();
      await task.printPage(page.toEncodedImage(), 1);
      await task.waitForFinished();
      await client.abstraction.printEnd();
      _setStatus('印刷完了: $path');
    } catch (error) {
      _setStatus('印刷エラー: $error');
    } finally {
      try {
        await client?.disconnect();
      } catch (_) {
        // 切断エラーは元のエラー表示を上書きしない。
      }
      _busy = false;
    }
  }

  Future<void> _testPrint() async {
    const path = '/storage/emulated/0/Pictures/Niimbot/label.png';
    await _printFile(path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Niimbot Auto Print')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.print, size: 64),
            const SizedBox(height: 16),
            const Text(
              'NIIMBOT B1 / 50 × 30 mm',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(_lines.join('\n')),
              ),
            ),
            const SizedBox(height: 12),
            if (_lastPath.isNotEmpty) SelectableText('直近の画像: $_lastPath'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _testPrint,
              icon: const Icon(Icons.science),
              label: const Text('テスト印刷'),
            ),
            const SizedBox(height: 8),
            const Text(
              '通常はMacroDroidから niimbotautoprint://print?path=... を送ると自動印刷します。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
