# タスク — スリープ/復帰ガード

- [ ] **1. `.deferred` の導入 (型変更 + StateMachine の扱い)**
      `applyLow` を `Bool` → `ApplyResult`、`RestoreResult` に `.deferred`。
      RED: 保留中は前進せず hooks も発火しない / 復帰後 ok で HIGH へ
- [ ] **2. StateMachine: 失敗時バックオフ**
      `RetryBackoff` + `clock` 注入。RED: 連続失敗で呼び出しが抑制される /
      接続状態の変化でリセット / フラグ変更でリセット / 保留でリセット
- [ ] **3. `DisplayEnvironment` 注入と `resolveTarget` の上書き防止**
      RED: 保存 UUID 不在で nil かつ UUID 不変 / 初回のみ自動選出
- [ ] **4. apply 直前のガード**
      ターゲット不在・未準備で `.deferred`。保留への出入りを 1 回だけログ
- [ ] **5. 失敗ログの間引き (`LogThrottle`)**
- [ ] **6. `SleepGate` と `AppController` への配線**
      4 通知の購読、tick 入口のゲート、開いた瞬間の `resetBackoff()`
- [ ] **7. BACKLOG 更新と検証**
      メインスレッド回避の見送り / ターゲット切り替え UI を BACKLOG へ。
      `make check` → `make test`
