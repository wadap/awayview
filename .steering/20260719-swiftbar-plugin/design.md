# design — SwiftBar プラグイン化（案A: フラグファイル + 状態ファイル方式）

## 全体像

```
SwiftBar プラグイン (UI, 5秒ごと)          watcher (判定・適用の一元管理)
  読む:  state, override の有無             読む:  override の有無
  書く:  override (touch / rm)              書く:  state（変化時のみ・アトミック）
  実行:  launchctl print / kickstart
```

判定・適用ロジックは watcher に一元化したまま、プラグインは
「state を読んで表示する・override フラグを置く/消す」だけの薄い層。
このファイル IF はロードマップ②（Swift ネイティブ化）でもそのまま使う契約。

## 1. ファイルインターフェース

配置はすべて既存の `~/.local/state/screenshare-res/`。

### `override`
- 存在＝「高解像度固定」。中身は空。mtime を「固定開始時刻」表示に使う
- **プラグインが touch / rm、watcher は存在チェックのみ**

### `state`
- **watcher だけが書く**。zsh で `source` できる key=value 形式:

  ```
  STATE=home        # home | low | override
  REMOTE_IP=        # 接続元 Tailscale IP。なければ空
  CHANGED_AT=2026-07-19 10:03:21
  ```

- tmp ファイルに書いて `mv` するアトミック書き込み
- 値が変わったときだけ更新（3秒ごとに毎回書かない）

## 2. watcher 拡張（bin/screenshare-res-watch.zsh）

メインループ先頭に override 分岐を追加。既存 state machine（`last`）は温存:

```
override あり:
  「接続なし」と同等に扱う
  last != high なら restore_home、以後は capture_home で追従
  state=override、ログ "-> HIGH (override)"
override なし:
  既存ロジックそのまま（low / home）
```

- 固定中の解像度はホームなので capture_home 追従は安全。
  「下げた状態をホームと誤学習しない」順序（CLAUDE.md 参照）は不変
- `remote_vnc_connected` が見つけた Tailscale IP をグローバル変数に保存し
  state に書く（固定中でも「接続: あり」を表示するため）
- 接続中に固定解除 → 次ループで通常の low パス（SETTLE_DELAY 込み）に乗る

## 3. SwiftBar プラグイン（swiftbar/screenshare-res.5s.zsh 新規）

zsh 1 ファイル。SwiftBar 形式は単なる標準出力なので、ターミナル直接実行で
検証できる（SwiftBar 不要でテスト可）。

処理順:
1. `launchctl print gui/$UID/com.wadap.screenshare-res` で watcher 生存確認
   → 未ロード or state 読めず → ⚠️ 表示
2. `state` を source してアイコン決定: 🏠 home / 📱 low / 📌 override
3. ドロップダウン（標準セット）:

   ```
   状態: ホーム解像度 | 低解像度 | 高解像度に固定中 (HH:MM〜)
   接続: なし | 100.x.y.z
   ---
   📌 高解像度に固定   ← override 無いとき。bash="touch …/override" refresh=true
   ✅ 自動に戻す       ← override あるとき。bash="rm …/override" refresh=true
   ---
   ログを開く          ← open で watch.log
   watcher を再起動    ← launchctl kickstart -k gui/$UID/com.wadap.screenshare-res
   ```

## 4. インストール統合

- `install.sh` に `swiftbar` サブコマンドを追加（Makefile に `make swiftbar`）:
  1. SwiftBar.app 未検出なら `brew install --cask swiftbar` を案内して終了
  2. `defaults read com.ameba.SwiftBar PluginDirectory` でプラグインフォルダ特定。
     未設定なら「SwiftBar を一度起動してフォルダを選んで」と案内して終了
  3. リポジトリ内 `swiftbar/screenshare-res.5s.zsh` を **symlink** 設置
- `uninstall` は symlink も削除
- symlink なのは開発中の変更を即反映するため。watcher の cp 方式とは意図的に
  非対称（watcher は launchd から参照されるため設置物を固定したい）

## 5. エラー処理

- state ファイルなし / watcher 未ロード → ⚠️ + 「watcher を再起動」をメニューに
- override フラグがあっても watcher 死亡なら ⚠️ を優先（異常検知 > 固定表示）
- displayplacer の失敗は従来どおり watcher の watch.log に残る（プラグイン非関与）

## 6. テスト

- `make check` にプラグインの `zsh -n` を追加
- プラグイン単体はターミナル実行で出力を目視確認
- 手動テストマトリクス:
  1. 通常起動 → 🏠
  2. 固定 → 📌、リモート接続してもホーム解像度のまま
  3. 接続中に解除 → 数秒で 📱
  4. `launchctl bootout` → ⚠️、メニューから再起動で復帰
