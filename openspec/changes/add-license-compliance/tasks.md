## 1. 本体ライセンスと第三者台帳

- [x] 1.1 本体LICENSE、第三者Manifest、通知文書、ライセンス原文の欠落とrevision不一致を検出する失敗テストを先に追加し、現在のリポジトリに必要な文書がない理由で失敗することを確認する
- [x] 1.2 `LICENSE`へKotodamaVoice本体のMIT Licenseと著作権表示を追加し、READMEから利用条件を確認でき、1.1の本体ライセンス検査が成功することを確認する
- [x] 1.3 whisper.cpp、llama.cpp、OpenSpec生成物、Whisperモデル、Gemma 4モデルのライセンス原文と出典を`Licenses`および`THIRD_PARTY_NOTICES.md`へ追加し、採用revisionの一次資料と一致することをhashと目視で確認する
- [x] 1.4 第三者コンポーネントManifestへ取得元、既存Manifest参照、ライセンス文書、原文hash、配布対象範囲を定義し、Runtime lockとModels Manifestの全対象が過不足なく対応して1.1のテストが成功することを確認する

## 2. アプリ内のライセンス表示

- [x] 2.1 ライセンス文書がBundleにない場合と、モデルのライセンス参照が不完全な場合の失敗テストを追加し、現在のresourceとモデル情報で期待した理由により失敗することを確認する
- [x] 2.2 第三者Manifestとライセンス文書をApp resourceへ追加するため`project.yml`を変更し、XcodeGenでプロジェクトを再生成して、Debug appのBundle内に全配布対象文書が存在することを検査する
- [x] 2.3 Settingsからオフラインで本体と第三者のライセンス全文を開ける画面を実装し、ネットワーク要求と新たな権限要求を発生させずに表示できるUnit TestとUI Testを成功させる
- [x] 2.4 Models画面とFormatterモデル取得確認に取得元、固定revision、ライセンス名、同梱文書および公式URLを開く操作を実装し、未導入モデルで取得開始前に確認できるUI Testを成功させる
- [x] 2.5 不完全なライセンス情報を持つモデルを取得不能にし、本文や秘密情報を含まない型付きエラーを表示するテストを成功させる

## 3. DMG作成と配布検証

- [x] 3.1 ライセンス文書が欠落したApp BundleとDMG fixtureを拒否する配布検証の失敗テストを追加し、現行スクリプトが欠落を検出しないことを確認する
- [x] 3.2 DMG作成処理へ追跡対象の第三者通知文書を追加し、生成したDMGをmountしてアプリを起動せず文書を読めることをfixture検証する
- [x] 3.3 App Bundle、DMG、第三者Manifest、Runtime lock、Models Manifestの対応を検査する処理を追加し、欠落、hash不一致、想定外revisionごとの失敗テストと適合fixtureの成功テストを確認する
- [x] 3.4 READMEとPROJECT_STRUCTUREを本体ライセンス、第三者通知の配置、依存更新時の検証手順、モデルを同梱しない配布条件へ合わせ、記載したパスとコマンドをクリーンcheckoutで確認する

## 4. 公開候補の検証

- [x] 4.1 関連するUnit Test、UI Test、配布fixtureテスト、全Test suiteを実行し、ライセンス対応による失敗がないことを確認する
- [x] 4.2 `openspec validate add-license-compliance --strict`を実行し、proposal、spec、design、tasksの整合性検証が成功することを確認する
- [ ] 4.3 Release archiveから新しいDeveloper ID配布物を作り、App、Framework、XPC Service、DMGの署名、Hardened Runtime、secure timestamp、ライセンス文書を検査する
- [ ] 4.4 公開候補DMGを公証してticketをstapleし、`stapler validate`、`spctl --assess`、DMG内ライセンス文書の目視確認がすべて成功した成果物だけを公開対象にする
