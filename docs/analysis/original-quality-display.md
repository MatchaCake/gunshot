# 初代 Pixel の原本と iPhone の画質表示

## upstream の照合

2026-09-12 に以下を確認しました。

- [gotohp api.go](https://github.com/xob0t/gotohp/blob/0637c745dc590d74766b24eac80d689d2248e766/backend/api.go): original は Pixel XL、field 7=3、field 10=1。
- [PhotosBackup GPMCClient.swift](https://github.com/g8row/PhotosBackup/blob/c3fff29/GPMC/Core/GPMCClient.swift): commitProfile と commit の同じ組合せ。
- [PhotosBackup #11](https://github.com/g8row/PhotosBackup/issues/11): iPhone の Storage Saver 表示に対し Web は Original、ダウンロード後のサイズも元と同じという報告。開発者もモデル由来の表示差と説明しています。サイズ一致だけでは byte 一致を証明しません。
- 本プロジェクトの利用者も今回の写真について Web のオリジナル画質表示を確認。

Pixel XL は Pixel 2 ではなく初代 Pixel 系です。今回 profile や課金設定は変更して
いません。容量不使用を維持するために通常 quota モードへ切り替える必要はありません。
この照合は将来の非公式 API 動作やすべてのメディアの品質・容量計上を保証しません。

## 7.92.0 の直接確認

ローカル IPA の GooglePhotos framework を確認しました。IPA やバイナリは本リポジトリに含めません。

| 対象 | 確認結果 |
| --- | --- |
| uploadQuality enum | Unknown=0, OriginalBytes=1, CompressedOriginal=2, Thumbnail=3。文字列・値列は file offset 0x5e1e0ec 付近 |
| hasOriginalBytes enum | Unknown=0, Yes=1, No=2, Maybe=3。文字列・値列は file offset 0x5dfabb2 付近 |
| PHSServerPhoto.initWithMCMediaItem: | 0x124c7d8 付近でサーバーの hasHasOriginalBytes / hasOriginalBytes を確認・保存 |
| PHSServerPhoto.hasOriginalBytes | C16@0:8、0x124deb4。保存された enum を返す |
| PHSServerPhoto.storagePolicy | quotaInfo.storagePolicy 由来。0x124cbb4 で保存 |
| getBackupStatusModelData | main binary 0x1031620e0。quotaChargeable / quotaChargedBytes で容量文言を作り、0x103162228 の storagePolicy で画質文言を作る |
| PHSUserItemsSynchronizer.fetchData | 0x909f38 → fetchWithType:0。アプリ所有の同期キュー・server store を利用 |

## 表示補正の条件

純正の詳細画面が既にバックアップ済みと判断し、サーバーモデルが
hasOriginalBytes=Yes、部分バックアップではない場合に、
詳細画面の subtitle を「オリジナル画質（原本データあり）」にします。
容量を示す backupStatus は純正の値をそのまま維持します。

以前は storagePolicy=Standard の場合だけに限定していましたが、容量非消費の
Pixel 系アップロードでは hasOriginalBytes=Yes でも storagePolicy が Standard
以外になり、「保存容量の節約」のまま残る事例を実機診断で確認しました
（v0.2.4 で serverOriginal は計上されるのに補正が発生しない）。
hasOriginalBytes はサーバー自身の原本モデルであり、storagePolicy は容量課金の
ポリシーです。判定は原本モデルだけに依存し、観測した storagePolicy 値は
serverStoragePolicy&lt;N&gt; として診断に記録します。storagePolicy は任意の診断用 API
であり、selector が存在しない場合や型が一致しない場合も、原本情報の ABI が
一致すれば表示補正を行います。バージョン番号は動作条件に使いません。

バックアップ連携（純正バックアップの GoToHP 経由）の有効・無効は表示補正に
影響しません。判定はサーバーが返す原本情報だけに依存するため、GoToHP 画面や
共有シートからの手動アップロードでも、連携を無効にしたままでも補正されます。
以前は連携が有効な場合だけ補正していたため、既定設定（連携オフ）では原本
確認済みの写真も「保存容量の節約」のまま表示されていました。

No / Unknown / Maybe、未バックアップ、部分バックアップは変更しません。GoToHP の
設定が original という理由だけで成功・画質表示を変更する処理はありません。
サーバーから原本情報が取得できない写真では、元の表示のままになる場合があります。

## 詳細スタックの行（v0.2.5 実機診断後の修正）

v0.2.5 の実機診断では `qualityLabelCorrected` が 10 件計上されているにもかかわらず、
詳細画面は「保存容量の節約」のままでした。getBackupStatusModelData の subtitle 置換は
実行されていますが、7.92.0 の詳細画面が表示する行はそこから作られていません。
7.92.0 の索引では、詳細コントローラに次の別経路があります。

| selector | ABI | 役割 |
| --- | --- | --- |
| `createStackViewModelsForExtendedPhoto:preferredMediaItem:` | `@32@0:8@16@24` | 詳細スタック全体を構築 |
| `createBackupViewModel:mediaItem:serverPhoto:localAsset:storeResult:` | `@56@0:8@16@24@32@40@48` | バックアップ行（`PHSOneUpInfoPanelDetailsStackViewModel`）を構築 |
| `updateBackupStatusUI` | `v16@0:8` | `backupStatusViewModelID` で追跡している行を後から更新 |
| `PHSExtendedPhoto.serverStoragePolicy` | `i16@0:8` | クライアント側 enum。`quotaTransparencyServerStoragePolicy` flag と対応 |

行の画質文言は、この工場が `PHSServerPhoto.storagePolicy`（または派生する
`serverStoragePolicy`）から自分で組み立てています。BackupStatusData の subtitle は
使いません。そのため置換件数が増えても表示は変わりませんでした。

### 修正

1. **表示スコープ**: 上記 3 つの工場が同一スレッドで実行中に限り、
   `PHSServerPhoto.storagePolicy` は原本確認済み（hasOriginalBytes=Yes、部分
   バックアップでない）の写真についてオリジナル画質のポリシー（2。7 を参照。
   6 回目の診断までは誤って Standard＝1 を返していた）を返します。純正の文言と
   ローカライズがそのまま使われます。スコープはコントローラが `isBackedUp` を
   返す場合だけ開きます。保存値、同期、アップロード、他の画面、我々自身の
   診断読取（`serverStoragePolicy<N>`）には影響しません。
2. **文字列フォールバック**: 工場が返した行の title / attributes に、同じ
   コントローラの純正 subtitle（getBackupStatusModelData の元実装から取得）と
   同じ文言が含まれる場合、その部分だけを「オリジナル画質（原本データあり）」に
   置き換えます。Google の文字列キーや言語の決め打ちはしません。
   `updateBackupStatusUI` の後も追跡中の行に同じ処理を行います。

3. **クライアント enum**: 最初の実機診断（2026-09-24、4 行構築）では
   `displayPolicyOverrides=12`（storagePolicy は行ごとに 3 回読まれ全て置換）にも
   かかわらず表示は変わらず、`displayServerPolicyReads=4` / `displayServerPolicy1=4`
   でした。`PHSExtendedPhoto.serverStoragePolicy`（`i16@0:8`）は読み込み時に保存
   されたクライアント enum（アップロード commit の field 7 と同じ値: 1=節約、
   3=オリジナル）で、storagePolicy の getter から再導出されません。行の画質文言は
   この値から作られています。同じスコープ内で、原本確認済みの写真については
   3 を返します（`displayServerPolicyOverrides`）。

4. **レイアウト時のラベル補正**: 2 回目の実機診断（10 行構築）では 3 つの getter が
   すべて置換され（`displayPolicyOverrides=30`、`displayServerPolicyOverrides=10`）、
   `stackRowCorrected` は 0 のまま、表示は「保存容量の節約」のままでした。行モデルは
   純正文言を平文で保持しておらず、文言の出所は静的索引だけでは特定できません。
   そこで詳細コントローラの `viewDidLayoutSubviews`（UIViewController から継承、
   このクラスだけに追加）と行構築・`updateBackupStatusUI` の直後に、ビュー階層の
   UILabel / UITextView を走査し、このコントローラの純正画質文言を含む部分だけを
   置き換えます。attributed text は属性を保持します。置換後は文言を含まないため
   再レイアウトで収束します。診断 `panelTexts` には走査したラベル文字列（数字は `#`、
   `/` やファイル拡張子を含むものは除外、60 文字まで、最大 16 件）と
   `native-quality:` 付きの純正文言を記録します。`panelWalks` / `panelLabelsSeen` /
   `panelLabelCorrected` で走査・発見・置換件数を示します。

5. **HTML subtitle と入れ子の行モデル**: 3 回目の実機診断（7 行構築、41 回走査）では
   `panelLabelsSeen=34`（走査 1 回あたり 1 未満）、`panelTexts` は `Details` のみで、
   走査のたびに記録されるはずの `native-quality:` も欠落していました。記録から外れる
   のは `/` を含む文字列だけなので、純正 subtitle はヘルプリンク付きの HTML です。
   HTML の文字列がそのまま描画文字列に現れることはないため、2 と 4 の照合は常に
   失敗していました。行は UIKit のラベルではなく Swift 側で描画されています。
   現在は次の候補を順に照合し、最初に一致したものだけを置き換えます。
   - 純正 subtitle と、表示スコープ内（画質 getter 置換中）で作った subtitle の差分部分。
     差分の境界が語の途中にある場合は使いません（ローカライズされた画質語そのもの）。
   - リンクを除いた平文、末尾記号を除いた平文、リンクを含む平文、元の文字列。
   リンク文字列（「詳細」など）だけが候補になることはありません。置換対象は行の
   `title` / `attributes` / `expandedContent` と、その中の属性モデルの
   `text` / `title` / `subtitle` / `attributedText` です。
   診断 `rowTexts` には候補（`candidate:`）と置換前の行構造
   （`row.attributes[0].text<str>: …` のようなパスと型）を、`panelViewClasses` には
   走査したビューのクラス名を記録します。リンクの URL とタグは伏せ字にします。

6. **節約文言の学習と全行補正**: 4 回目の実機診断では `native-quality` が
   「Original quality. Learn more」（storagePolicy=2 の容量非消費 Pixel 原本）で、
   バックアップ行は `Backed up • No storage used` だけを持っていました。純正 subtitle
   が既にオリジナル表示なので、5 の候補はすべてオリジナルの文言を探しており、
   「Storage saver」は一度も照合されていませんでした。また詳細行は SwiftUI
   （`OneUpInfoPanelDetailsStackView`）で描画され、UILabel は見出しだけです。
   - 純正 `getBackupStatusModelData` を storagePolicy 0〜6 で再構築し、Standard の
     subtitle と異なる語（ローカライズされた非オリジナル文言）を学習します
     （`saverWordingsProbed`、`rowTexts` の `saver:`）。取得できない場合は既知の
     Google 文言（Storage saver / 保存容量の節約 / 节省空间 等）を使います。
   - バックアップ行だけでなく詳細スタックの全行を補正します。
     `setDetailsStackViewModels:`（`stackModelAssignments`）、行構築の戻り値、
     `updateBackupStatusUI`、レイアウト時に適用し、`rowTexts` に `rows[N]` の構造を
     記録します。置換後の文言に含まれる候補（英語の「Original quality」）は
     再置換で伸び続けるため使いません。
   - SwiftUI は工場の後に描画するため、`PHSExtendedPhoto.serverStoragePolicy` は
     メインスレッドでスコープ外でも、直近にスコープを開いたバックアップ済み
     詳細画面の写真で原本確認済みの場合に限り 3 を返します
     （`displayServerPolicyReadsOutside` / `displayServerPolicyOutsideOverrides`）。
     他の写真、他スレッド、未バックアップの画面は純正値のままです（7 で変更）。

7. **ポリシー対応の訂正と全インスタンス補正**: 6 回目の実機診断（22 行構築、
   124 回走査）では `saver:` に「Original quality」「Express」が学習されていました。
   学習は Standard（1）の subtitle を基準に差分を取るので、「Original quality」が
   差分に出るということは policy 1 の文言はオリジナルではありません。写真の純正値は
   2（`serverStoragePolicy2`）で純正 subtitle は「Original quality」、
   GooglePhotos_GeneratedFramework には `photosConvertToStandardStoragePolicyRPC`
   （「容量を解放」＝オリジナルを節約画質へ変換する RPC）があり、Standard は
   Storage saver のポリシーです。1〜6 回目のビルドは行工場内で 1 を強制し、Google
   自身のコードに節約文言を作らせていました。ただし 9/23 の最初の診断（v0.2.5、
   上書きなし、純正値 2）でも表示は節約だったので、これが唯一の原因ではありません。
   - 表示スコープ内の `storagePolicy` は原本確認済みなら 2 を返します（純正が 2 なら
     無変更）。節約文言の学習も policy 2 の subtitle を基準にします。
   - `serverStoragePolicy`: スコープ内 336 読取が全て置換され、スコープ外メイン
     スレッドの読取は 0 件、それでも表示は節約でした。以前の規則が数えずに除外して
     いた読者（同じ写真の別 `PHSExtendedPhoto` インスタンス、別スレッド）しか残り
     ません。観測された唯一の節約値であり hasOriginalBytes はサーバー自身の原本
     モデルなので、サーバー写真が原本確認済みの全インスタンスで全スレッド 3 を
     返し、読取箇所を `displayServerPolicyReads` / `...ReadsOutside` /
     `...ReadsOtherInstance` / `...ReadsOffMain` と対応する `...Overrides` で数えます。
   - レイアウト時に `layout-rows[N]`（工場後に設定された expandedContent を含む）、
     `info[N]`（`infoContentViewModels`）、`localAssetInfo`、`learnMoreLinks`
     （`stackViewLearnMoreLinks`）の構造を `rowTexts`（上限 96）に記録し、
     全モデルに文言補正を適用します。`PHSExtendedPhoto.needsFullBackup` の読取を
     `needsFullBackup{Original,}{Yes,No}` で数えます（値は変更しません）。

8. **行モデルの initializer 補正**: 7 回目の実機診断（23 行構築、127 回走査）では
   `storagePolicy` は純正 2（オリジナル）、`serverStoragePolicy` はスコープ内 346 読取が
   全て 3 に置換、スコープ外・別インスタンス・別スレッドの読取は 0 件、行モデルの
   `title` / `attributes` / `expandedContent` に節約文言は無く、UILabel は「Details」
   だけで、それでも表示は「Storage saver」でした。7.92.0 の索引では
   `PHSOneUpInfoPanelDetailsStackViewModel` に `initWithTitle:subtitle:` /
   `initWithTitle:subtitle:icon:` があるのに `subtitle` の getter が存在しません。
   subtitle は Swift 側の保持値で、詳細スタックが直接描画します。工場がこの
   initializer に渡す値だけが文言の入口なので、そこで補正します。
   **2026-09-24 に実機（7.92.0、jailed）で「オリジナル画質」表示を確認しました。**
   1〜7 は単独では表示を変えず、8 が必要でした。
   - 表示スコープ内（原本確認済みの詳細コントローラの工場実行中）に限り、渡された
     subtitle / title に学習済み・既知の節約文言が含まれれば、その部分だけを
     置き換えます（`initCorrected.subtitle` / `initCorrected.title`）。純正文言の
     再構築（probe）や入れ子読取、スコープ外の生成は無変更です。
   - 渡された値は `rowTexts` に `init.subtitle<str>: …` / `init.title<str>: …` として
     記録します（伏せ字規則は同じ）。行 id（UUID）は `<uuid>` に畳んで記録件数を
     節約し、`rowTexts` の上限を 128 にしました。
   - SwiftUI の描画文字列は UILabel に無いため、走査中に見つけた Hosting view の
     accessibility 要素の `accessibilityLabel` / `accessibilityValue` を `panelTexts`
     に `a11y: …` として記録します（`panelA11yElements`、上限 32 件）。次の診断で
     画面上の文言とその出所を直接突き合わせられます。

No / Unknown / Maybe、未バックアップ、部分バックアップでは、スコープも置換も
発生しません。`PHSServerPhoto.storagePolicy` や `serverStoragePolicy` の ABI が
一致しない場合、その getter だけを省略します。

### 診断

- `stackQualityAvailable`: 行工場と原本 ABI が一致し hook を設置したか。
- `stackBackupRows` / `stackBackupUpdates`: 行構築と後更新の回数。`stackRowClasses` は観測した行クラス名（最大 8 件）。
- `displayPolicyReads` / `displayPolicyOverrides`: スコープ内の storagePolicy 読取とオリジナル（2）への置換件数。`displayPolicyReadsOutside` / `displayPolicyReadsOffMain` はスコープ外の純正読取。
- `displayServerPolicyReads` / `displayServerPolicy<N>` / `displayServerPolicyOverrides` / `displayQuotaReads`: スコープ内で `serverStoragePolicy` / `quotaChargeable` が読まれた回数、観測値、3 への置換件数。
- `stackRowCorrected`: 文字列フォールバックが行を書き換えた件数。

実機では 1 の経路だけでは表示が変わらず、3 が必要でした。`displayServerPolicyOverrides`
が増えれば 3 の経路、`stackRowCorrected` が増えれば 2 の経路で補正されています。どちらも 0 で表示が変わらない場合は、上記の読取件数から
文言の出所を特定します。テストは storagePolicy 由来、serverStoragePolicy 由来、
純正 subtitle 複写の 3 種の文言源、スコープ外の読取が純正値であること、
入れ子の診断読取が純正値を数えること、未バックアップ・部分・No での不変を検証します。

## 差分同期の信頼性

完了通知の反映は、アプリ自身の PHSUserItemsSynchronizer に fetchData を依頼して
行います。以前は観測した同期オブジェクトを weak 参照で保持していましたが、
アプリは同期のたびにオブジェクトを解放するため、合流待ち（1 秒）の間に参照が
失われ、要求が syncWaitingForAccount のまま送信されない事例を実機診断で確認
しました（syncSignals は増えるのに syncRequested が発生しない）。現在は
アカウントごとに最新の 1 個だけを保持し、新しい観測で置き換えます。純正
データベースやバックアップ状態への書き込みは引き続き行いません。

純正 fetchData / fetchDataSoft の呼び出しは、同期完了やサーバー側の反映を
保証しないため、待機中の要求を取り消しません。1 秒後の合流済み要求を維持します。
同期は accountID と fetchData の ABI で判定し、fetchDataSoft の hook は任意です。

## 診断

- photosIntegration: qualityAvailable / syncAvailable、原本 enum の観測件数、原本確認済み写真の storagePolicy 値別観測件数（serverStoragePolicy&lt;N&gt;）、画質表示補正件数、差分同期要求件数、同期オブジェクト待ち件数（syncWaitingForAccount）、詳細スタック行の件数（上記「詳細スタックの行」）。
- completionMonitor.uploadSummary（jailed では runtime.uploadSummary にも表示）: デフォルト画質、各ジョブの画質別・状態別件数と対応 profile、完了 revision。
- uploadSummary の profile は送信ポリシーです。実メディアのサーバー側品質を一括で検証した意味ではありません。
- アカウント、ファイル名、mediaKey、ハッシュ、トークンは追加診断に含めません。

テストは、手動 UI → 共通要求 → Go の完了 → 純正完了、原本 enum による表示分岐、
容量文言の保持、アカウント別の差分同期、永続完了 revision の保持を検証します。
実機の画面更新タイミングと全メディア形式のサーバー情報は端末での確認が必要です。
