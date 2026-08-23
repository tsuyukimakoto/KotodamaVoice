## 1. プロジェクトと署名境界

- [x] 1.1 App、Core Framework、Speech Worker、Formatter Worker、各Test Targetを持つXcodeプロジェクトを作り、全schemeのDebug buildが成功することを確認する
- [x] 1.2 macOS 14、arm64、LSUIElement、Hardened Runtime、App GroupをTargetごとに設定し、build settingsとentitlementsの検査で意図した値だけが含まれることを確認する
- [x] 1.3 Coreの依存方向を検査するテストまたはbuild ruleを追加し、CoreがAppKit、AVFoundation、whisper、llamaへリンクしていないことを確認する
- [x] 1.4 Runtime lock fileと再現可能なXCFramework build scriptを作り、固定revisionからwhisperとllamaのarm64 Frameworkを生成してSHA-256検証が成功することを確認する
- [x] 1.5 生成Frameworkを各Workerだけへリンクし、アプリ実行ファイルがwhisperまたはllama symbolを直接参照していないことを`nm`とlink mapで確認する

## 2. アプリ状態と操作

- [x] 2.1 Pipeline状態機械とrequest IDについて不正遷移、処理中の再操作、キャンセルの失敗テストを先に追加し、テストが要求どおり失敗することを確認する
- [x] 2.2 MainActor上のStoreとPipeline coordinatorを実装し、2.1のテストが成功することを確認する
- [x] 2.3 メニューバー、状態表示、Settings、Models、Runtime Monitor、終了操作を実装し、UI Testで各画面へ到達できDockアイコンが表示されないことを確認する
- [x] 2.4 `RegisterEventHotKey` adapterへ登録競合とキーリピートの失敗テストを追加してから実装し、別アプリが前面でも一回の押下が一回の状態遷移になることを確認する
- [x] 2.5 ショートカット編集と再登録を実装し、競合時に旧設定を維持してエラーを表示することをテストする
- [x] 2.6 `SMAppService.mainApp`によるLaunch at Loginを実装し、設定のONとOFFで登録状態が一致することを確認する

## 3. XPC通信基盤

- [x] 3.1 protocol version、request ID、要求、event、reply、型付きエラーをCoreへ定義し、secure codingの往復テストが成功することを確認する
- [x] 3.2 Speech WorkerとFormatter Workerに最小listenerとdiagnostic echoを実装し、Appから各Workerへ別々に接続してrequest ID付き応答を取得できることを確認する
- [x] 3.3 Connection Managerへ中断、無効化、timeout、cancelの失敗テストを先に追加してから実装し、進行中要求が一度だけ完了または失敗することを確認する
- [x] 3.4 Workerをテスト中に強制終了する統合テストを作り、Appが継続し次回要求でWorkerが再起動することを確認する
- [x] 3.5 App Group container内の固定fixtureを各Workerからopenしてmmapできる統合テストを作り、署名済みDebug buildで成功することを確認する
- [x] 3.6 load、unload、state、shutdownを共通Worker lifecycleへ実装し、shutdown応答前にモデルfixtureと進行中処理が解放されることをテストする
- [x] 3.7 request IDを含む統一OSLogをAppとWorkerへ実装し、本文を含まないログだけで正常要求とWorker障害の段階を追跡できることを確認する

## 4. Model Manager

- [x] 4.1 Manifest decoderへ必須項目不足、重複ID、許可外ファイル種別、hash不正の失敗テストを追加してから検証処理を実装する
- [x] 4.2 署名対象のモデルManifestとModels画面を実装し、名称、用途、容量、取得元、ライセンス、状態がfixtureと一致することをUI Testで確認する
- [x] 4.3 空き容量、一時取得、resume、進捗、サイズ、SHA-256、atomic moveの失敗テストを追加してからdownload coordinatorを実装する
- [x] 4.4 HTTP fixture serverで成功、中断再開、hash不一致、容量不足を再現し、Installedになるのが検証成功時だけであることを確認する
- [ ] 4.5 Worker unloadとモデル削除を連携し、unload失敗時はファイルを残し成功時だけ削除されることを統合テストで確認する
- [ ] 4.6 同一モデルのdownload、delete、loadを直列化し、競合操作を注入して破損または二重状態が発生しないことを確認する

