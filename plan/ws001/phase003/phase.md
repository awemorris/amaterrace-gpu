<!-- awesome-plan project=amaterrace-gpu record=ws001-p003 -->

# Phase 003: 共有 L2 キャッシュ（LLC）導入 & キャッシュコヒーレンシ再構築

- **親**: [WS001](../ws.md)
- **状態**: `in-progress`
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

- `tools/lint.sh`: 0 errors / 0 warnings。
- `python3 tools/arith-lint.py`: 0 operators outside `rtl/library/arith/`。
- `sim/run.sh atg_mc` および `sim/run.sh -q`: L2 ヒット/ミス/エビクション/コヒーレンシテスト全 PASS。
- 外部 AXI トラフィックの削減率（キャッシュヒット時の AXI バス非発行）の検証。
