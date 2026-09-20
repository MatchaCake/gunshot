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

- photosIntegration: qualityAvailable / syncAvailable、原本 enum の観測件数、原本確認済み写真の storagePolicy 値別観測件数（serverStoragePolicy&lt;N&gt;）、画質表示補正件数、差分同期要求件数、同期オブジェクト待ち件数（syncWaitingForAccount）。
- completionMonitor.uploadSummary（jailed では runtime.uploadSummary にも表示）: デフォルト画質、各ジョブの画質別・状態別件数と対応 profile、完了 revision。
- uploadSummary の profile は送信ポリシーです。実メディアのサーバー側品質を一括で検証した意味ではありません。
- アカウント、ファイル名、mediaKey、ハッシュ、トークンは追加診断に含めません。

テストは、手動 UI → 共通要求 → Go の完了 → 純正完了、原本 enum による表示分岐、
容量文言の保持、アカウント別の差分同期、永続完了 revision の保持を検証します。
実機の画面更新タイミングと全メディア形式のサーバー情報は端末での確認が必要です。
