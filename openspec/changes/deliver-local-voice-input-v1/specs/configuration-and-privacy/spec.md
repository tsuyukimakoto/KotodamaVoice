## Purpose

Engine、Prompt、出力、起動方法を永続設定として管理し、秘密情報と入力内容を保存、ログ、外部送信から保護する。

## ADDED Requirements

### Requirement: 設定を分類して提供する
アプリはGeneral、Speech、Formatting、Output、Modelsの設定画面を提供し、変更を次回起動後も保持しなければならない（SHALL）。

#### Scenario: 設定を変更して再起動する
- **WHEN** ユーザーがEngineまたは出力方式を変更してアプリを再起動する
- **THEN** システムは保存された設定を復元する

### Requirement: API KeyをKeychainへ保存する
アプリは外部EndpointのAPI KeyをKeychainへ保存し、設定ファイル、UserDefaults、ログへ書き込んではならない（MUST NOT）。

#### Scenario: API Keyを保存する
- **WHEN** ユーザーがAPI Keyを入力して設定を保存する
- **THEN** システムはKeychainからのみ秘密情報を復元する

### Requirement: 外部送信を明示する
アプリはloopback以外のEndpointを設定した場合、送信されるデータ種別と接続先を表示し、ユーザーの確認前にテスト要求を送ってはならない（MUST NOT）。

#### Scenario: 外部Speechを設定する
- **WHEN** ユーザーがloopback以外のSpeech Endpointを入力する
- **THEN** システムは音声がそのEndpointへ送信されることを表示して確認を求める

#### Scenario: 外部Formatterを設定する
- **WHEN** ユーザーがloopback以外のFormatter Endpointを入力する
- **THEN** システムは文字起こし結果とPromptが送信されることを表示して確認を求める

### Requirement: 安全でない外部HTTPを区別する
アプリはloopback以外の平文HTTP Endpointを安全な接続として表示してはならず（MUST NOT）、保存と利用の前に追加確認を要求しなければならない（SHALL）。

#### Scenario: 外部HTTPを入力する
- **WHEN** ユーザーがloopback以外の`http` Endpointを設定する
- **THEN** システムは通信が暗号化されないことを表示する

### Requirement: 入力内容を永続化しない
アプリは音声、文字起こし本文、Promptへ連結した本文、整形本文、Clipboard内容を履歴または通常ログへ保存してはならない（MUST NOT）。

#### Scenario: Pipelineが失敗する
- **WHEN** 任意の処理段階でエラーが発生する
- **THEN** システムは本文を含まないエラー種別、request ID、処理時間だけを診断ログへ記録する
