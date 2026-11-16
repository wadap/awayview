# 設計 — スリープ/復帰ガード

## 全体像

CG を叩かない条件を 3 層で重ねる。外側ほど粗く、内側ほど正確。

| 層 | 場所 | 止める条件 | 性質 |
|---|---|---|---|
| ゲート | `SleepGate` + `AppController` | スリープ通知を受けてから復帰 + 猶予まで | tick ごと止める |
| ガード | `RealDisplayController` | 対象ディスプレイが不在 / 非アクティブ / スリープ中 | 適用だけ `.deferred` で返す |
| バックオフ | `StateMachine` | ガードを通ったのに CG が失敗した | 再試行の間隔を空ける |

ゲートだけでは足りない。起動時点ですでに消灯している場合や通知が届く前の
tick はゲートをすり抜けるので、適用の瞬間に状態を見るガードが本体になる。
ゲートの役目は、復帰直後に CG の状態問い合わせが「準備完了」を返していても
WindowServer がまだ再構成中、という窓を猶予で塞ぐこと。

## 型の変更

```swift
enum ApplyResult { case ok, failed, deferred }
enum RestoreResult { case ok, failed, noCache, deferred }

protocol DisplayControlling {
    func applyLow(_ resolution: String?) -> ApplyResult      // Bool から変更
    func restoreHome(explicit resolution: String?) -> RestoreResult
    func captureHome(onlyIfMissing: Bool)
}
```

`.deferred` = 「CG を呼んでいない。条件が整えば通るはず」。StateMachine は
`.failed` と同じく前進しないが、バックオフは積まない。

## ゲート (`SleepGate`)

純粋な値型。時刻は引数で受け取るのでテストできる。

```swift
struct SleepGate {
    static let wakeGrace: TimeInterval = 5
    mutating func systemWillSleep()
    mutating func systemDidWake(now:)
    mutating func screensDidSleep()
    mutating func screensDidWake(now:)
    func isOpen(now:) -> Bool   // どちらも起きていて、猶予も明けている
}
```

`AppController` が `NSWorkspace.shared.notificationCenter` の 4 通知を購読して
ゲートを更新する。タイマーは止めず、tick の入口で `isOpen` を見て早期 return
する (タイマーの suspend/resume は回数の釣り合いを崩すと crash するため)。
閉じている間は `updateIcon()` も呼ばない (CG の列挙を叩くため)。

ゲートが開いた最初の tick で `StateMachine.resetBackoff()` を呼ぶ。復帰直後は
適用が通る見込みが最も高く、ここで最大 60 秒待たせると「復帰したのに
低解像度のまま」が見えてしまう。

開閉は watch.log に 1 行ずつ出す (`-- paused (...)` / `-- resumed`)。

## ガード (`RealDisplayController`)

`applyLow` / `restoreHome` の入口で、モード列挙より前に判定する。

1. `resolveTarget()` が nil → `.deferred`
2. `environment.isReady(id)` が false → `.deferred`
   (`CGDisplayIsActive != 0 && CGDisplayIsOnline != 0 && CGDisplayIsAsleep == 0`。
   `captureHome` の誤学習ガードと同じ条件を共有する)

ターゲット不在を `.failed` ではなく `.deferred` にするのは、クラムシェル復帰で
外部ディスプレイが一瞬消えるのが「待てば直る」状態だから。失敗扱いにすると
バックオフが積まれ、ディスプレイが戻ってからの復帰が遅れる。

保留への出入りは状態が変わったときだけログに出す
(`-- display not ready; deferring display changes` / `-- display ready`)。

### ディスプレイ列挙の注入

```swift
protocol DisplayEnvironment {
    func onlineDisplays() -> [CGDirectDisplayID]
    func uuidString(for id: CGDirectDisplayID) -> String?
    func isBuiltin(_ id: CGDirectDisplayID) -> Bool
    func isReady(_ id: CGDirectDisplayID) -> Bool
}
```

`RealDisplayController(defaults:environment:)`。既定は CG を叩く
`SystemDisplayEnvironment`。

### `resolveTarget` の上書き防止

| 保存 UUID | オンライン一覧 | 結果 |
|---|---|---|
| なし | あり | 外部優先で選出して保存 (従来どおり) |
| あり | その UUID を含む | そのディスプレイ |
| あり | 含まない | **nil。UUID は書き換えない** |
| — | 空 | nil |

## バックオフ (`StateMachine`)

```swift
struct RetryBackoff {
    static let delays: [TimeInterval] = [3, 10, 30, 60]
    func allows(_ now: TimeInterval) -> Bool
    mutating func recordFailure(now: TimeInterval)
    mutating func reset()
}
```

- 表示を変える 4 経路 (`ensureHigh` の restore、res_high の再適用、
  `ensureLow` の apply、res_low の再適用) を 1 つのバックオフで束ねる
- `.failed` で積む。`.ok` / `.noCache` / `.deferred` でリセット
  (`.deferred` は状況が変わった合図なので、連続失敗の数え直しにする)
- 「意図」が変わったらリセット。意図 = 接続の有無 + モードフラグ + res_low /
  res_high。メニュー操作を最大 60 秒待たせないため、接続だけでなくフラグも含める
- `.unavailable` の tick は意図を更新しない (不明は変化の証拠ではない)
- 時刻は `clock: () -> TimeInterval` で注入。既定は `systemUptime`
  (壁時計の修正で巻き戻らない)

バックオフ中は表示操作を呼ばず、`.deferred` と同じ「前進しない」扱いにする。

## ログの間引き (`LogThrottle`)

`RealDisplayController` の `!!` ログを通す。

- 直前と違う文言 → そのまま出す
- 同じ文言の連続 → 最後に出してから 10 分経つまで黙り、経ったら
  `<message> (N consecutive failures)` を 1 行出す
- 適用成功・保留への遷移でリセット

バックオフ上限 60 秒と合わせて、失敗が続いても 10 分に 1 行になる
(従来は 10 秒に 1 行)。

## `CGDisplayRegisterReconfigurationCallback` を使わない理由

- 通知されるのは再構成トランザクションの開始と終了で、「落ち着いた」という
  信号は無い。復帰時は複数回まとめて飛ぶので、結局デバウンス用の猶予タイマーが
  要る。固定の猶予と変わらず、仕組みだけ増える
- 自分の `apply()` もこのコールバックを起こすので、自己起因を除外する処理が要る
- 今回の実害 (消灯中の適用) では再構成自体が起きないので、このコールバックでは
  検知できない

準備状態は「適用する瞬間に問い合わせる」ガードの方が正確に取れる。

## リスク

- **ディスプレイスリープ中は切断を検知しても復帰しない** (意図した変更)。
  復帰はディスプレイが点いてから猶予 5 秒後。従来も消灯中の復帰は通って
  いなかったので、実質的な後退ではない
- **`screensDidWake` を取りこぼすとゲートが閉じたままになる。** NSWorkspace の
  通知は標準経路なので実害は考えにくいが、実機確認で `paused` と `resumed` が
  対になっていることを見る
- **リモート接続がディスプレイを起こさない環境では下がらなくなる。**
  11/12 のログでは接続のたびに `Display is turned on` が出ているので、
  この Mac では成立している。実機確認の項目に入れる
- **保存 UUID のディスプレイを恒久的に外すと ⚠️ のまま動かない。**
  従来は黙って別ディスプレイへ切り替わっていた。切り替え UI が無いので
  BACKLOG に積む
