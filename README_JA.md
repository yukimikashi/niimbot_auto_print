# Niimbot Auto Print（Android 14 / B1 / 50×30mm）

Termuxで作成したPNGファイルを、カスタムURLで受け取り、NIIMBOT B1へ自動印刷するFlutterアプリのソースです。

## 重要な前提

- `niimbot_print` 0.3.2 を使用。pub.dev記載ではFlutter 3.44以上が必要です。
- 実機のAndroid 14でBluetooth印刷テストが必要です。
- このソース一式はAPKではありません。Flutter SDKを使ってAPKをビルドします。
- 50×30mm媒体の印刷枠は48×28.8mm（左右約1mm、上下0.6mm余白）です。B1の384dot幅に合わせた初期値です。実機で位置と濃度を調整してください。

## 1. Flutterプロジェクトを作成

Flutter 3.44以上をインストールしたPC、またはGitHub Codespaces等で実行します。

```bash
flutter create --platforms=android --org jp.example --project-name niimbot_auto_print niimbot_auto_print
```

このZIP内の `pubspec.yaml`、`lib/main.dart`、`android/app/src/main/AndroidManifest.xml` を、生成された同名ファイルに上書きします。

プロジェクト直下で実行：

```bash
flutter pub get
flutter build apk --release
```

APKは次に生成されます：

```text
build/app/outputs/flutter-apk/app-release.apk
```

## 2. Android側の準備

1. APKをAndroid 14端末にインストール。
2. 初回起動して「写真と動画」へのアクセスを許可（可能ならすべての写真へのアクセス）。
3. B1の電源を入れ、端末のBluetoothをON。
4. アプリ画面の「テスト印刷」を押して接続・印刷を確認。

アプリは印刷時にB1を検索し、最初に見つかったB1へ接続します。公式アプリとのペアリング状態だけで接続が保証されるわけではありません。

## 3. Termux側の準備

Termuxで共有ストレージを有効化：

```bash
termux-setup-storage
mkdir -p ~/storage/shared/Pictures/Niimbot
```

PNGは次に保存してください：

```text
/storage/emulated/0/Pictures/Niimbot/label.png
```

画像は50×30mmの比率（5:3）で作成するのがおすすめです。印刷時に48×28.8mmの領域に縮小して配置します。

## 4. MacroDroid / Termuxから起動

MacroDroidからTermuxのコマンド実行を呼び出し、次を実行します：

```bash
am start -a android.intent.action.VIEW \
  -d 'niimbotautoprint://print?path=/storage/emulated/0/Pictures/Niimbot/label.png'
```

ファイル名に空白、日本語、`&`、`#`、`?` が入る場合はURLエンコードしてください。まずは固定ファイル名 `label.png` で動作確認してください。

Termuxから直接試す場合：

```bash
am start -a android.intent.action.VIEW -d 'niimbotautoprint://print?path=/storage/emulated/0/Pictures/Niimbot/label.png'
```

## 5. 動作の流れ

1. `niimbotautoprint://print?path=...` を受信
2. PNGファイルの存在・読み取り権限を確認
3. BluetoothでB1を7秒検索
4. 最初に見つかったB1に接続
5. 50×30mmレイアウトに画像を配置
6. 印刷し、画面に結果を表示
7. Bluetooth切断

## 注意点・制限

- この初期版は「最初に検出したB1」を選択します。周囲にB1が複数ある環境では選択ロジックの追加が必要です。
- 印刷完了通知はアプリ画面内に表示します。Termuxへ結果を返す仕組みはまだ実装していません。
- MacroDroidからの連続呼び出しは、前の印刷が終わってから行ってください。
- Android 14の省電力設定やバックグラウンド制限で処理が止まる場合は、アプリのバッテリー最適化を解除してください。
- `niimbot_print` は公式NIIMBOTアプリではなく、サードパーティー製Flutterプラグインです。実機での確認が必要です。


## 6. GitHub ActionsでAPKを作る場合

1. このフォルダの中身を、自分のGitHubリポジトリへアップロード。
2. GitHubの **Actions** タブを開く。
3. **Build Android APK** を選び、**Run workflow** を実行。
4. 完了後、実行結果の **Artifacts** から `niimbot-auto-print-apk` をダウンロード。
5. ZIPを展開し、中の `app-release.apk` をAndroid 14端末へ転送してインストール。

このワークフローはFlutter Androidプロジェクトの土台を生成してから、このソースを配置してビルドします。
