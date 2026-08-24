## Purpose

署名済みアプリを開発環境のないMacへ直接配布し、Gatekeeperの検証、初回権限要求、内蔵Workerの署名を含む導入経路を成立させる。

## ADDED Requirements

### Requirement: 配布物の全実行コードを署名する
配布用アプリはDeveloper ID Applicationでアプリ、Framework、dylib、Speech Worker、Formatter Workerを署名し、Hardened Runtimeを有効にしなければならない（SHALL）。

#### Scenario: Developer IDでexportした配布物を検査する
- **WHEN** 開発者がRelease archiveからDeveloper ID方式で配布用アプリをexportする
- **THEN** 署名検証はアプリ内のすべての実行コードについて成功する

### Requirement: Notarization済み配布物を作る
配布物はApple Notary Serviceの受理後にticketをstapleし、Gatekeeper検証に成功しなければならない（SHALL）。

#### Scenario: 配布物を検証する
- **WHEN** 開発者がstaple済み配布物へGatekeeper検証を実行する
- **THEN** システムはDeveloper ID署名とNotarizationを有効として判定する

### Requirement: クリーン環境から利用開始できる
ユーザーはXcode、Homebrew、Python、外部Runtimeを導入せず、アプリ内から必要なモデルを取得して内蔵Speechを利用できなければならない（SHALL）。

#### Scenario: 初めてインストールする
- **WHEN** モデル未導入のクリーンなMacでアプリを起動する
- **THEN** システムは不足モデルと必要容量を表示してアプリ内から取得できる

### Requirement: 権限を段階的に要求する
配布版は起動時にAccessibility権限を要求せず、マイクは初回録音時、AccessibilityはAuto Insert選択時だけ要求しなければならない（SHALL）。

#### Scenario: Clipboardだけを使う
- **WHEN** ユーザーがAuto Insertを選択せず音声入力を利用する
- **THEN** システムはマイク以外のプライバシー権限を要求しない

### Requirement: App終了後に推論処理を継続しない
配布版はアプリ終了後に録音、推論、モデル保持、ネットワーク要求を継続してはならない（MUST NOT）。

#### Scenario: モデルロード後に終了する
- **WHEN** SpeechとFormatterのモデルがloadedの状態でアプリを終了する
- **THEN** システムは両モデルを解放し進行中要求を残さない
