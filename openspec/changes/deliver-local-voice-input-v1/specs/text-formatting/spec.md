## Purpose

文字起こし結果の意味、数値、固有名詞を保ったまま日本語としての読みやすさを整え、整形を使わない選択と障害時の原文保持を保証する。

## ADDED Requirements

### Requirement: Formatterの動作方式を選択できる
アプリはFormatterをOff、内蔵、外部から選択でき、初期値をOffとしなければならない（SHALL）。内蔵は、選択済みのFormatterモデルがInstalledの場合だけ確定・保存しなければならない（SHALL）。

#### Scenario: Offを選択する
- **WHEN** FormatterがOffで文字起こしに成功する
- **THEN** システムは文字起こし結果を変更せず出力へ渡す

#### Scenario: 未導入の内蔵Formatterを選択する
- **WHEN** FormatterモデルがInstalledでない状態でユーザーが内蔵を選択する
- **THEN** システムは対象モデルの名称、容量、取得元、ライセンスと「モデルを取得しますか？」を表示する
- **THEN** システムは内蔵を確定または保存せず、現在のFormatter設定を維持する

#### Scenario: Formatterモデルの取得を承認する
- **WHEN** 未導入モデルの取得確認でユーザーが取得を承認する
- **THEN** システムはモデル管理画面の対象Formatterモデルへ遷移し、取得を開始する
- **THEN** システムはサイズとSHA-256の検証、導入、モデル選択がすべて成功した後に内蔵を確定・保存する

#### Scenario: Formatterモデルの取得を取り消すまたは取得に失敗する
- **WHEN** ユーザーが取得確認を取り消すか、モデルの取得、検証、導入、選択のいずれかに失敗する
- **THEN** システムは内蔵を確定または保存せず、現在のFormatter設定を維持する

#### Scenario: 使用中のFormatterモデルを削除する
- **WHEN** 内蔵Formatterで使用中のモデル削除が成功する
- **THEN** システムはFormatterをOffに変更し、利用できない内蔵選択を残さない

### Requirement: 内蔵Formatterをローカル実行する
内蔵Formatterは検証済みモデルをFormatter Workerで実行し、文字起こし結果とPromptをネットワークへ送信してはならない（MUST NOT）。

#### Scenario: 内蔵整形に成功する
- **WHEN** 内蔵Formatterが選択され必要なモデルがInstalledである
- **THEN** システムはローカルWorkerが返した整形本文だけを出力へ渡す

### Requirement: 外部Formatterの接続を検証する
外部FormatterはOpenAI互換のResponsesまたはChat Completions方式を明示し、モデルと応答本文の取得方法を接続テストで検証しなければならない（SHALL）。

#### Scenario: LM Studioへ接続する
- **WHEN** ユーザーがLM StudioのEndpointとモデルを設定して接続テストを実行する
- **THEN** システムは選択されたテキスト生成Endpointで短い応答を取得できることを確認する

### Requirement: Default PromptとCustom Promptを提供する
アプリは版付きDefault Promptとユーザー編集可能なCustom Promptを提供し、Default Prompt自体をユーザー編集で変更してはならない（MUST NOT）。

#### Scenario: DefaultをCustomへ読み込む
- **WHEN** ユーザーがDefault Promptの読み込みを選択する
- **THEN** システムは現在のDefault PromptをCustom editorへコピーする
- **THEN** 変更済みCustom Promptがある場合は上書き前に確認する

### Requirement: 整形で情報を追加しない
Default Promptは入力の意味、事実、数値、日付、固有名詞を変更せず、情報追加、推測、要約を禁止しなければならない（SHALL）。

#### Scenario: 数字と固有名詞を含む
- **WHEN** 文字起こし結果に数字、日付、固有名詞が含まれる
- **THEN** 整形品質テストは出力で各要素が保持されることを要求する

### Requirement: 整形失敗時に原文を保持する
Formatterが失敗、タイムアウト、空結果、契約外応答となった場合、アプリは別Formatterへ切り替えず文字起こし原文を出力しなければならない（SHALL）。

#### Scenario: 外部Formatterが停止している
- **WHEN** 文字起こし成功後に外部Formatterへ接続できない
- **THEN** システムは原文を出力し整形を適用できなかったことを表示する