## 5. 録音Pipeline

- [x] 5.1 マイク権限の未決定、許可、拒否を表す境界と失敗テストを追加し、初回録音操作まで許可要求を開始しない実装を確認する
- [x] 5.2 `AVAudioEngine`による録音と`AVAudioConverter`によるモノラル16kHz Float32変換を実装し、既知波形fixtureのサンプル数と値をテストする
- [x] 5.3 空録音、入力機器切断、最大録音長、キャンセルのテストを追加し、部分音声をSpeechへ渡さずreadyへ戻ることを確認する
- [x] 5.4 request ID単位の一時音声ファイルと`NSFileHandle`受け渡しを実装し、成功、失敗、キャンセル後に一時ファイルが残らないことを確認する
- [ ] 5.5 メニューバーとホットキーを録音Pipelineへ接続し、二回の押下で録音開始、停止、transcribing遷移が一度ずつ起きることを実機で確認する

## 6. 内蔵Speech

- [x] 6.1 whisper Runtime wrapperへmodel load、transcribe、cancel、unloadの失敗テストをfixture Runtimeで追加してからSpeech Workerへ実装する
- [ ] 6.2 固定したwhisper.cpp Frameworkと小型テストモデルを使うWorker統合テストを作り、既知音声から期待文字列を取得できることを確認する
- [ ] 6.3 Large v3 Turbo F16とQ5候補を取得し、固定日本語音声セットで文字誤り、固有名詞、英数字、日付、処理時間、ロード時間、physical footprintを測定する
- [ ] 6.4 16GB基準を満たす既定SpeechモデルをManifestへ固定し、revision、size、SHA-256、MITライセンス表示を検証する
- [ ] 6.5 内蔵SpeechをPipelineへ接続し、録音から文字起こし原文までネットワーク接続なしで完了することをNetwork Link Conditionerまたは通信監視で確認する
- [ ] 6.6 Speech Workerを推論中に終了し、Appがクラッシュせず要求を失敗表示して次の録音で復旧することを確認する

## 7. Formatter

- [ ] 7.1 Formatter Off、内蔵、外部と、失敗時に原文へ戻るPipelineテストを先に追加してからEngine selectionを実装する
- [ ] 7.2 llama Runtime wrapperへmodel load、format、cancel、unloadの失敗テストをfixture Runtimeで追加してからFormatter Workerへ実装する
- [ ] 7.3 Gemma 4 E4B候補を固定llama.cpp revisionで変換または取得し、ロード、連続生成、キャンセル、終了、制御token除去を検証する
- [ ] 7.4 日本語評価セットで意味、固有名詞、数値、日付、フィラー、句読点、情報追加、ロード時間、速度、physical footprintを測定する
- [ ] 7.5 16GB環境でSpeechと同時利用できる合格モデルをManifestへ固定し、合格しない場合は同じ評価条件で代替GGUFモデルを選定する
- [ ] 7.6 版付きDefault Prompt、Custom Prompt、上書き確認を実装し、Default resourceがユーザー編集で変化しないことをUI Testで確認する
- [ ] 7.7 空出力、長すぎる出力、説明文、timeout、Worker障害で原文が出力へ渡り、別Formatterへ切り替わらないことを統合テストする

## 8. 外部Engineと設定

- [ ] 8.1 OpenAI Audio Transcriptions adapterとwhisper.cpp `/inference` adapterを別々に実装し、fixture serverでrequestとresponse契約をテストする
- [ ] 8.2 OpenAI Responses adapterとChat Completions adapterを別々に実装し、LM Studio形式とllama-server形式のfixtureで本文抽出をテストする
- [ ] 8.3 Engine種別ごとの接続テストを実装し、TCP接続だけ成功して契約が欠けるserverをReadyにしないことを確認する
- [ ] 8.4 loopback判定、外部送信確認、外部平文HTTP警告を実装し、IPv4、IPv6、localhost、外部hostの境界テストを成功させる
- [ ] 8.5 API KeyをKeychainへ保存する実装とテストを追加し、UserDefaults、設定export、OSLogに秘密情報が含まれないことを確認する
- [ ] 8.6 外部Speech障害時に音声が別Endpointへ送られず、外部Formatter障害時に原文だけが出力されることを通信fixtureで確認する

