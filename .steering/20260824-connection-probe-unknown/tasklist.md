# タスク — 接続列挙の失敗を「接続なし」と区別する

- [x] **1. `ConnectionProbe` 三値化 (振る舞い不変の refactor)**
      `ConnectionObserving.remoteIP() -> String?` を `probe() -> ConnectionProbe`
      に置換。`.unavailable` は一旦 `.none` と同じ扱いにして 39 tests 緑を維持
- [x] **2. StateMachine: `.unavailable` で前 tick の判定を維持**
      RED (3 tests) → GREEN。`last` も `settling` も触らず return
- [x] **3. 観測フック `onProbeUnavailable`**
      RED (1 test) → GREEN。MenuController から watch.log に記録
- [x] **4. ConnectionMonitor: 列挙エラーと 0 件の分離**
      `lister` 注入の seam を作り RED (5 tests) → GREEN。`n >= 0` ガード
- [x] **5. CShim: ENOMEM リトライ**
      余裕を 1/8 → 1/4 → 1/2 → 1 と広げて最大 4 回。`errno != ENOMEM` は即 -1
- [x] **6. 検証**
      `make check` / `swift test` 48 tests 緑。実カーネルで非空列挙を確認
      (port 28196 の ESTABLISHED 6 本を netstat と一致して列挙)

## テストのカバー範囲と穴

新規 9 tests (39 → 48)。すべて RED を確認してから実装した。

**穴: CShim の ENOMEM リトライには unit test が無い。** sysctl を決定的に
ENOMEM で失敗させる手段がなく、C 側に関数ポインタ注入の seam を作るのは
非公開 ABI を扱うファイルへの改変として割に合わないと判断した。
代替として、実カーネルに対する非空列挙 (ESTABLISHED 6 本) が netstat の
件数と一致することを確認し、バッファ取得の変更が構造体歩行を壊していない
ことを担保している。
