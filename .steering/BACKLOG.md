# BACKLOG — 着手していない課題

まとまった作業に入るときは `.steering/[YYYYMMDD]-[タスク名]/` を切って、
該当項目をそこへ移す。ここは「忘れないための置き場」であって設計書ではない。

---

## UI: メニューバーアイコンが emoji で識別しづらい

**現状**: `MenuController.swift:45,90` で `statusItem.button?.title` に emoji を
入れている (`🏠` home / `💻` low / `📌` override)。

**問題**:

- emoji はメニューバーの tint / ダークモード / 透明度低減に追従しないので、
  ネイティブアプリの単色アイコンの列に並ぶと浮くうえに見つけにくい
- 幅が環境で変わり、レイアウトが安定しない
- アプリ本体のアイコン (`make icon` で生成) と見た目が繋がっていない

**方向性**: `NSImage` の template image (`isTemplate = true`) に置き換える。
SF Symbols で足りるならそれが最短。状態ごとに glyph を変える設計は維持する。
アプリアイコンと同じ SVG ソースから起こせば見た目の一貫性も取れる。

---

## 命名: アプリ名 "AwayView" を再検討するか

**論点**: 名前が用途 (外出先からの接続時だけ解像度を下げる) を想起させるか。

**注意 — 改名コストは v1.0.0 公開で跳ね上がっている**。単なる表示名の変更で
済まず、bundle id を変えると以下が芋づるで壊れる:

- `UserDefaults` suite `com.wadap.AwayView` — 既存ユーザの設定とホーム解像度の
  学習結果が孤児化する (移行コードが要る)
- `SMAppService` のログイン項目登録 — 旧 id の登録が残る
  (同種の事故は 2026-08-24 に実際に踏んだ。phase2 の blockers.md 参照)
- Homebrew cask `wadap/homebrew-tap` の `awayview.rb`、GitHub repo 名、
  署名 / notarize のフロー

**判断**: 表示名だけ変える / bundle id ごと変える / 変えない、の 3 択を
先に決める。bundle id を変えるなら移行コードとセットで 1 フェーズ切る。

---

## 既知の未解決 (別ドキュメントに詳細あり)

- **復帰失敗時の backoff** — `.steering/20260725-public-app-phase2/blockers.md`。
  2026-08-24 の修正で発生頻度は下がるはずなので、実運用のログを見てから判断
- **brew 移行で SMAppService の登録が旧 bundle パスに残る** — 同上。
  cask へ移行する全ユーザで再現しうるので、アプリ側で自己修復したい
  (起動時に自分の登録パスを検証して、ずれていたら登録し直す)
- **`UpdateInstaller` に自動テストが無い** — `.steering/20260828-version-and-updater/`。
  自分自身のバンドルを消して置き換える操作は、本物のバンドルと署名済み zip を
  用意しないと意味のあるテストにならないため見送った。取得・展開・署名検証・置換の
  経路は `--check-update` / `--install-update` の実機確認だけが担保になっている。
  リリース手順に「新版を 1 つ前の版から更新して確認する」を入れるのが現実的な穴埋め
