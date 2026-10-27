# GHCI Review Reply - Version 10.0 (2026-10-28) - Commit: 1a1fa85 (N37〜N45 Fully Resolved)

GHCI ドライバ開発チーム（`amaterrace.ko`）による GHCI レビュー第 10 版（`ghci-review.md` 2026-10-28 03:38）を受理しました。

レビュー第 10 版で提示された残存疑問（N38〜N45）の全件について、ドライバ担当チームの提示された推し案を全面的に受け入れ、仕様書 `docs/ghci.md`、C ヘッダ `include/ghci_cmd.h`、および ISA 定義 `include/gsi1_isa.h` を改訂・コミット（`1a1fa85`）しました。

---

## 1. 疑問点への回答および確定仕様詳細 (N38〜N45)

### N38 (H): 頂点属性スロットとレジスタの割り当て規則
- **(1)(2) 属性スロットとレジスタ配置 (Compact Consecutive ABI)**:
  - PSO の `attributes[16]`（dw16–31）で定義される 16 個の属性スロット（$i = 0..15$、Vulkan の `maxVertexInputAttributes = 16` に完全合致）のうち、有効なスロット（`format != 0`）について、先行する有効スロットの成分数の累積和 $base_i$ から順に、レジスタ $r[base_i \dots base_i + C_i - 1]$ に連続して割り当てられます：
    $$base_0 = 0, \quad base_{i+1} = base_i + C_i \quad (\text{有効スロット } i \text{ ごとに加算})$$
  - 各スロットの有効成分数 $C_i \in [1, 4]$ は `format`（`VkFormat`）から一意に定まります。不足成分（例えば float や vec2/vec3 から vec4 への自動パディング $(0, 0, 0, 1.0)$）はコンパイラ側が補い、ハードウェア VF は有効成分 $C_i$ 個のみをレジスタへ書き込みます。
  - 全属性の合計成分数が 60 本を超えるパイプライン構成（$r0..r59$ に収まらない構成）は、ドライバが作成時に拒絶（`VK_ERROR_INITIALIZATION_FAILED`）します。
- **(3) 未使用スロットの判定**:
  - `format == 0` (`VK_FORMAT_UNDEFINED`) のスロットは無効（disabled）として扱われ、メモリ読み出しおよびレジスタ書き込みは一切行われません。
- **(4) ハードウェア設定の自律化**:
  - Command Processor (CP) は `CMD_BIND_PIPELINE` 実行時に、PSO の `attributes[0..15]` を走査して $base_i$ と $C_i$ を計算し、ハードウェア内部ステート `ATTR_DST[i]` (`0x1C0 + i`) を自律的に構成します。ドライバが直接 `SET_REG` を発行する必要はありません。

### N39 (M): VertexIndex / InstanceIndex の配送条件と r60〜r62
- **配送ゲーティング**:
  - Hardware VF は、`PSO.shader_resource_limits[7:0]` (`used_regs_vs`) $\ge 62$ の場合のみ、$r60$ に `gl_VertexIndex`、$r61$ に `gl_InstanceIndex` を書き込みます。
  - `used_regs_vs < 62` の場合、VF はシステム入力の配送をスキップし、余分なサイクルを消費しません。コンパイラは `gl_VertexIndex` または `gl_InstanceIndex` を参照する頂点シェーダに対して、必ず `used_regs_vs \ge 62` を設定します。
- **r62 の役割**:
  - $r62$ はハードウェアは一切書き込まず、コンパイラ専用の一時計算 / スクラッチレジスタ（`GHCI_VS_REG_SCRATCH`）として予約されます。
  - $r63$ は `rq`（Systolic Array Queue オペランド / ハードウェア予約）です。

### N40 (M): PT バッファのワード割り当てとクリップ座標の直接読み出し
- **クリップ座標の直接読み出し (Direct POS Access)**:
  - PT Word 0..3 には頂点のクリップ座標 $POS.x..w$ が格納されます。フラグメントシェーダの `lda rd, imm` 命令は、PT Word 0..3（特に Word 3 で $POS.w$）を直接読み出すことができます。
  - したがって、noperspective 補間や `FragCoord.w` のために $POS.w$ を Varying スロットに重複エクスポートする必要はなく、全 64 個の Varying ワード（$w = 0..63$、PT Word $4 + w$）をすべてユーザー定義 Varying に割り当て可能です（Vulkan 1.0 の `maxVertexOutputComponents = 64` および `maxFragmentInputComponents = 64` を完全に満たします）。
- **POINT_SIZE**:
  - POINT_SIZE (`0x004`) は PT には格納されません。GHCI 1.0 ではポイントサイズは 1.0 固定（`largePoints = false`, `pointSizeRange = [1.0, 1.0]`）として扱われます。
