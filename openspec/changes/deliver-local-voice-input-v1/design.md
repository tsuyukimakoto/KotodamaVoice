## Context

KotodamaVoiceは新規のmacOSアプリであり、UI、音声、推論Runtime、モデル、外部通信、権限、配布を同じ設計の下で構成する。
対象はApple Silicon、16GB以上のUnified Memory、macOS 14以降とする。
開発と性能評価にはApple M5 Max、64GBの実機を使い、16GB環境での受け入れ条件を別に設ける。

通常利用に必要な権限はマイクだけである。
Auto InsertはAccessibility APIを使うため、アプリはApp Sandboxを有効にせず、Developer ID署名とHardened Runtimeによって直接配布する。

whisper.cppはApple Silicon、Metal、Core MLをサポートし、Whisper Large v3 Turboは多言語のMITライセンスモデルとして利用できる。
llama.cppはMetalとGGUFをサポートするが、Gemma 4対応には更新中の領域があるため、Runtime revisionとモデルファイルを組み合わせて評価し、動作確認済みの組み合わせだけをManifestへ登録する。

## Goals / Non-Goals

**Goals:**

- UI、Pipeline、推論、永続設定、外部通信の依存方向を固定する
- SpeechとFormatterを別のXPC Serviceへ隔離し、障害をrequest IDで追跡できるようにする
- クリーンなMacでアプリ内からモデルを取得し、ローカル文字起こしを開始できるようにする
- Clipboardだけを使う正常系と、明示的に有効化するAuto Insertを同じ出力境界で扱う
- 内蔵Engineと外部Engineを設定変更だけで切り替えられるようにする
- 署名とNotarizationを開発終盤の別構成にせず、各実行Targetの構成へ最初から含める

**Non-Goals:**

- Intel Macをサポートしない
- 録音履歴、文字起こし履歴、履歴検索を実装しない
- VADによる自動停止、ストリーミング文字起こし、複数要求のキューを実装しない
- クラウド事業者固有の認証画面または課金連携を実装しない
- ユーザーが任意のモデルrepositoryまたは実行コードを指定する機能を実装しない

## Decisions

### Targetと依存方向

Xcodeプロジェクトは次のTargetで構成する。

```text
KotodamaVoice.app
├── KotodamaCore.framework
├── SpeechWorker.xpc
│   └── whisper.xcframework
└── FormatterWorker.xpc
    └── llama.xcframework

KotodamaVoiceTests
KotodamaVoiceUITests
SpeechWorkerTests
FormatterWorkerTests
```

`KotodamaCore`は値型、Engine protocol、Pipeline、XPC protocol、エラー型を持ち、AppKit、AVFoundation、推論Runtimeへ依存しない。
アプリTargetはUI、録音、設定、モデル管理、外部API、出力を実装する。
WorkerだけがCまたはC++の推論Runtimeへリンクする。

共有Frameworkを作らずファイルを複数Targetへ重複登録する方式は採用しない。
同じ型に見える別実装が増え、XPC契約の版ずれをコンパイル時に検出できなくなるためである。

### SwiftUIとAppKitの分担

メニューバー、Settings、Models、Runtime MonitorはSwiftUIで作る。
ライフサイクル、Accessibility、非アクティブHUD、必要なウィンドウ制御にはAppKitを使う。
`LSUIElement`でDock非表示を宣言し、設定画面を開くときだけ通常ウィンドウを表示する。

HUDは一つの`NSPanel`を再利用する。
SwiftUIのWindowだけで実装すると、フォーカス、Space、画面配置の制御が不十分になるため採用しない。

### 状態機械とPipeline

状態はMainActor上のStoreが一つだけ所有する。

```text
ready
  → recording
  → transcribing
  → formatting
  → outputting
  → ready

任意の状態 → error → ready
任意の処理状態 → cancelling → ready
```

Pipelineは録音停止時に一つのrequest IDを発行し、Speech、Formatter、Outputへ引き継ぐ。
処理中のホットキーは無視し、キューへ保存しない。
Formatter失敗はSpeech成功を失わせず、原文をOutputへ渡して警告を表示する。

UIが各Engineを直接呼ぶ構成は採用しない。
キャンセル、状態遷移、Fallback、ログの順序が画面ごとに分散するためである。

### グローバルショートカット

グローバルショートカットは`RegisterEventHotKey`を薄いServiceで包む。
このAPIは現在のmacOS 26.5 SDKにも存在し、全キーイベントを監視せずアプリ向けホットキーだけを登録できる。
キーリピートを一回の押下として扱い、登録競合を型付きエラーとしてSettingsへ表示する。

`CGEventTap`またはglobal event monitorによる全キー監視は採用しない。
Input MonitoringまたはAccessibility権限を増やし、アプリが必要以上の入力を観測するためである。

