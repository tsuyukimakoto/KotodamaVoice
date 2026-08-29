# KotodamaVoiceの構成と開発環境

この文書は、KotodamaVoiceのソースコードを参照またはビルドする開発者向けに、現在の構成と開発環境を説明します。
アプリの使い方とデータの扱いは[README.md](README.md)を参照してください。

## 動作環境と開発ツール

- Apple Silicon Mac
- macOS 14以降
- Xcode 26
- XcodeGen
- CMake
- App Groupを利用できるApple Developer Team

XcodeGenとCMakeはHomebrewから導入できます。

```sh
brew install xcodegen cmake
```

## ソースコードの構成

- `Sources/KotodamaCore`：状態機械、XPC契約、接続管理、Manifest検証
- `Sources/KotodamaVoice`：メニューバーUI、設定、録音、出力、macOS APIとの接続
- `Sources/SpeechWorker`：whisper.cppを使って文字起こしを実行するXPC Service
- `Sources/FormatterWorker`：llama.cppを使って文章整形を実行するXPC Service
- `Tools`：SpeechモデルとFormatterモデルの評価用コマンド
- `Tests`：Core、App、Worker、UIのテスト
- `Resources/Models.json`：モデルの版、容量、取得元、SHA-256、ライセンス
- `Resources/ThirdPartyComponents.json`：第三者成果物、固定revision、ライセンス文書、配布対象範囲
- `Licenses`：第三者ライセンスの追跡対象原文
- `LICENSE`：KotodamaVoice本体のMIT License
- `THIRD_PARTY_NOTICES.md`：第三者成果物の用途、取得元、固定revision、ライセンス索引
- `Resources/FormattingPrompt-v1.json`：内蔵Formatterで使用する版付きPrompt
- `Config/runtime-lock.json`：推論Runtimeの固定revisionと生成物のhash
- `Scripts`：Runtime生成、fixture準備、配布物の作成と検証
- `openspec`：現在の仕様、設計、実装タスク

## 実行時の構成

アプリ本体は、録音、設定、モデル管理、処理の進行、出力を担当します。
文字起こしと文章整形は、それぞれ別のXPC Serviceで実行します。

Speech Workerだけがwhisper.cppを保持し、Formatter Workerだけがllama.cppを保持します。
アプリ本体と`KotodamaCore`は、これらの推論Runtimeへ直接リンクしません。

アプリとWorkerは、版付きのsecure coding契約とrequest IDを使って通信します。
モデルはApp Group containerで共有し、Workerをまたぐ処理と障害をrequest IDで追跡します。
診断ログには音声や本文を記録しません。

## Xcodeプロジェクトの生成

推論Runtimeを固定revisionからXCFrameworkとして生成した後、XcodeGenでプロジェクトを生成します。

```sh
./Scripts/build-runtime-xcframeworks.sh
xcodegen generate
open KotodamaVoice.xcodeproj
```

`KotodamaVoice.xcodeproj`は`project.yml`から生成されます。
Targetやビルド設定を変更する場合は、生成後のプロジェクトだけを編集せず、`project.yml`へ反映してから再生成します。

## 別のApple Developer Teamでビルドする

現在の署名設定、Bundle Identifier、App Groupは、このリポジトリのDeveloper Teamに合わせてあります。
別のDeveloper Teamでは、そのTeamが所有できる識別子へ置き換える必要があります。

1. `project.yml`の`DEVELOPMENT_TEAM`を使用するTeam IDへ変更する
2. `project.yml`のBundle Identifierを使用するTeamで登録可能な値へ変更する
3. `project.yml`、entitlements、App Group containerを参照するSwiftコードのApp Group識別子を変更する
4. Developer PortalでApp Groupを登録し、App、Speech Worker、Formatter Workerから利用できるようにする
5. 直接配布を行う場合は`Config/DeveloperIDExportOptions.plist`の`teamID`も変更する
6. `xcodegen generate`を実行してXcodeプロジェクトを再生成する
7. XcodeのSigning & Capabilitiesで、すべての実行Targetに署名とApp Groupが解決されていることを確認する

置換対象は次のコマンドで確認できます。

```sh
rg 'B7VP34NYD2|group\.jp\.tsuyuki\.KotodamaVoice|jp\.tsuyuki\.KotodamaVoice'
```

Team ID自体は秘密鍵ではありません。
証明書の秘密鍵、App用パスワード、API Key、認証トークンはリポジトリへ保存しません。

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

```sh
xcodebuild \
  -project KotodamaVoice.xcodeproj \
  -scheme KotodamaVoiceUnitTests \
  -destination 'platform=macOS' \
  test
```

UI Testと実プロセス間のXPC Testには、App Groupを含む署名済みbuildが必要です。
全テストTargetの実行には`KotodamaVoice` schemeを使用します。

```sh
xcodebuild \
  -project KotodamaVoice.xcodeproj \
  -scheme KotodamaVoice \
  -destination 'platform=macOS' \
  test
```

実モデルを使うオフライン統合テストでは、schemeに定義された環境変数へモデルと音声fixtureのパスを渡します。

- `KOTODAMA_OFFLINE_REQUIRED`
- `KOTODAMA_OFFLINE_MODEL`
- `KOTODAMA_OFFLINE_AUDIO`
- `KOTODAMA_FORMATTER_MODEL`

## モデルとRuntime

モデル管理はデータファイルだけを取得し、実行コードを取得しません。
取得したモデルはManifestのファイルサイズとSHA-256で検証してからApp Group containerへ移動します。

whisper.cppとllama.cppのrevision、生成条件、成果物hashは`Config/runtime-lock.json`で固定します。
Runtimeまたはモデルを更新する場合は、`Resources/ThirdPartyComponents.json`のrevision、ライセンス原文SHA-256、適用範囲も更新します。
固定revisionからXCFrameworkを再生成し、互換性、ライセンス、推論結果、リソース使用量を確認します。

台帳、Runtime lock、Models Manifest、App Bundle、DMGの対応は次のfixtureテストで確認できます。

```sh
./Tests/DistributionLicenseTests.sh
```

## 配布物

直接配布版はDeveloper ID Applicationで署名し、Hardened Runtimeを有効にします。
App、Framework、dylib、Speech Worker、Formatter Workerを同じ配布物として検証します。

`Scripts/verify-license-compliance.sh`は、第三者台帳、Runtime lock、Models Manifest、ライセンス原文SHA-256、App Bundle、mount済みDMGの対応を検査します。
`Scripts/verify-direct-distribution.sh`は、その検査に加えて署名、Hardened Runtime、secure timestamp、entitlementsを検査します。
`Scripts/create-direct-distribution-dmg.sh`は、検証済みのアプリ、本体ライセンス、第三者通知、配布対象のライセンス原文から署名付きDMGを作成します。
`Scripts/verify-direct-distribution-dmg.sh`はDMGを読み取り専用でmountし、ライセンス文書と内包アプリを検査してからdetachします。

```sh
./Scripts/verify-direct-distribution.sh /path/to/KotodamaVoice.app
./Scripts/create-direct-distribution-dmg.sh \
  /path/to/KotodamaVoice.app \
  /path/to/KotodamaVoice.dmg
./Scripts/verify-direct-distribution-dmg.sh /path/to/KotodamaVoice.dmg
```

配布用アプリとDMGにはモデルファイルを同梱しません。
アプリに同梱するModels Manifestとライセンス文書を検証し、モデル本体は利用者の取得操作後に固定URLから取得します。

Notarizationに使う認証情報や証明書の秘密鍵は、ソースコードや設定ファイルへ書き込みません。
