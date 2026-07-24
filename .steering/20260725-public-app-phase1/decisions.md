# Decisions — 公開アプリ化 Phase 1

- **2026-07-25 アプリ名 = AwayView**（旧 ScreenshareRes）。「Res」が
  用途を伝えないため改名。「外出先（away）から見るときの表示」で
  トリガーが名前に入る。ResShift（画像超解像 AI）・Squint（同名メニュー
  バーアプリ）等の衝突候補は web 検索で除外、AwayView は衝突なし
- **2026-07-25 legacy はクリーンブレーク**。公開 repo は native のみ、
  パスも `~/.config/awayview` / `~/.local/state/awayview` に一新。
  旧ユーザーは自分の 1 台だけなので自動 migration は作らない
- **2026-07-25 設定は UserDefaults + 観測用ファイル維持**。SwiftBar との
  ファイル契約が不要になったため設定・フラグは UserDefaults へ。
  `state` / `watch.log` は hooks・デバッグ用に出力専用で残す
- **2026-07-25 設定ウィンドウは最小構成**（ポート / CIDR / ログイン時
  起動）。解像度・モードはメニューのまま。Advanced 設定は YAGNI
- **2026-07-25 i18n は Localizable.strings**。String Catalog は
  SwiftPM + Makefile（swift build, CLT）との相性検証コストがあるため
  見送り。文字列数十件規模ならエディタ支援の差は小さい
- **2026-07-25 設定 UI は SwiftUI を NSWindow にホスト**。CIDR リスト
  編集を短く書けるため。既存 AppKit コードとの混在は許容
- **2026-07-25 config.zsh フック（on_low/on_high 関数）廃止**。hooks
  ディレクトリ方式（66a2360 で追加済み）のみ残す
- **2026-07-25 repo リネームは Phase 2**。public 化と同時に
  screenshare-res → awayview
