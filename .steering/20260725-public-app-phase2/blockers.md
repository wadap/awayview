# Blockers / 要確認 — 公開アプリ化 Phase 2

## 解消済み (2026-07-26)

- ~~Developer ID Application 証明書~~: Xcode から発行済み
  (`Developer ID Application: NANICA, K.K. (45F858C28S)`)
- ~~notarytool 認証情報~~: app-specific password は 401 が解消せず、
  **App Store Connect API キー方式**で解決 (プロファイル `awayview-notary`、
  キーは `~/.private_keys/AuthKey_427TJ9K2H4.p8`)
- ~~hardened runtime での CG / sysctl 動作~~: 署名済みバイナリで
  `--list-modes` / `--list-connections` とも動作確認済み。entitlements 不要

## 解消済み (2026-08-24)

- ~~実リモートでの自動切替 (Phase 1 からの持ち越し)~~: 実接続で検証完了。
  watch.log に `-> LOW (remote connection)` が計 30 回、往復も成立している。
  これで Phase 2 の受け入れ条件は全て達成:

  ```
  2026-08-22 15:53:13 -> LOW (remote connection)
  2026-08-22 18:14:19 -> HIGH (restored)
  2026-08-22 20:23:52 -> LOW (remote connection)
  2026-08-22 20:24:04 -> HIGH (restored)
  ```

## 未解決 (Phase 2 の受け入れ条件外・次フェーズ候補)

### 1. sysctl 失敗が「接続なし」に化ける (原因特定済み)

`!! complete configuration failed` が通算 180 件。うち **174 件が 3840x1620**
(= ホーム解像度) で、失敗しているのは *復帰* 方向。原因の連鎖:

1. `Sources/CShim/*.c:92` — `sysctlbyname("net.inet.tcp.pcblist_n", ...)` の
   2 回目の呼び出しが ENOMEM で失敗すると `return -1`。サイズ取得と本取得の
   間にソケットテーブルが 1/8 の余裕を超えて増えると起きる古典的レース。
   リトライが無い
2. `Sources/AwayView/ConnectionMonitor.swift:25` — `guard n > 0 else { return [] }`
   で **エラー (-1) と「接続 0 件」(0) を区別していない**。よって一過性の
   sysctl 失敗が「リモート接続なし」として観測される
3. `StateMachine.tick()` は remoteIP == nil の分岐で `ensureHigh()` →
   `restoreHome()`。しかし実際にはまだ画面共有セッションが生きているので
   CG が 3840x1620 を拒否 → `.failed`
4. `ensureHigh()` は失敗時 false を返し `last` を `.low` のまま据え置く
   (設計どおりの「失敗時前進禁止」)。結果、**10 秒ごとに静かに再試行し続ける**

2026-08-20 15:28:00〜15:37:42 は約 9 分間このループ。稀に適用が通ると
`-> HIGH (restored)` を記録し、次 tick で接続を再検知して 1〜9 秒後に LOW へ
戻る (フラッピング)。ユーザ影響は「復帰が遅れる/一瞬解像度が暴れる」程度で
機能不全ではないが、検知のミスが無音で増幅される構造になっている。

想定される修正 (未着手):
- CShim: ENOMEM 時にバッファを広げてリトライ (数回)
- ConnectionMonitor: エラーと 0 件を型で分離し、**エラー時は前 tick の判定を
  維持** (= 不明を「接続なし」に倒さない)
- StateMachine: 復帰の連続失敗をログに要約するか backoff を入れる

### 2. brew 移行で launch-at-login が孤児化 (解消済み・要再登録)

2026-08-23 02:48 の再起動後、AwayView が起動していなかった。`sfltool dumpbtm`
で判明:

```
Name: AwayView   Identifier: 2.com.wadap.AwayView
URL:  file:///Users/shwada/Applications/AwayView.app/   ← Phase 2 で撤去した旧パス
Disposition: [enabled, allowed, notified]
```

SMAppService の登録が旧 bundle パスを指したまま残り、brew 版
`/Applications/AwayView.app` は未登録だった。cask へ移行する全ユーザで
再現しうる。設定ウィンドウの「ログイン時に起動」を off→on すれば現行パスで
再登録される。旧 `ScreenshareRes` の login item も残骸として残っている