## 9. ClipboardとAuto Insert

- [x] 9.1 Clipboard adapterへ置換、読み戻し、競合、失敗のテストを追加してから実装し、最終テキストと読み戻しが一致することを確認する
- [ ] 9.2 単一`NSPanel` HUDへ置換、timer reset、非アクティブ、本文非表示のテストを追加してから実装する
- [ ] 9.3 Accessibility権限adapterを実装し、起動時とClipboard利用時にはpromptせずAuto Insert選択時だけpromptすることをUI Testで確認する
- [ ] 9.4 録音開始時のfrontmost app、focused element、selection captureと出力時再検証を実装し、PID変更、element無効化、selection変更の失敗テストを成功させる
- [ ] 9.5 選択範囲への置換を実装し、TextEdit、Notes、Safari、Chrome、Slack、VS Code、Xcode、Terminal、ChatGPTでcapture、insert、selection replacementを記録する
- [ ] 9.6 安全に挿入できないelement、権限失効、対象アプリ終了でClipboardへFallbackし、既存入力全体を変更しないことを互換性試験で確認する

## 10. Runtime Monitorとプライバシー

- [ ] 10.1 Worker状態、モデル、PID、physical footprint、CPU、処理時間、token速度、Metal状態を表示するRuntime Monitorを実装する
- [ ] 10.2 Monitor表示中だけpollingするテストを追加し、ウィンドウを閉じた後にtimerとprocess samplingが停止することを確認する
- [ ] 10.3 取得不能なGPU使用率と独立VRAMを表示しないUI Testを追加し、利用可能なmetricsだけが表示されることを確認する
- [ ] 10.4 音声、文字起こし、Prompt本文、整形本文、Clipboard、API Keyを含むcanary文字列を全失敗経路へ流し、OSLogとRuntime Monitorに現れないことを確認する
- [ ] 10.5 request IDからApp、Speech Worker、Formatter Workerの正常要求とクラッシュ要求を追跡し、段階と時間が一致することを診断手順で確認する

## 11. V1統合試験

- [ ] 11.1 モデル未導入状態からSpeechモデル取得、録音、内蔵文字起こし、Clipboard出力、二回目の録音までをUI Testと実機操作で完了する
- [ ] 11.2 Formatter Off、内蔵、外部の各経路を実行し、成功時の本文と失敗時の原文Fallbackがspecに一致することを確認する
- [ ] 11.3 ClipboardとAuto Insertの各経路で権限要求、入力先検証、Fallback、HUDがspecに一致することを確認する
- [ ] 11.4 モデル取得失敗、マイク拒否、Worker crash、外部timeout、hash不一致、disk不足、権限失効を順に再現し、Appが継続して復旧操作を提示することを確認する
- [ ] 11.5 16GB Apple Silicon MacでSpeechとFormatterの連続10回利用を実行し、memory pressure、モデル再ロード回数、処理時間、終了後のモデル解放を記録する
- [ ] 11.6 全Unit Test、Worker Test、UI Test、OpenSpec strict validationを実行し、失敗がないことを確認する

## 12. 直接配布

- [ ] 12.1 Release archiveをDeveloper ID ApplicationとHardened Runtimeで署名し、App、Framework、dylib、両Workerの`codesign --verify --deep --strict`が成功することを確認する
- [ ] 12.2 Release entitlementsを検査し、App Sandbox、JIT、unsigned executable memory、disable library validationが含まれないことを確認する
- [ ] 12.3 配布物を`notarytool`へ送信して受理後にticketをstapleし、`stapler validate`と`spctl --assess`が成功することを確認する
- [ ] 12.4 開発ツールとモデルのないクリーンなmacOS 14以降のMacへ配布物を導入し、初回起動、モデル取得、マイク許可、Clipboard音声入力を完了する
- [ ] 12.5 Accessibilityなしとありの両方で配布版を検証し、通常利用ではマイク以外を要求せずAuto InsertだけがAccessibilityを要求することを確認する
- [ ] 12.6 SpeechとFormatterモデルをロードしてからアプリを終了し、録音、推論、ネットワーク要求が継続せずモデルメモリが解放されることをActivity Monitorとログで確認する
