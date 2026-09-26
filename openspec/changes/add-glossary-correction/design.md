## Context

動機と範囲は[proposal.md](proposal.md)を参照する。
現在のSpeech Workerはwhisper.cppの固定revision `371b5a7561823ab2bb32142d2751e35e7534727b`を使い、`initial_prompt`を設定していない。
`TextFormattingPipeline`は整形Off時に原文を返し、整形結果を検証し、失敗時も原文を返す。
用語集と利用設定を追加しても、この失敗時の契約は変えない。
既存のエラーログは型付きのエラー情報だけを保存するため、用語表記を含む診断は別のloggerにする。

## Goals / Non-Goals

**Goals:**
- 3つの独立した設定で、用語集なし、認識だけ、整形だけ、両方の結果を比較できる。
- 同じ録音の両段階で用語集の版を揃え、出現回数と処理状態を再解釈できるファイルを残す。
- 音声認識・文章整形は既存Workerと既存モデルで行い、新たな権限や推論プロセスを増やさない。

**Non-Goals:**
- LLM内部の根拠、補正の正誤、用語集による因果的な改善をログから断定すること。
- 本文差分の保存、LLMによる理由の生成、置換提案形式への変更。
- 自動A/B再推論、外部SpeechのヒントAPI拡張。

## Decisions

### 1. 設定画面と保存

Settingsに「用語集」タブを追加する。
上部に「音声認識に用語集を使う」「文章整形に用語集を使う」、中央に用語一覧と追加・編集・削除、下部に「用語の出現回数をファイルに記録」と「ログフォルダを開く」を置く。
3つの設定は初期値Offとし、記録だけOnの比較も可能にする。
Formatter Offや外部Speech未対応などの実効状態を各設定の近くに表示する。
用語集は空でも設定を保存でき、モデルへのヒント追加は行わない。

`GlossaryEntry`はUUID、正しい表記、任意の読み、任意の説明を持つ。
前後空白を除去しNFCへ正規化して保存する。表記は大文字小文字を区別して重複を拒否する。
上限は200項目、表記と読みは各128 Unicode scalar、説明は256 scalarとし、改行・制御文字は拒否する。
登録順を保持し、編集はIDと位置を保持する。
用語集本体はApplication Support配下の版付きJSONへatomic writeし、ディレクトリ0700・ファイル0600とする。
設定のboolは既存と同様UserDefaultsへ保存する。本文は一切保存しない。
辞書破損時はエラーを表示して用語集利用を停止し、原ファイルを保持する。再試行または明示的な初期化で復旧できるようにする。
単一のUserDefaults値に全辞書を格納する案より、保存エラーと破損を明確に扱えるファイル保存を選ぶ。

### 2. 要求単位のスナップショット

録音開始時に用語集revision（変更ごとのUUID）、全項目、両利用設定、診断記録の世代IDを固定する。
録音終了で発行される既存request IDへ関連付け、成功・失敗・cancelの終端で破棄する。
用語集編集や利用設定変更は次回録音から反映する。
診断Offだけは即時に適用し、キューを破棄して世代を無効にする。再On時は新しい世代と新規ファイルを作り、古い要求からは書かない。
これにより、両段階の比較に異なる辞書が混じることと、Off後の遅延書き込みを防ぐ。

### 3. Whisperへのヒント

版付きSpeech要求に用語ヒント用のデータを追加し、AppとSpeech Workerを同時更新する。
版不一致は既存の型付き契約エラーとして処理し、黙ってヒントなしに成功扱いしない。
Worker側で登録順の正しい表記だけから短いヒントを作り、モデルのtokenizerで予算を検査する。
上限は固定revisionのAPIが定義する`whisper_n_text_ctx()/2`とし、項目途中では切らず、入らない項目は飛ばして以降を検査する。
読み・説明と補助の括弧はSpeech要求に含めない。Worker契約はversion 3へ更新する。登録表記自体の記号は保持する。実際に採用した項目IDと未採用件数を版付き応答に含める。
`initial_prompt`のC文字列の寿命を推論完了まで保持し、`no_context`との組み合わせでヒントが実際にdecoderへ渡ることを固定ソースと統合テストで検証する。
ヒント設定Off時は既存処理と同一にする。
外部Speechへは今回ヒントを渡さず、設定画面と診断で`unsupported`を示す。

