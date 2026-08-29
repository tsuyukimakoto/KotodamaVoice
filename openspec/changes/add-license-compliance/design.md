## Context

`whisper.cpp`と`llama.cpp`は固定revisionからXCFrameworkを生成し、各XPC Serviceへ動的Frameworkとして組み込んでいるが、生成物へ元のMIT Licenseをコピーしていない。
モデルManifestはライセンス名とURLを保持する一方、画面には名称だけを表示している。
OpenSpecが生成した`.agents/skills`も公開ソースに含まれるため、アプリに組み込まれない開発用成果物を含めて第三者通知を管理する必要がある。

## Goals / Non-Goals

**Goals:**

- リポジトリ、アプリ、DMGで必要になる文書を、レビュー可能な追跡対象ファイルから再現する
- 第三者成果物の固定revisionとライセンス文書の対応を機械的に検証する
- モデル取得前と、インストール後のオフライン環境の双方で利用条件を確認できるようにする
- ライセンス表示の追加によってマイク、Accessibility、ネットワークの権限要求を増やさない

**Non-Goals:**

- モデルファイルをアプリ、DMG、独自サーバーから再配布する仕組みは追加しない
- Runtimeとモデルの選定、固定revision、量子化方式は変更しない
- 商標調査、アイコンなどの素材来歴確認、未完了のV1品質試験は別の作業として扱う
- EULA、プライバシーポリシー、保証または有償サポート条件はこのchangeで新設しない

## Decisions

### KotodamaVoice本体にはMIT Licenseを適用する

リポジトリ直下の`LICENSE`をKotodamaVoice本体の正本とし、READMEから参照する。
MITは組み込むRuntimeのMITと両立し、Apache-2.0のモデルを利用者が配布元から取得する現在の構成とも矛盾しない。

代案としてApache-2.0を本体へ適用する方法もあるが、本体に明示的な特許条項を追加する要望はなく、利用条件を簡潔に保つため採用しない。

### ライセンス全文を追跡対象の`Licenses`ディレクトリで保持する

本体の`LICENSE`とは別に、第三者の原文をコンポーネント単位のファイルとして`Licenses`へ保存する。
リポジトリ直下の`THIRD_PARTY_NOTICES.md`は、コンポーネント名、用途、取得元、固定revision、ライセンス文書への索引を提供する。

ビルド時にインターネットや無視対象の`.build/runtimes/sources`から文書を取得する方式は、クリーン環境で通知を再現できず、上流の変更によって公開物が変化するため採用しない。

### 配布対象範囲を一つのManifestで管理する

追跡対象の第三者コンポーネントManifestに、ソース公開のみ、アプリ組み込み、モデル取得対象の範囲を記録する。
Runtime lockとModels ManifestのIDまたは固定revisionを参照し、通知文書が現在の依存対象と一致するかテストする。

コード内へ通知一覧を重複して直書きする方式は、revision更新時の更新漏れが起きるため採用しない。

### アプリは同梱文書を表示し、モデルでは公式URLも提供する

アプリのライセンス画面はBundle resourceに含めた文書を表示するため、オフラインで利用できる。
Models画面と取得確認は、同梱文書を優先して表示し、取得元が公開する公式URLも開けるようにする。
公式URLだけへ依存する方式はオフラインで組み込みRuntimeの条件を確認できないため採用しない。

ライセンス表示は既存画面から利用者が開いたときだけ表示し、新たな権限要求や自動通信を行わない。

### アプリ内とDMG直下の両方へ通知を配置する

Xcode resourceとしてアプリへ同梱する文書を正とし、DMG作成時は同じ追跡対象文書をDMG直下へコピーする。
配布検証はアプリBundleとDMGの内容をそれぞれ検査し、文書の欠落、想定外のrevision、Manifestとの不一致を失敗にする。

アプリ内だけに置く方法でもMITの表示条件を満たせる可能性はあるが、アプリを起動せず確認でき、配布物のレビューもしやすい構成を採用する。

## Risks / Trade-offs

- [上流のライセンス文書がrevision更新時に変わる] → Runtimeまたはモデルの更新時に原文hashと通知Manifestの更新を必須にし、不一致をテストで検出する
- [通知Manifest、Runtime lock、Models Manifestが重複する] → 通知Manifestはライセンスと配布範囲だけを保持し、版とrevisionは既存Manifestを参照して照合する
- [モデル提供元のURLが後から変わる] → 公式URLに加えて、採用時点のライセンス全文をBundleへ同梱する
- [アプリBundleへ文書を追加した後に署名が無効になる] → 文書をXcode resourceとして署名前に組み込み、署名後のBundleを変更しない
- [DMG検証のためmount処理が増える] → 一時mount先を限定し、必ずdetachする検証処理とfixtureテストを用意する

## Migration Plan

1. 本体と第三者のライセンス正本、通知Manifestを追跡対象として追加する。
2. 既存のRuntime lockとModels Manifestが通知Manifestに完全に対応することを失敗テストで固定する。
3. アプリへ文書表示とモデル取得前の確認操作を追加する。
4. Xcode resource、DMG作成、配布検証を同じ通知Manifestへ接続する。
5. Unit Test、UI Test、配布fixture検証、OpenSpec strict validationを完了してから新しいRelease成果物を署名、公証する。

ロールバック時はライセンス対応前の成果物を公開せず、公開済みReleaseがある場合は修正版で置き換える。署名済みアプリへ後から文書を追加しない。
