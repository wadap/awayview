# 設計 — ConnectionProbe による三値化

## 中心となる型変更

```swift
enum ConnectionProbe: Equatable {
    case remote(String)   // 設定 CIDR 内の接続元を検出
    case none             // 接続なし (列挙は成功した)
    case unavailable      // 列挙に失敗した = 不明
}
```

`ConnectionObserving.remoteIP() -> String?` を `probe() -> ConnectionProbe` に
置き換える。`String?` のままでは「なし」と「不明」を表現し分けられないため、
Optional を返す設計そのものが今回のバグの温床だった。

## 各層の責務

| 層 | 変更 |
|---|---|
| `CShim` | 2 回目の sysctl が ENOMEM のときバッファを拡大して最大 3 回リトライ。他のエラーは従来どおり -1 |
| `ConnectionMonitor` | `enumerateForeignIPs() -> [String]?` を新設 (nil = 列挙失敗)。`probe()` がこれを三値に写す |
| `StateMachine` | `.unavailable` の tick は **何もせず return**。`last` も `settling` も触らない |

## `.unavailable` で `settling` を保持する理由

SETTLE の意図は「瞬間的な接続では下げない」こと。観測不能は切断の証拠では
ないので、settling をリセットすると一過性の列挙失敗が二段階確認を毎回
巻き戻してしまい、リモート接続時にいつまでも下がらなくなる。
`remote → unavailable → remote` は「連続 2 回の肯定的観測」として扱う。

## 観測性

`onProbeUnavailable` クロージャを追加 (既存の `onLowApplied` /
`onHighRestored` と同じ形)。MenuController 側で watch.log に記録し、
「無音で増幅される」状態を解消する。

## リスク

- **CShim を触る**: CLAUDE.md は「触らない」としているが、対象は非公開 ABI の
  構造体レイアウトとブロック歩行。今回変更するのは sysctl 呼び出しの
  エラー処理のみで、レイアウト定義と歩行ループには手を入れない
- 既存 6 テストファイルのうち StateMachineTests / ConnectionMonitorTests が
  protocol 変更の影響を受ける。振る舞いを変えない refactor を先に通してから
  新しい振る舞いのテストを RED にする
