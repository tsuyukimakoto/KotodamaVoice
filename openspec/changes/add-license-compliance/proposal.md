## Why

KotodamaVoiceをパブリックリポジトリと署名済みアプリとして公開するには、プロジェクト本体の利用条件と、組み込む第三者成果物および取得対象モデルのライセンス条件を、ソースと配布物の両方で確認できる状態にする必要がある。
現在は本体ライセンスが未定義で、配布アプリにwhisper.cppとllama.cppのMIT表示が含まれず、モデル画面からライセンス本文へ到達できない。

## What Changes

- KotodamaVoice本体をMIT Licenseで公開し、リポジトリ直下で著作権表示と利用条件を明示する
- 追跡する第三者成果物と、アプリへ組み込むRuntimeの名称、固定revision、著作権表示、ライセンス本文を一元管理する
- アプリとDMGに第三者ライセンス表示を同梱し、配布検証で欠落や不整合を失敗として扱う
- モデル取得前に、取得元、固定revision、ライセンス名、ライセンス本文または公式URLを利用者が確認できるようにする
- READMEと開発者向け文書を、採用ライセンスと配布時の表示義務に一致させる
- モデル本体をアプリまたはDMGへ同梱すること、依存Runtimeやモデルの選定を変更すること、商標調査や素材の権利確認を完了扱いにすることはこのchangeの対象外とする

## Capabilities

### New Capabilities

- `license-compliance`: プロジェクト本体、第三者Runtime、生成済み開発支援ファイル、取得対象モデルについて、ソース公開と直接配布で必要なライセンス表示および検証を扱う

### Modified Capabilities

なし。

## Impact

- リポジトリ直下のライセンス文書と第三者通知文書
- Xcode resource設定とアプリ内のライセンス表示
- Models画面およびモデル取得確認
- `Resources/Models.json`とRuntime lockに紐づくライセンス情報
- DMG作成処理と直接配布検証スクリプト
- README、PROJECT_STRUCTURE、関連テスト
