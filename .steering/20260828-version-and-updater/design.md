# design — 版表示とアプリ内アップデート

- **Date**: 2026-08-28
- **Requirements**: ./requirements.md

## 全体像

新規コンポーネントは 4 つ。いずれも単一責務で、外部依存は protocol 越しに注入する
(既存の `StateMachine` が接続 / 表示 / 設定を protocol で観測しているのと同じ作り)。

| 型 | 責務 | 外部依存 |
|---|---|---|
| `AppVersion` | `CFBundleShortVersionString` の読み出しと SemVer 比較 | Bundle のみ |
| `InstallOrigin` | `homebrew` / `direct` の判定 | ファイル存在確認のみ |
| `UpdateChecker` | 最新 release の取得と現行版との比較 | `ReleaseFetching` (protocol) |
| `UpdateInstaller` | 取得 → 署名検証 → 置換 → 再起動 (`direct` のみ) | Security.framework |

## インストール元の判定

Homebrew の cask は app を **実体として** `/Applications/AwayView.app` へ移動し
(symlink ではない)、`<brew prefix>/Caskroom/awayview/<version>/` に管理記録を残す。
したがってバンドルの場所では判定できず、**Caskroom に自分のエントリがあるか**が信号になる。

- `/opt/homebrew/Caskroom/awayview` (Apple silicon) と
  `/usr/local/Caskroom/awayview` (Intel) の存在を見る
- 存在すれば `homebrew`、無ければ `direct`
- brew CLI は起動しない (sysctl 直叩きでシェルアウトを避けている既存方針に合わせる)
- prefix はテストのために注入可能にする

## チェックの流れ

- 起動 5 分後に 1 回、以降 24 時間ごと。最終チェック時刻は `SettingsStore` に持ち、
  再起動を繰り返しても過剰にチェックしない
- GitHub の未認証 API は 60 req/hr/IP。この頻度なら余裕がある
- 手動チェックはメニューの「更新を確認…」からいつでも可能
- 結果は三値の enum で返す。`Optional` にはしない (下記「設計判断」参照)

```
UpdateCheckResult
  .upToDate
  .available(Release)     // version, downloadURL, htmlURL
  .failed(String)         // 到達不能 / パース失敗 / rate limit
```

## 新版を見つけたときの導線

| インストール元 | メニュー表示 | クリック時の動作 |
|---|---|---|
| `homebrew` | 「v1.0.2 が利用可能 (brew)」 | `brew upgrade --cask awayview` を `NSPasteboard` へコピー |
| `direct` | 「v1.0.2 に更新」 | 取得 → 検証 → 置換 → 再起動 |

Homebrew 経路でアプリが自分を置き換えると、brew 側は旧版のままだと認識し続けて
次の `brew upgrade` で状態が食い違う。経路を分けるのはこの二重管理を避けるため。

## 自己置換の手順 (direct のみ)

1. zip を一時ディレクトリへ取得し展開する
2. **署名検証** — `SecStaticCodeCheckValidity` に
   `anchor apple generic and certificate leaf[subject.OU] = "45F858C28S"` を要求する。
   検証に失敗したら即中止し、取得物を破棄する
3. 旧バンドルを同ボリューム内へ退避 → 新バンドルを所定パスへ移動。
   失敗したら退避を戻す
4. `open` で新インスタンスを起動し、自プロセスは exit する

**順序は崩さない**。ネットワーク経由で取得したバンドルを検証前に一度でも実行したら、
更新経路がそのまま任意コード実行の穴になる。

## LOW 中の適用を禁じるガード

`WatchState` が `.low` / `.lowManual` / `.override` のときは更新を実行せず、
「ホームに戻ってから実行してください」と伝えるに留める。

理由: 更新は自プロセスの再起動を伴う。低解像度のまま新プロセスが立ち上がると、
その解像度をホームとして誤学習しうる (CLAUDE.md が名指ししている落とし穴)。
「適用はユーザー操作のときだけ」という設計だけでは、リモート接続中に押される
可能性が残るため、状態でも塞ぐ。

## 版表示

メニュー最下部、終了の上に無効項目で `AwayView 1.0.1`。その直下に更新項目を置く。

## README

