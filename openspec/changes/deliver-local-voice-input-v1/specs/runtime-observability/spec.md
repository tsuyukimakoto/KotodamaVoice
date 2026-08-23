## Purpose

推論Workerと直近処理の状態を本文に触れず確認できるようにし、監視画面を閉じている間の継続的な計測負荷を発生させない。

## ADDED Requirements

### Requirement: Worker状態を表示する
Runtime MonitorはSpeech WorkerとFormatter Workerについて接続状態、プロセス識別子、モデル識別子、ロード状態、Metal利用状態を表示しなければならない（SHALL）。

#### Scenario: モデルをロードする
- **WHEN** Workerがモデルロードを完了してRuntime Monitorが開いている
- **THEN** システムは対応Workerをloadedとして表示する

### Requirement: 実測可能な指標だけを表示する
Runtime Monitorはprocess physical footprint、CPU使用率、処理時間、prompt速度、generation速度を取得できる場合だけ表示し、推測したGPU使用率または独立VRAM容量を表示してはならない（MUST NOT）。

#### Scenario: GPU使用率を取得できない
- **WHEN** RuntimeまたはOSから正確なGPU使用率を取得できない
- **THEN** システムはGPU使用率の数値を表示しない

### Requirement: 監視画面を閉じたら定期計測を停止する
アプリはRuntime Monitorが閉じている間、リソース表示のための定期pollingを実行してはならない（MUST NOT）。

#### Scenario: Runtime Monitorを閉じる
- **WHEN** ユーザーがRuntime Monitorを閉じる
- **THEN** システムは定期計測タイマーを停止する

### Requirement: 直近要求をrequest IDで追跡する
Runtime Monitorは直近のSpeechとFormatter要求についてrequest ID、結果種別、各段階の時間を表示し、音声または本文を表示してはならない（MUST NOT）。

#### Scenario: Worker障害が発生する
- **WHEN** 推論中にWorker接続が中断する
- **THEN** システムは対応request IDと中断段階をRuntime Monitorへ表示する
