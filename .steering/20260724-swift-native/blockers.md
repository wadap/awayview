# blockers — Swift ネイティブ化

- ~~CG API の HiDPI モード列挙の互換性が未検証~~ → 2026-07-24 スパイクで実証済み。
  `CGDisplayCopyAllDisplayModes` + `kCGDisplayShowDuplicateLowResolutionModes` で
  res_options の全 41 モード（HiDPI 含む）を網羅、UUID も displayplacer の
  persistent id と一致。注意点: `CGDisplayCreateUUIDFromDisplayID` は Swift 未公開
  シンボルのため `@_silgen_name` 宣言 + ColorSync フレームワークのリンクが必要
- SSH agent が不調のため push は `gh` の HTTPS 認証経由で行う
  （`git -c credential.helper='!gh auth git-credential' push https://github.com/wadap/screenshare-res.git <branch>`）