Homebrew の導線は en/ja 双方に既にある。追記は Homebrew 6 が初回利用の tap に
要求する `brew trust --tap wadap/tap` の一行 (Homebrew 6.0.20 で確認)。
これが無いと現状の手順は失敗する。

## A. 既存パターンとの差分

### 踏襲するもの

- 観測対象は protocol 越しに注入し、テストでは fake を刺す
- 戻り値を `Optional` にしない (v1.0.1 で `ConnectionObserving` を三値 enum にした判断を継承)
- 設定は `SettingsStore` 一点 (`autoCheckEnabled` / `lastCheckedAt`)。
  `autoCheckEnabled` は設定ウィンドウにチェックボックスとして出す (既定 ON)。
  `lastCheckedAt` は内部状態なので UI には出さない
- ログは `ObservationWriter` に英語固定
- 文言は `L()` 経由で en/ja 両方に追加
- メニュー項目は `menuNeedsUpdate` 内で構築する (開くたび全再構築)
- シェルアウトしない。brew 判定はファイル存在確認、署名検証は Security.framework、
  クリップボードは `NSPasteboard`。
  **例外は 2 つだけ**: zip の展開 (`/usr/bin/ditto`) と再起動 (`/usr/bin/open`)。
  展開は署名済みバンドルの拡張属性と symlink を壊さない公開 API が無く、`ditto` が
  標準的な手段であるため。いずれも引数配列で渡し、シェル経由の文字列展開はしない

### 異なる扱いをする箇所と理由

- **`UpdateInstaller` は protocol の裏に隠さず、ユニットテストの対象外に置く**。
  実際の置換と再起動は「自分自身のバンドルを消す」操作で、意味のある自動テストには
  本物のバンドルと署名済み zip が要る。`--check-update` / `--install-update` の CLI
  フラグ (既存の `--apply` / `--restore` と同じ検証用フラグの並び) で実機確認する。
  CShim の ENOMEM リトライをテストしないと決めたときと同じ判断。穴は tasklist に明記する
- **アプリが初めてネットワークに出る**。失敗モードの層が一つ増えるため、ネットワーク
  失敗は必ず静かにログして次回に回す。watcher は止めない
  (hooks の失敗が watcher を止めないのと同じ規律)

## B. テスト戦略

XCTest。既存 `Tests/AwayViewTests/` に追加する。
**TZ・ロケール・ネットワーク・実ファイルシステムに依存させない**
(CI は macos-15 / Swift 6.1 で回っており、JST 依存テストで一度踏んでいる)。

| 対象 | 種別 | mock の範囲 |
|---|---|---|
| `AppVersion` の SemVer 比較 | unit | 純粋関数。mock なし |
| `UpdateChecker` の判定 | unit | `ReleaseFetching` を fake に。HTTP は一切叩かない |
| GitHub API JSON のパース | unit | 実レスポンスを固定文字列で埋め込む |
| `InstallOrigin` の判定 | unit | prefix パスを注入し、tmpdir に偽 Caskroom を作る |
| `SettingsStore` の新規キー | unit | 既存 `SettingsStoreTests` の作法 (一時 suite) に倣う |
| 置換・再起動 | 手動 | CLI フラグで実機確認。自動テストなし |

### 最初に書く RED テスト

`AppVersion` の比較:

- `"1.0.10" > "1.0.9"` (辞書順で実装すると落ちる)
- `"1.0.1" == "1.0.1"`
- `"v1.0.2"` の `v` 剥がし

ここが壊れると「新版があるのに一生気づかない」か「毎回更新を促す」のどちらかになり、
実運用では気づきにくい。

## リスクと未解決

- **署名検証が唯一の防壁**。Team ID `45F858C28S` を定数で持つ。検証 → 置換 → 起動の
  順序を崩さない
- **`/Applications` への書き込み権限**。admin グループのユーザーなら通るが、非 admin
  環境では失敗する。失敗時は Releases ページを開く導線に落とす
- **`SMAppService` の登録は触らない**。同一パスへ置き換えるので登録は生き残る
  (BACKLOG の「登録パスの自己修復」は別件のまま)
- **手元の cask clone が古い**。`~/git/homebrew-tap` は 1.0.0 のままで v1.0.1 の更新
  (`ac7dd6a`) が pull されていない。本作業とは独立だが、実機確認の前に揃える
