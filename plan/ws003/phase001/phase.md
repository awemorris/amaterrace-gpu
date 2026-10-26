<!-- awesome-plan project=amaterrace-gpu record=ws003-p001 -->

# Phase ws003-p001: ビルド設定基盤（config.mk & atg_config.vh）の構築

- Workstream: [WS003](../ws.md)
- Status: `completed`
- Depends on: None

## 目的

プロジェクトルートに `config.mk.template` および `config.mk` を新設し、`Makefile` 経由で Verilog マクロ定義ヘッダ `include/atg_config.vh` を自動生成するメカニズムを構築する。
また、Python ターミナル UI（TUI: curses 等）による `make menuconfig` コマンドを新設し、対話的な GPU 構成変更を可能にする。

## 変更対象ファイル

- `config.mk.template` (新規作成)
- `config.mk` (新規作成, .gitignore 登録確認)
- `tools/menuconfig.py` (新規作成: Python 標準ライブラリによる TUI 設定ツール)
- `Makefile` (atg_config.vh 生成ターゲットおよび menuconfig ターゲット追加)
- `include/atg_config.vh` (自動生成)

## 完了条件

- `make include/atg_config.vh` で正しい構文の Verilog ヘッダが生成されること。
- `config.mk` が存在しない場合はデフォルト設定で動作すること。
- `make menuconfig` で Python TUI が起動し、設定変更・保存が行えること（非対話モード `--check` / `--preset` 等の headless 動作もサポート）。
- 生成されたヘッダが Verilator lint でエラーなく解釈されること。
