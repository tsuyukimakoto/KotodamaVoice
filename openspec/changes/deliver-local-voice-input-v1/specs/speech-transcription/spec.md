## Purpose

録音音声を内蔵Runtimeまたは明示された外部Endpointで文字列へ変換し、接続先や障害によって音声の送信範囲が変わらないようにする。

## ADDED Requirements

### Requirement: 内蔵Speechをローカル実行する
内蔵Speechはインストール済みの検証済みモデルをWorker内で実行し、音声をネットワークへ送信してはならない（MUST NOT）。

#### Scenario: 内蔵モデルで文字起こしする
- **WHEN** 内蔵Speechが選択され、必要なモデルがInstalledである
- **THEN** システムは録音音声をローカルWorkerへ渡して文字起こし結果を返す

#### Scenario: モデルがない
- **WHEN** 必要なSpeechモデルがInstalledでない
- **THEN** システムは録音を開始せずモデル管理画面への導線を表示する

### Requirement: 外部SpeechのAPI種別を区別する
外部SpeechはOpenAI Audio Transcriptions互換とwhisper.cpp Server互換を別の接続方式として設定しなければならない（SHALL）。

#### Scenario: OpenAI互換をテストする
- **WHEN** ユーザーがOpenAI Audio Transcriptions互換を選んで接続テストを実行する
- **THEN** システムはモデル一覧だけでなく音声文字起こし要求の契約が利用可能か検証する

#### Scenario: whisper.cpp互換をテストする
- **WHEN** ユーザーがwhisper.cpp Server互換を選んで接続テストを実行する
- **THEN** システムは設定されたinference endpointの応答形式を検証する

### Requirement: Engineを勝手に切り替えない
選択中のSpeech Engineが失敗した場合、アプリは別の内蔵または外部Speechへ自動で切り替えてはならない（MUST NOT）。

#### Scenario: 外部Speechが停止している
- **WHEN** 外部Speechへの接続が失敗する
- **THEN** システムは音声を別Endpointへ送らず文字起こし失敗を表示する

### Requirement: 長時間要求を制御する
Speech Engineはタイムアウトとキャンセルを扱い、完了後に到着した応答を出力へ使用してはならない（MUST NOT）。

#### Scenario: ユーザーが処理をキャンセルする
- **WHEN** 文字起こし中にユーザーがキャンセルする
- **THEN** システムは要求をキャンセルして遅れて返った結果を破棄する

### Requirement: 空の文字起こしを区別する
Speech Engineは無音または認識不能による空結果と、Runtime障害を別の結果として返さなければならない（SHALL）。

#### Scenario: 音声から文字を認識できない
- **WHEN** Speech Engineが正常に完了したが本文が空である
- **THEN** システムは出力処理を行わず認識結果が空であることを表示する
