# GHCI Review Reply - Version 17.0 (2026-10-28) - Commit: 052a0f3

zedBSD ドライバ担当殿の GHCI レビュー 第 17 版（N78, N79）に対する Amaterrace GPU 側の確定回答および仕様・コード整合状況です。

---

## ■ 各指摘事項への回答

### N78: 頂点属性レジスタ割り当ての食い違い（Consecutive Register Allocation vs 固定 vec4 式）

- **(1) 正しいのは ghci.md の累積か、header の 4 × loc + comp か**:
  - **正本 `docs/ghci.md` §12.10.3 の「Compact Consecutive 累積配置（$base_0 = 0, base_{i+1} = base_i + C_i$）」が 100% 正しい仕様です。**
  - ハードウェアの Vertex Fetch 変換モジュール（`rtl/gpu/vf/atg_vf_conv.v`）は、レジスタ `ATTR_DST[k][5:0]` に指定されたベースアドレスから始まる連続レジスタに、$C_k$ 個の有効成分を 1 語ずつ直接書き込みます（`register ATTR_DST[5:0] + c (mod 64)`）。
  - したがって、ドライバ側で現在実装されている「正本の累積 $base_i$ によるコンパイル」が完全に正しい動作です。

- **(2) `ghci_cmd.h` とファームウェアの整合修正状況**:
  - **`include/ghci_cmd.h` の改訂 (Commit: `052a0f3`)**:
    ```c
    /* Vertex Shader General Register Allocation ABI (§12.10.3 Consecutive Register Allocation) */
    #define GHCI_VS_REG_ATTR_COMP(base, comp)   (((uint32_t)(base)) + ((uint32_t)(comp) & 3u))
    #define GHCI_VS_REG_ATTR(base, comp)        GHCI_VS_REG_ATTR_COMP(base, comp)
    /* Legacy fixed 4-component slot mapping (deprecated, provided for backward compatibility) */
    #define GHCI_VS_REG_ATTR_LEGACY(loc, comp)  (((uint32_t)(loc) * 4u) + ((uint32_t)(comp) & 3u))
    ```
    正本仕様（`base + comp`）に完全準拠する形に更新し、旧固定式は `GHCI_VS_REG_ATTR_LEGACY` に分離・非推奨化しました。
  - **ファームウェア（`fw/cp/ghci_cmd.c`）の改訂 (Commit: `052a0f3`)**:
    - `CMD_BIND_PIPELINE`（`fw_cmd_bind_pipeline_pso`）において、`pso.attributes[0..15]` を走査し、`format != 0` の各有効スロットについて $C_i$（1..4）を取得して $base_i$ を自律累積計算し、ハードウェア状態 `ATTR_DST[i]`（`0x1C0 + i`）に `(base_i & 0x3F) | ((C_i - 1) << 6) | (format << 24)` を自動設定する Autonomous Hardware Configuration 処理を完全実装しました。
    - 無効スロット（`format == 0`）は `ATTR_DST[i] = 0` で確実に無効化されます。

---

### N79: Multisample アタッチメント行ピッチ（`row_pitch_bytes`）の食い違い

- **(1) multisample の attachment の行の pitch は P か、64 byte に揃えた値か**:
  - 行内の最小必要バイト幅は $P_{\text{min}} = \text{roundup}(\text{width}, 2) \times S \times ps$ です（クアッド単位でラスタライズされるため幅は 2 の倍数に切り上げ）。
  - メモリバス・キャッシュライン整列（AMB / MIG 64-byte バースト転送効率）を最大限に発揮するため、ドライバは **`row_pitch_bytes = roundup(P_min, 64)`** を指定してアタッチメントを配置することを推奨・標準とします。
  - ただし、ハードウェアの行アドレス計算乗算器は任意のバイト幅を許容するため、パッキングされた $P_{\text{min}}$ をそのまま指定した場合でも論理的に正しく動作します。

- **(2) 記述の `row_pitch_bytes` を hardware は使うのか（P を自分で計算して記述の値を無視するのか）**:
  - **ハードウェア（ROP: `atg_rop_wpix.v`, `atg_rop_ds.v`）は、アタッチメント記述で与えられた `row_pitch_bytes`（`GHCI_S_RT_STRIDE`, `GHCI_S_DS_STRIDE`）をそのまま行ストライドとして直接乗算器（`am_mul`）に入力し、$y \times \text{row\_pitch\_bytes}$ を計算します。**
  - ハードウェアが独自に $P$ を再計算してドライバの記述値を無視することは一切ありません。

- **(3) multisample の texture（`texf` で sample を読む）の行も P か**:
  - Texture Unit（`atg_tu_addr.v`）も ROP と同様に、`GhciTextureDescriptor.row_pitch_bytes` に指定された値をそのまま 1 行のストライドとして直接使用します。
  - したがって、Multisample Texture においてもドライバが記述した `row_pitch_bytes`（推奨: `roundup(P_min, 64)`）がそのまま適用されます。

- **`docs/ghci.md` §8.4 および §12.11 の整合改訂 (Commit: `052a0f3`)**:
  - §8.4 および §12.11 の記述を上記のハードウェア動作および `row_pitch_bytes` の定義に完全整合させました。

---

以上の改訂により、N78・N79 は完全に解決・整合いたしました。ご確認・Signoff のほどよろしくお願いいたします。

DONE
