## Why

独自の用語や特殊な読みを持つ名称を、誤認識の全パターンを手入力せず正しい表記へ近づけたい。
音声認識と文章整形で用語集を個別に利用し、各段階の出現回数を比較できるようにする。

## What Changes

- 正しい表記を必須、読みと短い説明を任意とする用語集の追加・編集・削除と永続保存を提供する。
- 「音声認識に用語集を使う」「文章整形に用語集を使う」「用語の出現回数をファイルに記録」の独立した設定を提供する。
- 内蔵Whisperへ正しい表記だけを用語ヒントとして渡し、内蔵・外部Formatterへ用語集を文脈補正の参考情報として渡す。
- 同一request IDについて、Speechの生の出力とFormatterの検証済み出力に含まれる各登録表記の回数を専用JSONLファイルへ記録する。本文、読み、説明、Promptは記録しない。
- 本機能は精度や因果関係を保証しない。出現回数を補正回数や正解数として扱わない。
- 初回の対象外は誤表記の強制置換、読みの自動生成、用語の自動学習、音声・本文の保存、外部Speechへの用語ヒント送信、モデル変更、追加推論による補正である。

## Capabilities

### New Capabilities

- `glossary-correction`: 用語集管理、段階別の利用設定、音声認識ヒントと整形時の文脈補正。
- `glossary-diagnostics`: 段階別の用語出現回数の集計、独立したファイル記録設定、失敗・プライバシー動作。

### Modified Capabilities

なし。`openspec/specs`にはまだmain specがない。既存changeの文章整形Off・失敗時の原文保持は維持し、新規capabilityとして追加する。

## Impact

`KotodamaCore`の用語モデル・集計と版付きSpeech XPC契約、`SpeechRuntime`、`AppRuntime`、`TextFormattingPipeline`、FormatterのPrompt組み立て、Settings、専用ファイルlogger、Unit・統合・UI Testが対象となる。
外部Formatterを利用する場合は用語集も送信データに加わるため、既存の外部送信確認を拡張する。
既存エラーログの許可項目は拡張せず、明示的に有効化する用語集診断ファイルを分離する。
