## Purpose

最終テキストを権限不要のClipboardまたは明示的に許可された入力欄へ渡し、対象が不確実な場合に内容や既存入力を破壊しない。

## ADDED Requirements

### Requirement: 初回に出力方式を選択する
アプリは保存済みの出力方式がない場合に出力を未設定として扱い、ClipboardまたはAuto Insertをユーザーが明示的に選択するまで録音を開始してはならない（MUST NOT）。

#### Scenario: 初めて起動する
- **WHEN** 保存済みの出力方式がない状態でアプリを起動する
- **THEN** システムはClipboardとAuto Insertの違いを示す選択画面を表示する
- **THEN** システムはClipboardを権限不要の推奨選択肢として表示する
- **THEN** システムは選択前にマイクまたはAccessibility権限を要求しない

#### Scenario: 選択せず画面を閉じる
- **WHEN** ユーザーが出力方式を選択せず選択画面を閉じる
- **THEN** システムは出力を未設定のまま維持する
- **THEN** システムは録音操作を受けたときに選択画面を再表示する

### Requirement: Clipboardを権限不要の出力として提供する
アプリはClipboardが選択された場合に最終テキストをシステムClipboardへ書き込み、前面アプリのUI情報へアクセスしてはならない（MUST NOT）。

#### Scenario: Clipboard出力に成功する
- **WHEN** 最終テキストが確定する
- **THEN** システムはClipboardの既存内容を最終テキストで置き換える
- **THEN** システムはAccessibility権限を要求しない

### Requirement: 必要な結果を単一HUDで通知する
アプリはClipboard成功、Auto InsertからClipboardへのFallback、出力失敗についてフォーカスを奪わないHUDを一つだけ表示し、新しい通知で既存HUDと消去時刻を置き換えなければならない（SHALL）。Auto Insert成功ではHUDを表示してはならない（MUST NOT）。

#### Scenario: 短時間に複数結果が届く
- **WHEN** HUD表示中に新しい結果通知が届く
- **THEN** システムはHUDを追加せず既存HUDの内容と消去時刻を更新する

#### Scenario: Clipboard成功を表示する
- **WHEN** Clipboard出力が完了する
- **THEN** システムは本文を含めず出力方式と成功だけをHUDへ表示する

#### Scenario: Auto Insert成功は入力欄だけで確認する
- **WHEN** Auto Insertが成功する
- **THEN** システムは入力欄へ最終テキストを反映する
- **THEN** システムはHUDを表示しない

### Requirement: Auto Insertを明示的に有効化する
アプリはユーザーがAuto Insertを選択した時点だけAccessibility権限を確認し、許可されるまで設定を確定してはならない（MUST NOT）。

#### Scenario: 権限なしでAuto Insertを選ぶ
- **WHEN** Accessibility権限がない状態でユーザーがAuto Insertを選択する
- **THEN** システムは用途を説明してユーザー操作により許可要求を開始する
- **THEN** 許可されるまで出力方式を未設定のまま維持する

### Requirement: 録音開始時の入力先を対象にする
Auto Insertは録音開始時に前面アプリ、focused element、選択範囲を取得し、出力時に同じ対象が有効であることを再検証しなければならない（SHALL）。

#### Scenario: 処理中にフォーカスが移る
- **WHEN** 録音開始後に別の入力欄へフォーカスが移る
- **THEN** システムは新しくフォーカスされた入力欄へ挿入しない

### Requirement: 安全に挿入できない場合はClipboardへ戻す
アプリは対象、選択範囲、書き込み可能性を確認できない場合に既存内容全体を置換せず、Clipboardへ出力しなければならない（SHALL）。

#### Scenario: 対象要素が無効になる
- **WHEN** 出力時に録音開始時の要素を再検証できない
- **THEN** システムはAuto Insertを行わずClipboardへ出力する
- **THEN** システムはFallbackしたことを本文なしで表示する

### Requirement: 権限の失効を正常に扱う
アプリはAuto Insert設定後にAccessibility権限が失効した場合、設定画面を繰り返し開かずClipboardへ出力しなければならない（SHALL）。

#### Scenario: 権限が取り消される
- **WHEN** Auto Insert設定中にAccessibility権限が取り消されている
- **THEN** システムはClipboardへ出力して権限不足を表示する
