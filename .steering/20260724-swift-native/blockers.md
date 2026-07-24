# blockers — Swift ネイティブ化

- **CG API の HiDPI モード列挙の互換性が未検証**。displayplacer の res_options と
  同等の一覧（1920x810 等のスケールモード含む）が取れるかは Task 1 のスパイクで
  最初に実証する。取れない場合は設計（ピッカーの選択肢）の見直しが必要
- SSH agent が不調のため push は `gh` の HTTPS 認証経由で行う
  （`git -c credential.helper='!gh auth git-credential' push https://github.com/wadap/screenshare-res.git <branch>`）
