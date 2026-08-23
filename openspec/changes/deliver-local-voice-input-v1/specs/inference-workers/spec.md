## Purpose

SpeechとFormatterの推論処理をUIプロセスから隔離し、クラッシュ、再起動、モデル解放を追跡可能な共通契約で管理する。

## ADDED Requirements

### Requirement: 推論種別ごとにWorkerを分離する
アプリは内蔵Speechと内蔵Formatterを別々の署名済みWorkerプロセスで実行し、UIプロセス内でモデルRuntimeを実行してはならない（MUST NOT）。

#### Scenario: 内蔵Speechを実行する
- **WHEN** Pipelineが内蔵Speechへ文字起こしを要求する
- **THEN** システムはSpeech Workerをオンデマンドで起動して要求を実行する

#### Scenario: 内蔵Formatterを実行する
- **WHEN** Pipelineが内蔵Formatterへ整形を要求する
- **THEN** システムはFormatter Workerをオンデマンドで起動して要求を実行する

### Requirement: IPC契約を版管理する
アプリとWorkerはprotocol version、request ID、要求種別、モデル識別子、進捗、結果、型付きエラーを含む契約で通信しなければならない（SHALL）。

#### Scenario: 契約版が一致しない
- **WHEN** アプリとWorkerのprotocol versionが一致しない
- **THEN** システムは推論を開始せず互換性エラーを表示する

### Requirement: Worker障害をUIプロセスから隔離する
Workerがクラッシュまたは強制終了してもアプリは継続動作し、進行中の要求を一度だけ失敗として確定しなければならない（SHALL）。

#### Scenario: 推論中にWorkerがクラッシュする
- **WHEN** Workerが応答前に異常終了する
- **THEN** システムは対応するrequest IDをWorker障害として失敗させる
- **THEN** システムはアプリを終了せず次回要求でWorkerを再起動できる

### Requirement: 診断可能な通信にする
アプリとWorkerはrequest ID、処理段階、所要時間、モデル状態、接続中断、接続無効化を統一ログへ記録し、音声と本文を記録してはならない（MUST NOT）。

#### Scenario: 要求を完了する
- **WHEN** Workerが推論結果を返す
- **THEN** システムは同じrequest IDで開始、モデルロード、推論、完了を追跡できるメタデータを記録する

### Requirement: 終了時にモデルを解放する
アプリは終了前に各Workerへshutdownを要求し、モデル解放の応答後に接続を無効化しなければならない（SHALL）。

#### Scenario: 通常終了する
- **WHEN** ユーザーがアプリを終了する
- **THEN** システムはWorkerのモデルロード状態をunloadedへ遷移させる
- **THEN** システムは進行中のXPC接続を残さない