### 録音と音声の受け渡し

録音は`AVAudioEngine`のinput nodeから取得する。
マイクのnative formatで受け取り、`AVAudioConverter`でモノラル16kHz Float32へ変換する。
録音中はメモリ上のchunkへ保持し、長時間録音で上限を超える場合だけApplication Support内の一時ファイルへ移す。

Speech WorkerへはXPCで大きな`Data`を送らず、読み取り専用の`NSFileHandle`とサンプル形式を渡す。
一時ファイルはrequest IDごとのディレクトリへ置き、応答、失敗、キャンセルのいずれでも削除する。

### XPC境界

Speech WorkerとFormatter Workerはアプリbundle内のprivate XPC Serviceとする。
`NSXPCConnection`の`activate`、interruption handler、invalidation handlerを一つのConnection Managerが管理する。

```text
WorkerRequest
  protocolVersion
  requestID
  operation
  modelID
  options

WorkerEvent
  requestID
  phase
  progress
  metrics

WorkerReply
  requestID
  result | typedError
```

音声本文、文字起こし本文、整形本文は要求と応答には含まれるが、`description`、`debugDescription`、OSLogへ展開しない。
ログはrequest ID、byte count、token count、時間、状態、エラー分類だけを記録する。

中断は進行中要求を一度だけ失敗させてConnectionを破棄し、次回要求で新しいConnectionを作る状態として扱う。
無効化も同様にConnectionを破棄し、次回要求まで再接続しない。
進行中要求は自動再実行しない。
再実行すると同じ要求が二重に完了する可能性があるためである。

Workerはモデルのロード、推論、アンロード、キャンセル、状態取得、shutdownを提供する。
アプリ終了時はshutdownの完了を短い期限まで待ち、接続をinvalidateする。
XPC Serviceのプロセス終了はlaunchdへ任せるが、モデルメモリと進行中要求はshutdown応答前に解放する。

### モデル保存領域

アプリとXPC Serviceが同じモデルを参照できるよう、Developer Teamに紐づくApp Group containerの`Models`ディレクトリを使用する。
一時取得、resume data、確定モデルを同じvolumeへ置き、renameによるatomic moveを成立させる。

App Groupを使わず任意の絶対pathをWorkerへ渡す方式は採用しない。
XPC Serviceのfilesystem制約と署名設定によって動作が変わり、クリーン環境で再現しにくいためである。

### Runtimeの組み込み

whisper.cppとllama.cppはrelease tagまたはcommit SHAをRuntime lock fileへ固定する。
固定sourceから公式のCMakeとXCFramework build scriptを使ってarm64 macOS用Frameworkを生成し、生成物のSHA-256を検証する。
Frameworkは各Workerへ埋め込み、配布時にDeveloper IDで再署名する。

推論Runtimeの実行ファイルをモデルと一緒にダウンロードする方式は採用しない。
配布後に署名対象外のコードを追加することになるためである。

### Speechモデル

内蔵Speechの評価対象はWhisper Large v3 TurboのF16とQ5量子化である。
日本語の句読点、固有名詞、英数字混在、日付、長い発話を含む固定音声セットで文字誤り率、処理時間、モデルロード時間、physical footprintを測る。
16GB Macで連続利用でき、品質基準を満たす最小のモデルを既定Manifestへ固定する。

Core ML encoderはMetal単独より品質を変えずに性能が改善する場合だけ同梱する。
Core ML artifactもモデルManifestのhash対象にする。

### Formatterモデル

内蔵FormatterはGemma 4 E4B instruction-tunedを第一候補とし、llama.cppの固定revisionで変換、ロード、日本語生成、キャンセル、連続要求を検証する。
互換性または品質基準を満たさない場合は、同程度のメモリ範囲に収まる日本語対応GGUFモデルを同じ評価で比較する。

評価では次を測る。

- 意味、固有名詞、数値、日付の保持
- フィラー除去、句読点、改行の品質
- 情報追加、要約、推測の発生
- ロード時間、physical footprint、prompt速度、generation速度
- 16GB MacでSpeechモデルと同時にロードした場合のmemory pressure

既定モデルと量子化は評価結果が合格した組み合わせだけをManifestへ固定する。
最小ファイルを自動的に選ぶ方式は採用しない。

### Model Manager

Manifestはapp bundle内の署名対象JSONとして保持する。
revisionとSHA-256を固定し、実行時にremoteの`main`を解決しない。

ダウンロードは`URLSessionDownloadTask`を使い、空き容量確認、resume、一時ファイル、サイズ検証、SHA-256、atomic moveの順に処理する。
ライセンス本文または配布条件へのリンクを取得前に表示する。