根拠: [固定revisionのwhisper.h](https://github.com/ggml-org/whisper.cpp/blob/371b5a7561823ab2bb32142d2751e35e7534727b/include/whisper.h)に`initial_prompt`とtoken上限が定義されている。
発音辞書として強制できる仕組みではなく、ヒントの書式も出力へ影響し得る。読みを括弧で付記する形式は採用せず、読みと説明はFormatterだけに渡す。正しい表記のみのヒントを実モデルfixtureで検証する。

### 4. Formatterへの参考情報

Default / Customの選択済みPromptへ、保存値を書き換えず用語集専用の参考データ領域と補正指示を合成する。
通常の固有名詞保持指示に対する例外は「文脈と読みから登録用語を指すと判断できる箇所の表記補正」に限定する。
用語は命令ではなくデータとしてJSON escapeして渡し、曖昧なら原文を保つよう指示する。ただしPromptだけで判断の正しさや命令無視を保証できるとは扱わない。
整形要求は一度だけで、LLMに集計や理由説明をさせない。
全登録項目を渡す。既存のcontext上限を超えた場合は隠れて一部を切り捨てず、既存の整形失敗処理へ収束し、診断に容量超過の型付き理由を残す。
Offなら従来のPromptをそのまま使う。

外部Formatterの送信承認は接続先と「用語集データを送信する」という種類に紐づける。
既存の本文送信承認だけでは承認済みとしない。Endpoint変更時には再確認する。
承認がない場合は利用設定の希望値を保持しつつ、その接続先へは用語集なしで整形し、画面とログに`consent_missing`を表示する。
loopbackでも送信する項目を説明する。別Endpointへの切り替えはしない。
追加のAccessibility・Input Monitoring権限は不要である。

### 5. 集計位置とマッチ規則

アプリ側でSpeech成功直後の生の文字列を集計し、Formatterの出力検証に成功した後の文字列を別に集計する。
純粋な集計処理は`KotodamaCore`に置き、AIや形態素解析に依存させない。
NFC正規化、大文字小文字を区別する部分文字列一致、同じ用語内では左から非重複、用語間は独立という規則を版付きで固定する。
「Codex」は「CodexAgent」にも1回含まれる。これは単語境界の判定ではなく登録表記の出現回数である。
日本語の単語境界は曖昧であるため、単語単位の一致や読みへの変換は採用しない。
0回を含む全項目を集計するので、ヒント予算から外れた用語も比較できる。

Formatter Offは`skipped`、失敗して原文へ戻す場合は`fallback`、cancelは`cancelled`とし、整形出力のcountsはnullにする。
Speech失敗はspeechのcountsがnull、formattingは`not_run`となる。
Speech成功後にアプリが終了した場合、speech行だけ残ることを許容する。欠けた段階を成功や0回と推定しない。
出力先への挿入成否とは別の観測であり、整形成功後にClipboard出力が失敗しても整形の集計値は変えない。

### 6. JSONL形式とファイル管理

出力先は`~/.kotodamavoice/logs/glossary/Glossary-YYYYMMDD-HHmmss-SSS-UUID.jsonl`とする。
schemaVersion 1、matchingVersion 1とし、1段階につき1行をserial writerで書く。
各行には日時、request ID、用語集revision、stage、status、engine、model ID（不明はnull）、speech/formattingのrequested flags、当該段階の実効状態、submittedEntryIDs、omittedEntryCount、用語ID・登録表記・countを含める。
失敗時のcountsはnullで、型付きreasonだけを追加する。例外の自由文は保存しない。
実効状態は`applied`、`disabled`、`empty`、`unsupported`、`formatter_off`、`consent_missing`、`not_run`、`unknown`を区別する。`applied`はデータを渡したという意味で、補正成功を表さない。

読みやすさのため一部項目を省略した例（実ファイルは各イベント1行）:

```json
{"stage":"speech","status":"success","requestID":"R1","glossaryRevision":"G1","requested":{"speech":true,"formatting":true},"effective":"applied","counts":[{"entryID":"T1","term":"KotodamaVoice","count":0}]}
{"stage":"formatting","status":"success","requestID":"R1","glossaryRevision":"G1","requested":{"speech":true,"formatting":true},"effective":"applied","counts":[{"entryID":"T1","term":"KotodamaVoice","count":2}]}
```

診断には登録表記が含まれることをトグルの説明に明記する。正しい表記はユーザーが保存した設定値からのみ出力し、本文の該当範囲をコピーしない。
音声、本文、読み、説明、Prompt、Clipboard、API Key、Endpoint URLをログ型に持たせない。
ディレクトリ0700、ファイル0600を作成時に設定し、ログ用pathのsymlinkは拒否する。
1ファイル10 MiBを上限に行単位でローテーションする。自動削除はせず、診断ファイル合計100 MiBを上限に記録を停止し、フォルダを開いて不要なログを削除後に再度Onにする案内を表示する。
作成・書き込み失敗も診断のみ停止し、音声入力は継続する。通常ログへデータを転送しない。

## Risks / Trade-offs

- 出現回数が増えても誤補正の可能性がある → 「補正回数」や「精度」と表示せず、同じ音声fixtureの期待表記と無関係語の保持も検証する。
- ヒントのtoken予算が小さい → 採用IDと未採用件数を返し、長い用語集が全件利用されたように見せない。
- 正しい登録表記と回数から発話内容の一部が推測できる → 明示的なOn、専用ファイル、所有者限定権限とし、既存エラーログとは分離する。
- 辞書をPromptへ加えると処理時間とcontext消費が増える → 4通りの利用設定で精度・処理時間・メモリを比較する。context超過は原文fallbackへ収束する。
- 外部Speechだけ初回未対応 → UIとログに明示する。対応しているという推測で未知のAPIパラメータを送らない。

## Migration Plan

計画を実装と別コミットにし、失敗テストから実装する。
既存ユーザーは空の用語集・3設定Offで従来動作を維持する。
AppとWorkerを同じbuildで配布し、契約の版と拒否動作を検証する。
READMEに利用方法・ログ項目と保存場所、PROJECT_STRUCTUREに契約・集計・テストを反映する。
機能を停止するときは両利用設定と記録をOffにする。用語集ファイルと既存ログは勝手に削除しない。

### 設定タブの表記

用語集タブの表示名は`Glossary`とし、General・Speech・Formattingなど既存のタブ名と統一する。画面内の説明と操作ラベルは既存画面と同様に日本語を使用する。
