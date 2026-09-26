# KotodamaVoiceを開発するAIエージェントへの指示

この文書には、AIエージェントがKotodamaVoiceを変更するときに守るプロジェクト固有のルールを記載する。
一時的な作業状況、変更履歴、未完了タスクは記載しない。

## 仕様と実装の順序

- 現在の要件と設計判断はOpenSpecを正とする
- 振る舞いを変更する前に、対応するOpenSpec changeのspec、design、tasksを整合させる
- 計画文書と実装は別のコミットに分け、計画をコミットしてから実装を始める
- 実装では失敗テストを先に追加し、期待した理由で失敗することを確認してから修正する
- 実装後は関連するUnit Test、統合テスト、UI Test、OpenSpec strict validationを実行する
- OpenSpecのタスクは、そのタスクに書かれた確認が完了してから完了にする

## 設計上の制約

- KotodamaVoiceはmacOS 14以降のApple Silicon Macを対象とする
- 通常利用ではDockアイコンを表示せず、メニューバーから操作できる状態を保つ
- グローバルショートカットはAccessibility権限とInput Monitoring権限を使わずに登録する
- SpeechとFormattingのローカル推論は、別々のXPC Serviceで実行する
- `KotodamaCore`をAppKit、AVFoundation、whisper.cpp、llama.cppへ依存させない
- whisper.cppはSpeech Workerだけへ、llama.cppはFormatter Workerだけへリンクする
- XPCの要求と応答には版付き契約とrequest IDを使い、timeout、cancel、接続中断を一度だけ完了する結果へ収束させる
- XPC分離によって障害を追いにくくしないよう、本文を含まない統一ログとRuntime Monitorからrequest ID単位で追跡できる状態を保つ

## データと権限

- 試験用のドメイン名が必要な場合は `www.tsuyukimakoto.com` を使用する。`example.com` など別のドメインを使わない。HTTP通信の統合テストにはloopbackのfixture serverを使用する。

- 音声、文字起こし本文、Promptへ連結した本文、整形本文、Clipboard内容を履歴、UserDefaults、通常ログへ保存しない
- API KeyはKeychainにだけ保存する
- ローカルのSpeech処理で録音音声を外部へ送信しない
- ローカルのFormatting処理で文字起こし結果とPromptを外部へ送信しない
- 外部Endpointは利用者が明示的に設定した接続先だけを使用し、別のEndpointへ自動で切り替えない
- loopback以外へ送信する前に、送信するデータと接続先を利用者へ表示する
- マイク権限は最初の録音操作まで要求しない
- Accessibility権限は利用者がAuto Insertを選択したときだけ要求する
- Clipboard出力ではAccessibility APIへアクセスしない
- Auto Insertの対象を再検証できない場合は既存入力を変更せず、Clipboardへ出力する

## モデルとRuntime

- モデルは版、取得元、revision、ファイル名、容量、SHA-256、ライセンス、対応RuntimeをManifestで固定する
- モデルをInstalledとして扱う前に、容量とSHA-256を検証する
- モデル管理機能から実行ファイル、dylib、スクリプト、Pythonコード、remote codeを取得または実行しない
- 使用中モデルは対応Workerのunload成功後にだけ削除する
- 推論Runtimeは`Config/runtime-lock.json`の固定revisionから再現可能な手順で生成する
- Runtimeまたはモデルの選定を変える場合は、互換性、ライセンス、品質、処理時間、メモリ使用量、失敗時の動作を確認する

## Xcodeプロジェクトと署名

- `KotodamaVoice.xcodeproj`の構成を変える場合は`project.yml`を編集し、XcodeGenで再生成する
- App、Speech Worker、Formatter WorkerのApp Groupを一致させる
- 署名や配布設定を変更した場合は、アプリだけでなく埋め込まれたFramework、dylib、XPC Serviceも検査する
- 証明書の秘密鍵、App用パスワード、API Key、認証トークンをリポジトリへ保存しない

## ドキュメント

- `README.md`には利用者が必要とする概要、操作、権限、データの扱いを記載する
- `PROJECT_STRUCTURE.md`には開発環境、構成、ビルド、署名、テストを記載する
- この文書にはAIエージェントが将来の変更でも使う判断基準だけを記載する
- 作業報告、変更履歴、移行手順、完了チェックリストをドキュメントとして追加しない
- 実装とドキュメントが一致しない場合は、現在の仕様と実装を確認して同じ変更の中で整合させる