モデル削除は対応Workerのunloadが成功してから行う。
ダウンロードと削除を同じモデルに対して同時実行しない。

### 外部Engine

外部Speechは次のadapterを分ける。

- OpenAI Audio Transcriptions互換
- whisper.cpp Serverの`/inference`互換

LM StudioはAudio Transcriptions endpointを提供しないため、Speech接続先として扱わない。
外部FormatterはOpenAI互換のResponsesとChat Completionsをadapterで分け、LM Studioとllama-serverを対象にする。

loopback判定はURLのhost文字列だけで済ませず、`localhost`、IPv4 loopback、IPv6 loopbackを正規化して判定する。
loopback以外では送信データを表示し、HTTPSでない場合は暗号化されないことを追加表示する。

External Engine障害時にInternalへ切り替えない。
ユーザーが指定していないEngineへ音声または本文を渡さないためである。

### Formatting Prompt

Default Promptは版付きresourceとして管理し、整形本文だけを返すよう要求する。
Custom PromptはUserDefaultsへ保存するが、文字起こし本文を連結した最終Promptは保存しない。

Formatter出力は空、上限超過、制御token混入、本文外の説明を検査する。
意味保持を機械的に完全保証することはできないため、固定評価セットとFormatter Offを提供し、失敗時は原文を使用する。

### ClipboardとAuto Insert

Clipboardは`NSPasteboard`へplain textを書き込み、change countと読み戻しで直後の成功を確認する。
Clipboard成功、Auto InsertからClipboardへのFallback、出力失敗は本文を含まないHUDで通知する。
Auto Insert成功は入力欄への反映自体で確認できるためHUDを表示しない。

Auto Insertはユーザーが設定で選択した場合だけ`AXIsProcessTrustedWithOptions`を呼ぶ。
アプリ起動時にはAccessibility権限を要求しない。

録音開始時にfrontmost application、focused element、selected text rangeを取得する。
出力時にPID、element role、editable属性、選択範囲を再取得して一致を確認する。
安全な置換を確認できない場合はClipboardへFallbackする。

キーボードイベントで貼り付けを模倣する方式は採用しない。
対象と選択範囲を検証できず、Input Monitoringまたは追加の権限問題を生むためである。

### 設定と秘密情報

非機密設定は`UserDefaults`、API KeyはKeychainへ保存する。
EndpointごとにEngine種別、base URL、model、timeout、API Key参照を保持する。
接続テストは実際の要求契約を検証し、単なるTCP接続成功をReadyとして扱わない。

Launch at Loginは`SMAppService.mainApp`を使い、ユーザーがSettingsで有効化した場合だけ登録する。

### Runtime Monitorとログ

Workerはモデル状態と直近要求のmetricsを応答する。
アプリはRuntime Monitorが開いている間だけprocess情報をpollingし、閉じた時点で停止する。
Unified Memory環境で独立VRAMまたは推測GPU使用率を表示しない。

OSLogはsubsystemを共通化し、categoryをapp、pipeline、speech-worker、formatter-worker、model、network、outputへ分ける。
request IDでプロセスをまたいだログを検索できるようにする。

### 配布と署名

App Sandboxは有効にしない。
Accessibility APIによる他アプリ操作がV1の任意機能に含まれるためである。

アプリと全内蔵実行コードでHardened RuntimeとLibrary Validationを維持する。
JIT、unsigned executable memory、disable library validationの例外を要求しない。
配布用archiveをDeveloper ID Applicationで署名し、`notarytool`で送信してticketをstapleする。

## Risks / Trade-offs

- [XPC越しのモデル参照が署名またはcontainer設定で失敗する] → App Group entitlementを全Targetで一致させ、最初の統合テストでモデルのopenとmmapを検証する
- [Workerのクラッシュ原因が見えにくくなる] → request ID、protocol version、phase、metricsを共通化し、Worker単体テストと直接起動可能な診断Harnessを用意する
- [Gemma 4とllama.cppの固定組み合わせが安定しない] → Runtimeとモデルを一組として回帰試験し、合格しない組み合わせをManifestへ追加しない
- [SpeechとFormatterの同時ロードが16GB Macでmemory pressureを起こす] → 16GB実機で測定し、Formatterの遅延ロードと明示的unloadを提供する
- [Accessibility elementの実装差で誤挿入する] → 対象と選択範囲を再検証し、確証がない場合はClipboardへFallbackする
- [外部Endpointが互換APIの一部だけを実装する] → adapterごとに実要求を使う接続テストを行い、Engine種別を自動推測しない
- [モデル配布元のファイルが差し替わる] → revision、サイズ、SHA-256を固定し、不一致を導入失敗として扱う

## Migration Plan

新規アプリのためユーザーデータ移行はない。
