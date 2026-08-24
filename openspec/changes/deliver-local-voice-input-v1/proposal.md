## Why

KotodamaVoiceは、音声取得から文字起こし、文章整形、出力までをMac上で完結させ、日常的な文字入力として使える必要がある。
後から推論プロセス、モデル管理、権限、配布方式を継ぎ足す構成を避けるため、V1に必要な境界と運用機能を一つのchangeで定義して実装する。

## What Changes

- Apple Silicon搭載Mac、macOS 14以降で動作するメニューバーアプリを新設する
- グローバルショートカットによる録音開始と停止、マイク入力、状態表示を実装する
- whisper.cppを内蔵するSpeech XPC Serviceと、llama.cppを内蔵するFormatter XPC Serviceをアプリへ組み込む
- モデルManifest、ダウンロード、ハッシュ検証、ライセンス表示、削除、再取得を実装する
- 内蔵Speechと外部Speech、FormatterのOff、内蔵、外部を同じPipelineから利用できるようにする
- 初回にClipboardまたはAuto Insertを選択させ、Clipboardを権限不要の推奨選択肢として提供し、Auto Insertを選択した場合だけAccessibility権限を要求する
- 設定、Keychain、単一HUD、Runtime Monitor、通常のOSLogと明示的に有効化するエラーログファイルを実装する
- Developer ID署名、Hardened Runtime、Notarizationによる直接配布を成立させる
- 履歴DB、録音の永続保存、クラウドサービス固有連携、任意コードの取得実行、複数処理キュー、VAD自動停止はV1に含めない

## Capabilities

### New Capabilities

- `app-control`: メニューバー、グローバルショートカット、状態遷移、終了処理を扱う
- `audio-capture`: マイク権限、録音、音声形式、録音データの破棄を扱う
- `model-management`: モデルManifest、取得、検証、保存、削除を扱う
- `inference-workers`: SpeechとFormatterのXPC通信、ライフサイクル、障害回復、診断を扱う
- `speech-transcription`: 内蔵Whisperと外部Speech APIによる文字起こしを扱う
- `text-formatting`: FormatterのOff、内蔵LLM、外部API、Prompt、失敗時動作を扱う
- `text-output`: Clipboard、Auto Insert、安全なFallback、HUDを扱う
- `configuration-and-privacy`: 設定、秘密情報、ローカルと外部通信の区別、ログ方針を扱う
- `runtime-observability`: Worker、モデル、処理時間、リソースの必要時監視を扱う
- `distribution`: 署名、Hardened Runtime、Notarization、クリーン環境での導入を扱う

### Modified Capabilities

なし

## Impact

- macOSアプリ、Unit Test、UI Test、Speech XPC Service、Formatter XPC Serviceの各ターゲットを追加する
- whisper.cpp、llama.cpp、Metal、AVFoundation、ApplicationServices、Security、CryptoKitを利用する
- マイク権限を通常利用で要求し、Auto Insertを選択した場合だけAccessibility権限を要求する
- App Sandboxは使用せず、Hardened Runtimeと署名された内蔵コードだけを使用する
- モデルファイルの取得時とユーザーが設定した外部Endpointの利用時だけネットワーク通信が発生する
