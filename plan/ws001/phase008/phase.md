<!-- awesome-plan project=amaterrace-gpu record=ws001-p008 -->

# Phase 008: FP 演算ライブラリ再編 & 統合 FPU コア（am_fpu_core）実装

- **親**: [WS001](../ws.md)
- **状態**: `in-progress`
- **依存**: [ws001-p001](../phase001/phase.md)
- **優先度**: Major (DSP48E1 リソース最適化 & ライブラリ共通化)
- **出典**: ユーザー諮問（FPU ライブラリ化・DSP 再利用、fdiv/f2fix/i2f ライブラリ化）および R1 技術アドバイス

## 目的

1. **DSP48E1 の再利用による FPU リソース極小化**:
   単体演算器（`am_fp_add`, `am_fp_mul` 等）を並べて FPU を組むことによる DSP の重複消費を根絶し、1 レーンあたり 4 個の DSP48E1（33×33 カスケード乗算器）を前段 MUX で共有して FMA / FMUL / FADD / FSUB / INT-MUL（RISC-V M 拡張乗算）を 1 本のデータパスで処理する統合 FPU コア（`rtl/library/fp/am_fpu_core.v`）を新設する。
2. **GPU 制御と純粋演算のレイヤリング分離**:
   `atg_su_fpu.v` はワープ管理、スコアボード調停、Packed fp16 時分割（PK_SHARED）に専念し、演算処理を `am_fpu_core` の $N_{\text{PHYS}}$ 個のインスタンスへ委譲する。
3. **`fdiv` / `f2fix` / `i2f` のライブラリ昇格**:
   - `atg_rx_fdiv.v`（27 サイクル回復法・DSP 0・低面積）を `rtl/library/fp/am_fp_div.v` に昇格し、RX・TU・SU で共通利用可能にする。
   - `atg_rx_i2f.v` を `rtl/library/fp/am_fp_i2f.v` へ昇格。
   - `atg_rx_f2fix.v` をパラメータ化（`W`, `F`, `ROUND`, `SATURATE`）し、`rtl/library/fp/am_fp_f2fix.v` として新設。

## 範囲・作業内容

1. **Step 1: 変換器のライブラリ化（[済] 完了）**:
   - `rtl/library/fp/am_fp_fix2f.v`（`atg_rx_i2f.v` を汎用拡張・互換ラッパー配置）
   - `rtl/library/fp/am_fp_f2fix.v`（パラメータ `W`, `F`, `SIGNED`, `ROUND`, `SATURATE`, `SAT_BITS`）
   - 仕様書 `spec/library/fp/am_fp_fix2f.md`, `spec/library/fp/am_fp_f2fix.md`
   - RX（`atg_rx_setup`, `bary`, `cpoly`, `frag`, `scan`, `edge`）の接続を新ライブラリに切り替え。
   - 単体等価検証 110 万パターン 100% 一致確認。
2. **Step 2: 浮動小数点除算器のライブラリ化（[済] 完了）**:
   - `atg_rx_fdiv.v` → `rtl/library/fp/am_fp_div.v`（27 サイクル回復法、互換ラッパー配置）
   - 仕様書 `spec/library/fp/am_fp_div.md` 作成。
   - RX 回帰シミュレーション（`atg_rx_fp`, `clip`, `setup`, `cpoly`, `frag`, `scan`）全件 PASS。
3. **Step 3: 統合 FPU コア（`am_fpu_core.v`）の設計・実装（進行中）**:
   - 1 レーン分の FMA/ADD/SUB/MUL/MIN/MAX/FCMP/F2I/I2F/IMUL を完結して処理するパイプラインコアの実装。
   - 乗算器部に `am_mul.v`（DSP48E1 カスケード）を活用し、33×33 乗算器（4×DSP48E1）を mux で共有。
   - 単体等価テストベンチの作成・検証。
4. **Step 4: `atg_su_fpu.v` の置換 & 全体回帰検証**:
   - `atg_su_fpu.v` 内部を `am_fpu_core` に置換。
   - `make check`（lint, sim, verilator）および全ラスタライズテストの完全一致確認。

## 検証基準（受け入れ条件）

- `am_fpu_core` により、SU の 1 レーンあたりの DSP48E1 消費が 4 個に抑えられ、かつ全 FP/整数乗算命令がビット完全一致すること。
- RX の `fdiv`、`f2fix`、`i2f` が新ライブラリに移行し、既存シミュレーションが全件 PASS すること。
