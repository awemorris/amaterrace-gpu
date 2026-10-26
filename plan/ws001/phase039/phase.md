<!-- awesome-plan project=amaterrace-gpu record=ws001-p039 -->

# Phase 039: DC -> MC Urgent / Panic ウォーターマークプリエンプション実装

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p038](../phase038/phase.md), [ws001-p028](../phase028/phase.md)
- **優先度**: Critical (100% 3D レンダリング高負荷時の画面アンダーフロー完全防止)
- **出典**: ユーザー諮問（DC & BUS 最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

GPU が 100% の 3D レンダリング高負荷状態（ROP ブレンド、テクスチャキャッシュミス、BLT コピーが同時多発）にある際、Display Controller のスキャンアウトデータが飢餓状態に陥りアンダーフロー（画面チラつき・ブラックアウト）を起こす問題を根本解決する。
ピクセル AFIFO の残量水位に基づく多段階ウォーターマーク信号（Urgent / Panic）を MC（メモリコントローラ）へ送り、他クライアントの調停を一時停止して DC を最優先供給するハードウェアプリエンプション機構を実装する。

## 範囲・作業内容

1. **多段階ウォーターマーク監視機構の実装 (`atg_dc.v`)**:
   - Phase 038 で導入した `am_afifo_bram` のピクセル残量カウンタ（`r_count`）を監視。
   - **Normal（残量 $\ge 40\%$）**: 通常の調停（`dc_urgent = 0`, `dc_panic = 0`）。
   - **Urgent（残量 $< 40\%$、約 819 ワード未満）**: `dc_urgent = 1` を出力。
   - **Panic（残量 $< 20\%$、約 409 ワード未満）**: `dc_panic = 1` を出力。
2. **MC アービタのプリエンプション統合 (`atg_mc.v` / `atg_mc_tree.v`)**:
   - `dc_urgent`: MC は 3D/コンピュートクライアント（SU, TU, ROP, BLT）の新規グラント発行を一時停止し、DC のリード要求を最優先でスケジュール。
   - `dc_panic`: 走行中のバースト完了境界で即座にグラントを DC へ切り替え。
3. **トップ配線とステータス統合 (`atg_top.v`)**:
   - DC から MC への `dc_urgent`, `dc_panic` 信号線を配線。
   - `DISP_STATUS` レジスタへウォーターマーク履歴（過負荷警告）を反映。
4. **単体・ストレステスト**:
   - 全クライアントがフル飽和アクセスを行っている極限環境下での 1080p 連続表示ストレステスト。
   - `tools/arith-lint.py` 違反 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/dc/atg_dc.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/mc/atg_mc.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/mc/atg_mc_tree.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/top/atg_top.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/dc/atg_dc.md`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/mc/atg_mc.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_dc_mc_stress_tb.v`

### 2. モジュールインターフェース設計

#### `atg_dc.v` 追加ポート
```verilog
    output wire dc_urgent,  // ピクセル残量 < 40% (819/2048 words)
    output wire dc_panic    // ピクセル残量 < 20% (409/2048 words)
```

#### `atg_mc.v` 追加ポート
```verilog
    input wire dc_urgent,
    input wire dc_panic
```

### 3. RTL アーキテクチャと実装詳細
#### (1) ウォーターマーク判定ロジック（`atg_dc.v`）
- `am_afifo_bram` から出力される `r_count` は `pclk` ドメイン。
- これをクロック同期器 `am_sync` または CDC パスを通じて `clk`（gclk）ドメインへ安全に渡す（Urgent/Panic 判定はミリ秒・マイクロ秒オーダーの緩やかな水位変化であるため、2段 FF 同期で十分）。
- `gclk` ドメインにおいて判定:
  ```verilog
  // 2048 ワード AFIFO に対する閾値
  localparam [11:0] WM_URGENT = 12'd819; // 40%
  localparam [11:0] WM_PANIC  = 12'd409; // 20%

  reg dc_urgent_r, dc_panic_r;
  always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
          dc_urgent_r <= 1'b0;
          dc_panic_r  <= 1'b0;
      end else begin
          dc_urgent_r <= enable && (g_px_count < WM_URGENT);
          dc_panic_r  <= enable && (g_px_count < WM_PANIC);
      end
  end
  assign dc_urgent = dc_urgent_r;
  assign dc_panic  = dc_panic_r;
  ```

#### (2) MC 調停（`atg_mc.v`）のプリエンプション動作
- `dc_urgent` または `dc_panic` がアサートされている間、MC のルートアービタは他のすべてのリクエストに対する `grant` の発行をマスク（マスクベクタ `other_mask = dc_urgent ? ~(1 << C_DC) : {NCLIENT{1'b1}}`）する。
- これにより、DC からのリクエストが到着次第、最優先・ゼロ待機で AXI メモリポートへディスパッチされる。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: 閾値比較（`<`）は Verilog 比較演算子として許可されるが、カウンタの加減算には必ず `am_add` / `am_sub` を使用すること。
- **CDC 遵守**: `pclk` から `clk` への信号受け渡しには必ず `am_sync.v` を使用し、メタスタビリティを完全に遮断すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_dc_mc_stress_tb.v`
- **検証項目**:
  1. **DC プリエンプション奪取確認**:
     SU および ROP がメモリ帯域を 100% 占有している最中に、ピクセル FIFO 残量を人為的に低下させて `dc_urgent` をアサート。
     次サイクルで他のクライアントがホールドされ、DC のリードが即座に割り込んで完了することを確認。
  2. **100% 飽和下でのアンダーフロー 0 件確認**:
     100,000 サイクルにわたり、全クライアント飽和アクセス＋1080p スキャンアウトを同時実行し、`DISP_STATUS.UNDERFLOW` が一切発生しないことを確認。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_dc_mc_stress
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 3D/コンピュート/DMA が 100% 飽和している状態でも、画面表示のアンダーフローが完全にゼロになること。
- `sim/run.sh` の新規ストレステストが PASS すること。
- `tools/arith-lint.py` で違反 0 件。
- R1 レビュー APPROVE 獲得。
