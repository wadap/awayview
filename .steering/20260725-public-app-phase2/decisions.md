# Decisions — 公開アプリ化 Phase 2

- **2026-07-25 リリースパイプラインはローカル Makefile 完結（A 案）**。
  GitHub Actions 自動化（B 案）は署名鍵を新規 public repo の secrets に
  預けるリスクとセットアップコストが、ユーザー 1 人・低頻度リリースに
  見合わないため不採用。手順書のみ（C 案）は Makefile 資産があるため
  自動化との差分コストがほぼ無く、ミス防止で A を選択
- **2026-07-25 cask は本家 homebrew/cask でなく個人 tap**。本家は
  notability 要件（GitHub スター数等）があり新規アプリは通らない。
  将来要件を満たせば本家へ昇格可能
- **2026-07-25 アイコンは Claude が SVG でデザイン→生成**。再現可能で
  repo にソースを残せる。案を複数提示してユーザーが選択
- **2026-07-25 メニューバーは絵文字（🏠/💻）維持**。状態が一目で分かる
  現 UX を壊さない。.icns は Dock/Finder/About 用のみ
- **2026-07-25 リネーム & public 化は notarize 検証成功後**。hardened
  runtime での動作問題が出た場合に private のまま調査できるようにする
- **2026-07-25 バージョンは v1.0.0 始まり**
- **2026-07-26 notarize 認証は App Store Connect API キー方式**。app-specific
  password は組織アカウントで 401 が解消せず、API キー (Team Key, ロール
  Developer) に切替えたら一発で通った。以後のマシン追加時もこの方式を使う
- **2026-07-26 codesign --verify に --deep を付けない** (design.md からの
  意図的逸脱)。ネスト実行物はデータのみのリソースバンドルだけで、実効性の
  高い検証は notarize + spctl が担うため。final review で確認済み
- **2026-07-26 publish は `--target $(git rev-parse HEAD)` を明示**。
  gh release create の既定はリモート default branch の HEAD にタグを打つため、
  push 忘れ時に stale commit へタグが付く事故を防ぐ
- **2026-07-26 cask の depends_on は symbol 形式** (`macos: :ventura`)。
  Homebrew 6 で文字列比較形式 (`">= :ventura"`) は deprecated。また
  Homebrew 6 は初回利用の tap に `brew trust <tap>` を要求する (README には
  記載不要と判断 — brew 自身がエラーメッセージで案内する)
