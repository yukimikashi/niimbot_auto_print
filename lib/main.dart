import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_links/app_links.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  // BLEで見えるアドレス(本体シールのMACとは並びが違う)。
  static const String _b1Mac = '31:08:03:B6:88:2E';

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

  // 1bit/パレット/透過PNGでも正しく印刷できるよう、
  // 「透過は白」「8bit RGB」「400x240」に揃えたPNGへ変換する。
  Uint8List _normalizeImage(Uint8List src) {
    final decoded = img.decodeImage(src);
    if (decoded == null) {
      throw Exception('画像をデコードできませんでした(PNG/JPG/BMPのみ対応)。');
    }
    final flat = img.Image(
      width: decoded.width,
      height: decoded.height,
      numChannels: 3,
    );
    img.fill(flat, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(flat, decoded);
    final resized = img.copyResize(
      flat,
      width: _labelWidthPx,
      height: _labelHeightPx,
      interpolation: img.Interpolation.nearest,
    );
    return Uint8List.fromList(img.encodePng(resized));
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
      final printBytes = _normalizeImage(bytes);
      _setStatus('画像を変換: 元${bytes.length}B → ${printBytes.length}B');

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
          buffer: printBytes,
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

  Future<void> _startBackgroundPrint() async {
    if (!await _requestImagePermission()) return;
    if (!await _requestBluetoothPermission()) return;
    final notification = await Permission.notification.request();
    if (!notification.isGranted && Platform.isAndroid) {
      _setStatus('通知権限が許可されていません。Androidの通知設定を確認してください。');
      return;
    }
    try {
      await const MethodChannel('niimbot/background_control')
          .invokeMethod('start');
      _setStatus('バックグラウンド印刷サービスを開始しました。常駐通知が表示されます。');
    } catch (error) {
      _setStatus('バックグラウンドサービス開始エラー: $error');
    }
  }

  Future<void> _stopBackgroundPrint() async {
    try {
      await const MethodChannel('niimbot/background_control')
          .invokeMethod('stop');
      _setStatus('バックグラウンド印刷サービスを停止しました。');
    } catch (error) {
      _setStatus('サービス停止エラー: $error');
    }
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
            FilledButton.icon(
              onPressed: _startBackgroundPrint,
              icon: const Icon(Icons.play_arrow),
              label: const Text('バックグラウンド印刷を開始'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _stopBackgroundPrint,
              icon: const Icon(Icons.stop),
              label: const Text('バックグラウンド印刷を停止'),
            ),
            const SizedBox(height: 8),
            const Text(
              'MacroDroidはブロードキャストで画像パスを送信します。画面を開かずに印刷します。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

// Separate Flutter engine entry point used by the Android foreground service.
// Permissions are requested in the visible app before the service is started.
@pragma('vm:entry-point')
Future<void> backgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('niimbot/background_print');
  // 本体シールのMAC(03:31:08:B6:88:2E)ではなく、BLEで見えるアドレス。
  const b1BleAddress = '31:08:03:B6:88:2E';
  const labelWidthPx = 400;
  const labelHeightPx = 240;
  bool busy = false;
  String scanInfo = '';

  Future<void> status(String message) async {
    try {
      await channel.invokeMethod('status', message);
    } catch (_) {}
  }

  Future<void> printFile(String path) async {
    if (busy) {
      await status('別の印刷処理中です。今回の指示は待機キューに残ります');
      // The Android service serializes incoming commands; this guard is a final safeguard.
      return;
    }
    busy = true;
    NiimbotBluetoothClient? client;
    try {
      scanInfo = '';
      await status('画像を読み込み中');
      final imageFile = File(path);
      if (!await imageFile.exists()) {
        throw Exception('画像ファイルが見つかりません: $path');
      }
      final bytes = await imageFile.readAsBytes();
      if (bytes.isEmpty) throw Exception('画像ファイルが空です。');
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('画像をデコードできませんでした。');
      final flat = img.Image(
          width: decoded.width, height: decoded.height, numChannels: 3);
      img.fill(flat, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(flat, decoded);
      final resized = img.copyResize(
        flat,
        width: labelWidthPx,
        height: labelHeightPx,
        interpolation: img.Interpolation.nearest,
      );
      final printBytes = Uint8List.fromList(img.encodePng(resized));

      // 「検索 → 接続」を最大 maxAttempts 回まで繰り返す(BLEは初回に失敗しやすい)。
      const maxAttempts = 5;
      Object? lastError;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        // 1回目は検索せず、BLEアドレスで直接接続する(最速)。
        // 2回目以降は検索してから接続し、検索で見つからなければ直接接続する。
        final BluetoothDevice device;
        if (attempt == 1) {
          device = BluetoothDevice.fromId(b1BleAddress);
          scanInfo = '直接接続($attempt/$maxAttempts)';
        } else {
          await status('B1を検索中($attempt/$maxAttempts)');
          List<BluetoothDevice> devices = [];
          try {
            devices = await NiimbotBluetoothClient.listDevices(
              timeout: const Duration(seconds: 6),
            );
          } catch (e) {
            lastError = e;
          }
          if (devices.isEmpty) {
            device = BluetoothDevice.fromId(b1BleAddress);
            scanInfo = '検索0台→直接接続($attempt/$maxAttempts)';
          } else {
            device = devices.first;
            scanInfo = '検索${devices.length}台($attempt/$maxAttempts)';
          }
        }

        await status('B1に接続中($attempt/$maxAttempts) $scanInfo');
        final c = NiimbotBluetoothClient();
        c.setDevice(device);
        try {
          await c.connect().timeout(
                const Duration(seconds: 25),
                onTimeout: () => throw TimeoutException('B1接続がタイムアウトしました。'),
              );
          client = c;
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          try {
            await c.disconnect();
          } catch (_) {}
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      if (client == null) {
        throw Exception('接続失敗($maxAttempts回): $lastError');
      }
      client.stopHeartbeat();
      client.setPacketInterval(0);

      await status('ラベルに印刷中');
      final task = client.createPrintTask(
        PrintOptions(
          totalPages: 1,
          density: 3,
          labelType: LabelType.withGaps,
          statusPollIntervalMs: 100,
          statusTimeoutMs: 8000,
        ),
      );
      if (task == null) throw Exception('プリンタの機種を判別できませんでした。');
      final page = PrintPage(labelWidthPx, labelHeightPx);
      page.addImageFromBuffer(
        ImageFromBufferOptions(
          x: 0,
          y: 0,
          width: labelWidthPx,
          height: labelHeightPx,
          buffer: printBytes,
          threshold: 128,
        ),
      );
      await task.printInit();
      await task.printPage(page.toEncodedImage(), 1);
      await task.waitForFinished();
      await client.abstraction.printEnd();
      await status('印刷完了');
      await channel.invokeMethod('printResult', {
        'success': true,
        'message': '印刷完了：${DateTime.now().toLocal()}',
      });
    } catch (error) {
      await status('印刷エラー[$scanInfo]: $error');
      try {
        await channel.invokeMethod('printResult', {
          'success': false,
          'message': '印刷エラー[$scanInfo]: $error',
        });
      } catch (_) {}
    } finally {
      try {
        await client?.disconnect();
      } catch (_) {}
      busy = false;
    }
  }

  channel.setMethodCallHandler((call) async {
    if (call.method == 'print') {
      final path = call.arguments as String?;
      if (path == null || path.trim().isEmpty) {
        await status('エラー：画像パスが空です');
        return;
      }
      await printFile(path);
    }
  });
  await channel.invokeMethod('ready');
}
