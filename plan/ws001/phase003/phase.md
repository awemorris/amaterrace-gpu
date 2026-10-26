<!-- awesome-plan project=amaterrace-gpu record=ws001-p003 -->

# Phase 003: 共有 L2 キャッシュ（LLC）導入 & キャッシュコヒーレンシ再構築

- **親**: [WS001](../ws.md)
- **状態**: `completed`
- **依存**: [ws001-p002](../phase002/phase.md)
- **担当**: P1 (Implementation) / T1 (Test)
- **優先度**: Critical
- **出典**: R1 敵対的仕様レビュー（観点1: L2 キャッシュ不在による帯域爆発・コヒーレンシ破綻）

## 目的

GPU 全体で共有する Last Level Cache (LLC: 128 KiB〜256 KiB、16-way set-associative) を MC（`atg_mc.v`）直前に導入し、ROP・TU・SU 間のレンダーターゲット/テクスチャピンポンに伴う外部 DDR3 メモリ帯域の飽和を解消する。あわせて、粗野な「キャッシュ全破棄（Full Invalidate）」からライン単位・アドレス範囲指定のコヒーレンシ制御へ移行し、DC の優先帯域（QoS）を保証する。

## 範囲・作業内容

1. **共有 L2 キャッシュ（LLC）モジュールの設計と MC への統合 (`rtl/gpu/mc/atg_mc_l2.v`)**:
   - 容量 256 KiB（ラインサイズ 64 バイト = 4096 ライン、16-way set-associative: 256 sets）。
   - Kintex-7 内蔵 Block RAM (RAMB36E1 / RAMB18E1 推論、または同期デュアルポート BRAM) を使用。
   - Write-back / Write-allocate ポリシー（ダーティラインのみ外部書き戻し）。
   - クライアント集約後のルート AMB リクエストパス（`atg_mc_tree` 出力と `am_axi_master` の間）に配置。
2. **キャッシュライン単位・範囲指定コヒーレンシ制御**:
   - ライン単位のフラッシュ / インバリデート制御。
   - アドレス範囲指定（Range Invalidate / Clean）レジスタまたは CP 制御コマンドインターフェース。
3. **QoS 帯域保証と DC バイパス/プライオリティ**:
   - DC（`ROOT_CLIENT` / `HIGH_MASK`）読み出し時のレイテンシ最小化（L2 ヒット時は 1〜2 サイクル、ミス時も AXI 最優先発行）。
   - ノンキャッシュ可能（NC）領域のアパーチャバイパス。
4. **ハードウェア制約の厳格遵守**:
   - [plan/fpga.md](../../fpga.md) の完全遵守（演算子は `rtl/library/arith/` 経由、クロック分周の禁止等）。
   - `python3 tools/arith-lint.py` および `tools/lint.sh` クリーン。

## 検証基準（受け入れ条件）

- `tools/lint.sh`: 0 errors / 0 warnings（100% clean PASS）。
- `python3 tools/arith-lint.py`: 0 operators outside `rtl/library/arith/`（完全遵守）。
- `sim/run.sh atg_mc_l2`: PASS（8 テストグループ全 PASS、16-way PLRU エビクション、バイパス、フラッシュ）。
- `sim/run.sh atg_mc`: PASS（53 s、Case A〜F 全 PASS、シミュレーションサイクル 7.16 億 ps → 2.56 億 ps へ 1/3 に短縮）。
- コミット: `f78b016` (初期), `28c81ba` (是正)
- R1 レビュー: **APPROVE** (2026-10-27, `adversarial_review_ws001_p003_remediation.md`)
  - `HAS_L2 = 0` デフォルト化による後方互換性担保。
  - `flush` による全 256 セットダーティライン書き戻し・フラッシュ（`S_FLUSH_STEP`）動作確認。
  - `sim/run.sh atg_mc_l2` PASS (1 s), `sim/run.sh atg_mc` PASS (56 s), `sim/run.sh atg_top` PASS (23 s), `sim/verilator/run.sh basic` PASS (1,131 cycles)。
- 完了確定: 2026-10-27 (Phase 003 是正完了承認)
