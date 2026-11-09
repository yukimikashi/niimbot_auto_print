import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:niimbot_print/niimbot_print.dart';
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
  final AppLinks _appLinks = AppLinks();
  final NiimbotPrint _printer = NiimbotPrint();

  StreamSubscription<Uri>? _linkSubscription;
  bool _busy = false;
  String _status = '待機中。Termuxから印刷リクエストを受け付けます。';
  String _lastPath = '';

  @override
  void initState() {
    super.initState();
    // app_links は cold start の初回リンクも stream に流すため、
    // getInitialLink() と二重に処理しない。
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

  void _setStatus(String value) {
    if (!mounted) return;
    setState(() => _status = value);
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
    // Android 13/14 の共有ストレージ上の画像を読む権限。
    final status = await Permission.photos.request();
    if (status.isGranted || status.isLimited) return true;
    _setStatus('画像の読み取り権限がありません。アプリ設定で写真と動画へのアクセスを許可してください。');
    return false;
  }

  Future<void> _printFile(String path) async {
    if (_busy) {
      _setStatus('別の印刷処理が実行中です。少し待ってから再送してください。');
      return;
    }
    _busy = true;
    _lastPath = path;
    try {
      _setStatus('画像を確認中: $path');

      if (!await _requestImagePermission()) return;

      final imageFile = File(path);
      if (!await imageFile.exists()) {
        throw Exception('画像ファイルが見つかりません: $path');
      }
      final length = await imageFile.length();
      if (length == 0) throw Exception('画像ファイルが空です。');

      _setStatus('NIIMBOT B1を検索中...');

      final devices = await _printer.onStartScan(
        // 検索時間を15秒に延長
        scanDuration: const Duration(seconds: 15),

        // whiteListDevicesを指定しない
        // 周囲のBluetooth機器を広く検索する

        onError: (message) {
          _setStatus('Bluetooth検索エラー: $message');
        },
      );

// 検出した機器をすべてログに表示
      if (devices.isEmpty) {
        throw Exception('Bluetooth機器が1台も検出されませんでした。'
            '権限・Bluetooth設定を確認してください。');
      }

      _setStatus('Bluetooth機器を${devices.length}台検出しました。\n'
          '${devices.map((d) => d.toString()).join('\n')}');

      if (devices.isEmpty) {
        throw Exception('B1が見つかりません。電源・Bluetooth・プリンターとの距離を確認してください。');
      }

      _setStatus('B1に接続中...');
      final connectCompleter = Completer<bool>();
      await _printer.onStartConnect(
        model: devices.first,
        onResult: (isSuccess, message) {
          if (!connectCompleter.isCompleted) {
            if (isSuccess) {
              _setStatus('B1接続成功: $message');
              connectCompleter.complete(true);
            } else {
              connectCompleter.completeError(Exception('B1接続失敗: $message'));
            }
          }
        },
      );
      final connected = await connectCompleter.future.timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw TimeoutException('B1接続がタイムアウトしました。'),
      );
      if (!connected) throw Exception('B1に接続できませんでした。');

      _setStatus('50×30mmラベルに印刷中...');
      // B1の印字ヘッドは384dot幅。50mm媒体の左右に約1mmずつ余白を取り、
      // 48×28.8mmの枠に画像を収める。元画像は縦横比を保って作成すること。
      final imageElement = await NiimbotImageElement.fromFile(
        path: path,
        frame: const NiimbotRect(
          x: 1,
          y: 0.6,
          width: 48,
          height: 28.8,
        ),
      );

      final printCompleter = Completer<void>();
      await _printer.onStartPrint(
        layout: const NiimbotLabelLayout(
          size: NiimbotLabelSize.mm50x30,
          orientation: NiimbotLabelOrientation.landscape,
          padding: 1,
        ),
        elements: [imageElement],
        onError: (error) {
          if (!printCompleter.isCompleted) {
            printCompleter.completeError(
              Exception('印刷データエラー ${error.code}: ${error.message}'),
            );
          }
        },
        onResult: (isSuccess, message) {
          if (!printCompleter.isCompleted) {
            if (isSuccess) {
              printCompleter.complete();
            } else {
              printCompleter.completeError(Exception('印刷失敗: $message'));
            }
          }
        },
      );

      await printCompleter.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () => throw TimeoutException('印刷完了の応答がありません。'),
      );
      _setStatus('印刷完了: $path');
    } catch (error) {
      _setStatus('印刷エラー: $error');
    } finally {
      try {
        await _printer.onDisconnect();
      } catch (_) {
        // 印刷失敗時の切断エラーは元のエラー表示を上書きしない。
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
            SelectableText(_status),
            const SizedBox(height: 12),
            if (_lastPath.isNotEmpty) SelectableText('直近の画像: $_lastPath'),
            const Spacer(),
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
