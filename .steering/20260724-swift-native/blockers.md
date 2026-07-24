# blockers — Swift ネイティブ化

（解消済み・ブロッカーなし）

- ~~CG API の HiDPI モード列挙の互換性~~ → スパイクで実証 (41 モード網羅・UUID 一致)
- ~~実機切替の検証~~ → 2026-07-24 完了。接続中の切替で無チラつき引き継ぎ、
  切断→自動復帰 (19:06:15) / 再接続→自動低解像度化 (19:06:42) をログで確認
- 実装中に踏んだ罠 (CLAUDE.md にも記録):
  - CGDisplayCreateUUIDFromDisplayID は @_silgen_name + ColorSync リンクが必要
  - pcblist_n は #pragma pack(4) + 8 バイト境界切り上げが必須
  - UserDefaults(suiteName: 自 bundle id) は nil を返す
  - swift test は CLT に XCTest が無く DEVELOPER_DIR 指定が必要