- **ヘッダ修正**:
  - `include/gsi1_isa.h` の `lda` コメントの記述を「words 0-3 read clip-space POS.x..w」に修正しました。

### N41 (M): `lda` 命令の頂点インデックスと Primitive 規則
- **頂点と重心座標の対応**:
  - `lda` 命令の頂点インデックス $k \in \{0, 1, 2\}$ は、重心座標 $b_k$（$r0, r1, r2$）に対応する頂点を指します。
- **Provoking Vertex 規約**:
  - Vulkan の Primitive Topologies 順に従い、vertex 0 が常に Provoking Vertex（First Vertex convention）となります。フラット補間時は vertex 0 を読み出します。
- **Line / Point プリミティブ時の未定義頂点**:
  - Line 描画時（vertex 0, 1）の vertex 2、および Point 描画時（vertex 0）の vertex 1, 2 は未定義（コンパイラは読み出さない）となります。

### N42 (M): Clip から Window への変換式
- **クリップ体積**: Vulkan 標準規格（$-w \le x, y \le w$、および $0 \le z \le w$）。
- **透視除算**: $x_d = x/w, y_d = y/w, z_d = z/w$。
- **Viewport 写像**: `CMD_SET_VIEWPORT` (§7.3) に従う式を明記：
  $$x_w = \frac{\text{width}}{2} x_d + \left(x + \frac{\text{width}}{2}\right)$$
  $$y_w = \frac{\text{height}}{2} y_d + \left(y + \frac{\text{height}}{2}\right) \quad (\text{または反転指定に従う})$$
  $$z_w = \text{minDepth} + z_d \times (\text{maxDepth} - \text{minDepth})$$
- **Depth Clamp (`PSO.flags[4] = 1`)**:
  - Near/Far 平面でのクリッピングを無効化し、ラスタライザで深度値を $[\text{minDepth}, \text{maxDepth}]$ にクランプします。
- **POINT_SIZE**: GHCI 1.0 では無視されサイズ 1.0 固定。

### N43 (M): カラーアタッチメント数と MRT エクスポート
- **8 アタッチメント MRT エクスポート**:
  - カラーアタッチメント $k \in [0, 7]$、コンポーネント $c \in [0, 3]$ に対するエクスポートターゲットは `0x100 + 16k + c`（ターゲット番号 `0x100`〜`0x173`、12-bit に収まる）と規定しました。
  - `include/ghci_cmd.h` および `include/gsi1_isa.h` の `GHCI_EXP_COLOR(k, c)` を `0x100u + 16u * ((k) & 7u) + (c)` に更新し、`GSI1_COLOR_ATTACHMENTS` を 8 に更新しました。
- **CAP_ROP_PACK との独立性**:
  - MRT エクスポートはハードウェアのコア機能であり、`DEVICE_CAPS[26]` (`CAP_ROP_PACK`) に依存しません（`CAP_ROP_PACK` は非ブレンド整数および 32-bit float アタッチメントの Path 2 パッカーのみを制御します）。

### N44 (L): Dual-Source Blending の SRC1 エクスポートターゲット
- §8.4 1426 行の `export target 0x101` を、§12.10.3 および §12.12 と一致する `0x108..0x10B` (`GHCI_EXP_COLOR0_SRC1(c)`) に修正しました。

### N45 (L): 旧仕様参照の整理とヘッダ同期
- (1) §12.8 2133 行の scratch 参照先を §12.10.2 に更新。
- (2) §12.12 の旧 interface kinds 9-11 に関する段落を削除（§12.10.2 に一元化）。
- (3) §12.10.1 2259 行の参照先を §12.10.3 に更新。
- (4) 旧 GSI1 の CAPS[24]..[30] を `DEVICE_CAPS` / `EXT_CAP_FEATURE` の正式名称に置き換え、CAPS[25]（systolic array: 予約、常に 0、実行時は `GHCI_FAULT_KIND_INVALID_OP`）の対応を §12.1 に明記。
- (5) `include/gsi1_isa.h` を §12.10.3 と完全に整合・同期。

---

## 2. 検証ステータス

- C ヘッダ構文検証: `gcc -fsyntax-only -Iinclude include/ghci_cmd.h include/gsi1_isa.h` $\rightarrow$ **PASS**
- 回帰シミュレーション: `./sim/run.sh atg_cp atg_ghci_slim` $\rightarrow$ **PASS** (100%)
- 禁止略語監査: リポジトリ全域 $\rightarrow$ **0 件完全維持**
- セッション分離・MMU 透過性要件: 完全遵守

DONE