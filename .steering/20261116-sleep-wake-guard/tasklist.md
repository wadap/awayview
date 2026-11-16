# タスク — スリープ/復帰ガード

- [x] **1. `.deferred` の導入 (型変更 + StateMachine の扱い)** — `26f1d20`
      `applyLow` を `Bool` → `ApplyResult`、`RestoreResult` に `.deferred`。
      テスト 3 件 (保留中は前進せず hooks も capture も無し / 明けたら HIGH /
      applyLow 側も同じ)。RED はコンパイルエラーで確認
- [x] **2. StateMachine: 失敗時バックオフ** — `c256780`
      `RetryBackoff` + `clock` 注入。テスト 8 件。RED では 40 tick で 40 回
      叩く現状の不具合がそのまま出た
- [x] **3. `DisplayEnvironment` 注入と `resolveTarget` の上書き防止** — `c5021d3`
      テスト 6 件
- [x] **4. apply 直前のガード** — `c5021d3` (3 と同じコミット)
      ターゲット不在・未準備で `.deferred`。保留への出入りを 1 回ずつログ。
      テスト 6 件
- [x] **5. 失敗ログの間引き (`LogThrottle`)** — `1d01607`
      単体 5 件 + RealDisplayController 経由 1 件
- [x] **6. `SleepGate` と `AppController` への配線** — `c6757b6`
      4 通知の購読、tick 入口のゲート、開いた瞬間の `resetBackoff()`。
      SleepGate の単体 7 件 (テストと実装を同時に書いたので RED は見ていない)
- [x] **7. BACKLOG 更新と検証**
      `make check` / `make test` 103 tests 緑 (70 → 103)

## テストのカバー範囲と穴

**穴 1: 通知の配線 (`AppController.observeSleep`) に自動テストが無い。**
`SleepGate` の判定は単体で押さえたが、NSWorkspace の通知が実際に届いて
ゲートが開閉することは実機でしか確かめられない。

**穴 2: `SystemDisplayEnvironment.isReady` が消灯中に false を返すことは
未確認。** 判定式は `captureHome` の誤学習ガードで実績のあるものと同じだが、
画面共有セッション中の消灯で `CGDisplayIsAsleep` が何を返すかは見ていない。
ゲート (通知) が先に効くので実害は出にくいが、実機確認の項目に入れる。

**穴 3: CG が本当に失敗する経路 (`apply()` の失敗 → バックオフ) は
結合では通していない。** StateMachine 側はモックで、RealDisplayController 側は
「モードが見つからない」失敗で間引きを確認した。

## 作業中の事故

タスク 4 の RED 実行で、フェイクのディスプレイ ID に `2` を使っていたため
実機の外部ディスプレイ (ID 2) に本物の CG 呼び出しが届き、数秒間だけ実機の
解像度が変わった。最後の呼び出しがホーム解像度の適用だったので元に戻り、
常駐中の AwayView の学習値 (Home 3840x1620 / TargetDisplayUUID) も無傷。
テストの ID を `0xDEAD_0001` / `0xDEAD_0002` に変更し、CLAUDE.md に罠として記録した。
