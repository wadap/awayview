# decisions — Swift ネイティブ化

- **2026-07-24 全部入り 1 アプリ構成を採用**（対案: watcher だけ先行ネイティブ化）
  - ロジックは zsh 版で実証済み・テストシナリオも揃っており、二度手間を避ける

- **2026-07-24 SwiftPM + Makefile、Xcode プロジェクトなし**
  - ローカル専用・ad-hoc 署名。リポジトリをクリーンに保つ

- **2026-07-24 接続監視は sysctl net.inet.tcp.pcblist_n**（対案: netstat shell-out 継続）
  - ロードマップの「shell-out 排除」を実現。netstat と同じ情報源なので
    root 不要のまま全プロセスのソケットが見える（lsof の轍は踏まない）

- **2026-07-24 ファイル契約は維持、config.zsh はネイティブ版で不要化**
  - state/フラグ/解像度選択ファイルは互換維持（legacy と相互運用・デバッグ容易）
  - SCREEN_ID は UUID 自動検出、LOW_CMD はメニュー選択で代替。
    home 自動学習キャッシュのみネイティブ内部（UserDefaults + CGDisplayMode）へ
    移し、home.cmd は legacy 専用とする

- **2026-07-24 常駐は SMAppService ログイン項目**（対案: launchd plist 継続）
  - メニューバーアプリの常駐はアプリ自身で担保。plist の手書き・KeepAlive 不要

- **2026-07-24 SETTLE_DELAY は「二段階遷移」で実装**
  - tick 内 sleep は UI スレッドを塞ぐため、候補検知 → 次 tick 再確認で同等の
    意味論を実現

- **2026-07-24 zsh 版は legacy として残置**
  - native 安定確認まで `make install` で即切戻し可能にする
