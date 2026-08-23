# KotodamaVoice

KotodamaVoiceは、音声の取得、文字起こし、文章整形、出力をMac上で処理するローカルファーストの音声入力アプリです。
メニューバーに常駐し、権限を増やさず登録できるグローバルショートカットから操作します。

推論Runtimeはアプリ本体へ直接リンクせず、Speech WorkerとFormatter WorkerのXPC Serviceへ分離します。
アプリとWorkerはversion付きのsecure coding契約とrequest IDを使って通信します。

## 動作環境

- Apple Silicon Mac
- macOS 14以降
- Xcode 26
- XcodeGen
- CMake
- App Group `group.jp.tsuyuki.KotodamaVoice`を利用できるApple Developer Team

## セットアップ

```sh
brew install xcodegen cmake
./Scripts/build-runtime-xcframeworks.sh
xcodegen generate
open KotodamaVoice.xcodeproj
```

XcodeのSigning & CapabilitiesでTeam `B7VP34NYD2`の有効なアカウントとprovisioning profileが解決されると、App、Speech Worker、Formatter WorkerをApp Group付きで実行できます。

## テスト

CoreのUnit Testは署名なしで実行できます。

```sh
xcodebuild \
  -project KotodamaVoice.xcodeproj \
  -scheme KotodamaCore \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

アプリのUnit Testには`KotodamaVoiceUnitTests` schemeを使用します。
UI Testと実プロセス間XPC Testには、App Groupを含む署名済みbuildが必要です。

## 構成

- `Sources/KotodamaCore`: 状態機械、XPC契約、接続管理、Manifest検証
- `Sources/KotodamaVoice`: メニューバーUI、設定、macOS API adapter
- `Sources/SpeechWorker`: whisper.cppを保持するXPC Service
- `Sources/FormatterWorker`: llama.cppを保持するXPC Service
- `Resources/Models.json`: revision、size、SHA-256を固定したモデル候補
- `Config/runtime-lock.json`: 推論Runtimeの固定revisionと生成物hash
- `openspec/changes/deliver-local-voice-input-v1`: V1の仕様、設計、実装タスク
