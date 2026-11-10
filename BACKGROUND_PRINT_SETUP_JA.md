# NIIMBOTバックグラウンド印刷の設定

## 仕組み

- アプリ画面から一度「バックグラウンド印刷を開始」を押す
- AndroidのForeground Serviceが常駐通知を表示して待機
- MacroDroidから明示的Broadcastを受け取る
- 常駐サービス内のFlutterEngineが画像を読み込み、NIIMBOT B1へ印刷
- 印刷中もMainActivityは起動しない

## 初回だけ必要な操作

1. アプリをインストールして一度起動する。
2. 写真と動画、付近のデバイス、通知の権限を許可する。
3. B1の電源を入れて、アプリ画面からテスト印刷を成功させる。
4. 「バックグラウンド印刷を開始」を押す。
5. 「NIIMBOT Auto Print / 待機中」の常駐通知が出たことを確認する。
6. ホーム画面に戻る。アプリ画面を開いておく必要はない。

スマートフォン再起動後は、アプリを一度開いて「バックグラウンド印刷を開始」を押し直す。

## MacroDroidの設定

既存の「ファイル更新時」トリガーの後に、画像の書き込み完了を待つため2〜3秒の待機を入れ、その後に「インテントを送信」を追加する。

「インテントを送信」の設定：

| 項目 | 値 |
|---|---|
| インテントの種類 | ブロードキャスト（Broadcast） |
| アクション | `com.example.niimbot_auto_print.PRINT` |
| パッケージ | `com.example.niimbot_auto_print` |
| クラス | `com.example.niimbot_auto_print.PrintCommandReceiver` |
| 追加データ | 文字列 extra `path` |
| extraの値 | `/storage/emulated/0/Pictures/Niimbot/label.png` |

extraの値は、実際にTermuxが上書き保存する画像のフルパスに合わせる。

この方式ではActivityを起動しない。古い `niimbotautoprint://print?path=...` のVIEWインテントではなく、上記のBroadcastを使う。

## 停止方法

アプリを開き、「バックグラウンド印刷を停止」を押す。常駐通知が消える。

## Xiaomi端末での注意

Xiaomiのバッテリー管理でサービスが停止される場合は、アプリ情報からバッテリーセーバーを「制限なし」にする。端末に「自動起動」の設定がある場合は許可する。

Androidの「強制停止」を行うとサービスも止まる。再び使うときはアプリを開いてサービスを開始する。

## ビルド

Flutter SDKが設定された開発環境でプロジェクトを開き、次を実行する。

```bash
flutter clean
flutter pub get
flutter build apk --release
```

`android/local.properties` は開発PCごとのFlutter SDKパスを含むため、この配布ZIPには含めていない。Android Studio/Flutterで開いたときにローカル環境に合わせて生成する。
