# OOC合成・組み合わせ検証マトリックス (Module Combination Matrix)

本書は、Amaterrace GPU (ATG1) の 200 MHz（周期 5.000 ns）動作達成およびエリア最適化を効率的に進めるため、主要 13 モジュールにおける**単体 OOC (Out-of-Context) 合成テスト用の組み合わせマトリックス**を定義する。

---

## 1. 検証対象モジュール一覧 (13モジュール)

| 略称 | モジュール名 | 主要 RTL トップ | 主な役割 |
| :--- | :--- | :--- | :--- |
| **`blt`** | BitBLT 2D Engine | `rtl/gpu/blt/atg_blt_2d.v` | 2D 矩形転送・拡大縮小・フォーマット変換 |
| **`cp`** | Command Processor | `rtl/gpu/cp/atg_cp.v` | ホストコマンド解釈、リングバッファ、状態管理 |
| **`dc`** | Display Controller | `rtl/gpu/dc/atg_dc.v` | 画面表示・スキャンアウト・TMDS/HDMI 出力 |
| **`fmt`** | Format Engine | `rtl/gpu/fmt/atg_fmt_cvt.v` | テクセル/頂点/カラーのフォーマット変換・展開 |
| **`mc`** | Memory Controller & L2 | `rtl/gpu/mc/atg_mc.v` | メモリ統合制御、L2 キャッシュ、AMB/AXI 調停 |
| **`mmu`** | Memory Management Unit | `rtl/gpu/mmu/atg_mmu.v` | 仮想記憶変換、L1 TLB、ページテーブルウォーカー |
| **`rop`** | Render Output Backend | `rtl/gpu/rop/atg_rop.v` | ブレンディング、Depth/Stencil テスト、カラー書込 |
| **`rx`** | Rasterizer | `rtl/gpu/rx/atg_rx.v` | トライアングルセットアップ、走査変換、MSAA |
| **`sa`** | Systolic Array (Tensor) | `rtl/gpu/su/atg_su_sa.v` | 行列積積和演算アクセラレータ (AI/Tensor) |
| **`su`** | Shader Unit | `rtl/gpu/su/atg_su.v` | SIMD 実行ユニット、ALU、レジスタファイル、LDS |
| **`top`** | GPU Core Full Top | `rtl/gpu/atg_top.v` | 全ユニット統合フルチップコア |
| **`tu`** | Texture Unit | `rtl/gpu/tu/atg_tu.v` | テクスチャサンプリング、フィルタリング、L1 キャッシュ |
| **`vf`** | Vertex Fetch | `rtl/gpu/vf/atg_vf.v` | 頂点バッファ取得、頂点キャッシュ、属性変換 |

---

## 2. 組み合わせの軸 (Matrix Axes)

各モジュールについて、以下の 3 軸（直交組み合わせ）を交差させてテストケースを網羅的に定義する。

### 軸 A: 機能性 (Functionality)
1. **`FULL`**: コンフィグで**すべての機能を有効**
2. **`BARE`**: コンフィグで**すべての拡張機能を無効**（ベースライン動作のみ）
3. **`ISO-<Feature>`**: コンフィグで**1つずつの機能を単独有効化**（1-Hot: 単体機能遅延を単離）
4. **`PAIR-<F1>+<F2>`**: コンフィグで**任意の2つのオプション機能を有効化**（2-Hot: 相互干渉・MUX段数評価）
5. **`TRIO-<F1>+<F2>+<F3>`**: コンフィグで**任意の3つのオプション機能を有効化**（3-Hot: 複合データパス遅延評価）
6. **`QUAD-<F1>+<F2>+<F3>+<F4>`**: コンフィグで**任意の4つのオプション機能を有効化**（4-Hot: 高負荷機能統合評価）

### 軸 B: サイズ / キャッシュ容量 (Size & Capacity)
1. **`MAX`**: 最大構成（High-Performance Preset 相当）
2. **`HALF`**: 1/2 構成（Balanced Preset 相当）
3. **`QUARTER`**: 1/4 構成（Mid-Low 構成）
4. **`MIN`**: 最小構成（Minimal Preset 相当）

### 軸 C: SU SIMT 物理レーン数 (SU SIMT Lane Configuration)
*Shader Unit (`su`) 専用の直交マトリックス次元*
1. **`LANE-2`** (`NPHYS=2`): 2-lane 物理 SIMD（組込み・極小フットプリント構成）
2. **`LANE-4`** (`NPHYS=4`): 4-lane 物理 SIMD（Minimal Preset 基準構成）
3. **`LANE-8`** (`NPHYS=8`): 8-lane 物理 SIMD（Kintex-7 325T 推奨・Balanced 構成）
4. **`LANE-16`** (`NPHYS=16`): 16-lane 物理 SIMD（ミッドレンジ GPU 構成）
5. **`LANE-32`** (`NPHYS=32`): 32-lane 物理 SIMD（フルワープ単一サイクル実行・High-End 構成）

---

## 3. モジュール別 テスト組み合わせマトリックス

---

### (1) `blt` (BitBLT 2D Engine)
- **関連ファイル**: `rtl/gpu/blt/atg_blt_2d.v`
- **機能フラグ**:
  - `F_ROP3`: ROP3 論理演算 (Ternary Raster Operations)
  - `F_SCALING`: 拡大縮小・バイリニア補間スケーリング
  - `F_FMT_CVT`: 各種カラーフォーマット相互変換
  - `F_CLIP`: クリッピング境界判定
- **サイズ設定 (ラインバッファ / FIFO 深度)**:
  - `MAX`: 64 beats / 512B
  - `HALF`: 32 beats / 256B
  - `QUARTER`: 16 beats / 128B
  - `MIN`: 4 beats / 32B

| テスト ID | 機能性 (Functionality) | サイズ (Size) | 主な設定内容 | 検証・評価観点 |
| :--- | :--- | :--- | :--- | :--- |
| `BLT-F-MAX` | `FULL` (全有効) | `MAX` | ROP3+Scaling+FmtCvt+Clip, FIFO=64 | 全機能有効時のワースト遅延・最大リソース |
| `BLT-B-MIN` | `BARE` (全無効) | `MIN` | Direct Copy のみ, FIFO=4 | 最軽量フットプリント・基本パス遅延 |
| `BLT-I-ROP` | `ISO-ROP3` | `MIN` | ROP3 単独有効, FIFO=4 | 論理演算回路のタイミング影響 |
| `BLT-I-SCL` | `ISO-Scaling` | `MIN` | Scaling 単独有効, FIFO=4 | 乗算器・補間パスの 200MHz 適合性 |
| `BLT-I-FMT` | `ISO-FmtCvt` | `MIN` | FmtCvt 単独有効, FIFO=4 | フォーマット展開段の遅延 |
| `BLT-P-RS` | `PAIR-ROP3+Scl` | `MIN` | ROP3 + Scaling 有効, FIFO=4 | 拡大縮小と論理演算の複合遅延 |
| `BLT-P-SF` | `PAIR-Scl+Fmt` | `MIN` | Scaling + FmtCvt 有効, FIFO=4 | 補間乗算とフォーマット変換の直結遅延 |
| `BLT-P-FC` | `PAIR-Fmt+Clip` | `MIN` | FmtCvt + Clip 有効, FIFO=4 | 境界判定とカラー展開の複合パス |
| `BLT-T-RSF` | `TRIO-ROP+Scl+Fmt` | `MIN` | ROP3 + Scaling + FmtCvt, FIFO=4 | 3機能有効時の MUX カスケード遅延 |
| `BLT-T-SFC` | `TRIO-Scl+Fmt+Clp` | `MIN` | Scaling + FmtCvt + Clip, FIFO=4 | 演算・変換・クリップ統合パス |
| `BLT-Q-ALL` | `QUAD-All4` | `MIN` | ROP3 + Scaling + FmtCvt + Clip, FIFO=4 | 4機能全有効 (最小バッファ) での 200MHz 検証 |
| `BLT-S-HALF` | `FULL` | `HALF` | 全機能有効, FIFO=32 | 中間バッファサイズでの P&R 余裕度 |
| `BLT-S-QTR` | `FULL` | `QUARTER` | 全機能有効, FIFO=16 | エリア/タイミングのバランス評価 |

---

### (2) `cp` (Command Processor)
- **関連ファイル**: `rtl/gpu/cp/atg_cp.v`, `rtl/gpu/cp/atg_cp_state.v`
- **機能フラグ**:
  - `F_AUTO_MMU`: 自律ページテーブルウォーカー連動 (`CONFIG_CP_AUTONOMOUS_MMU`)
  - `F_RV32`: RV32 マイクロコントローラコア (`CONFIG_CP_USE_RV32_CORE`)
  - `F_INDIRECT`: インダイレクト描画/計算ディスパッチ
  - `F_STATE_BC`: 状態ブロードキャスト追従
- **サイズ設定 (IMEM / DMEM / コマンド FIFO)**:
  - `MAX`: IMEM 32KB, DMEM 16KB, Ring FIFO 64 entries
  - `HALF`: IMEM 16KB, DMEM 8KB, Ring FIFO 32 entries
  - `QUARTER`: IMEM 8KB, DMEM 4KB, Ring FIFO 16 entries
  - `MIN`: IMEM 2KB, DMEM 1KB, Ring FIFO 4 entries

| テスト ID | 機能性 (Functionality) | サイズ (Size) | 主な設定内容 | 検証・評価観点 |
| :--- | :--- | :--- | :--- | :--- |
| `CP-F-MAX` | `FULL` (全有効) | `MAX` | AutoMMU=1, RV32=1, IMEM=32K/16K | 最大構成での BRAM/LUT と 200MHz 達成 |
| `CP-B-MIN` | `BARE` (全無効) | `MIN` | HWステートマシンのみ, IMEM=2K | 最小構成での制御パス遅延 |
| `CP-I-MMU` | `ISO-AutoMMU` | `MIN` | AutoMMU 単独有効 | ページフォールト/ウォーカー連携パス |
| `CP-I-RV32` | `ISO-RV32` | `MIN` | RV32 コア単独有効 | RISC-V パイプライン段の 200MHz 適合性 |
| `CP-I-IND` | `ISO-Indirect` | `MIN` | Indirect 実行単独有効 | DMAフェッチから実行へのレイテンシ |
| `CP-P-MR` | `PAIR-MMU+RV32` | `MIN` | AutoMMU + RV32 有効 | MMU 連携命令と RISC-V 制御の結合パス |
| `CP-P-RI` | `PAIR-RV32+Ind` | `MIN` | RV32 + Indirect 有効 | FW によるインダイレクトパケット生成遅延 |
| `CP-P-IS` | `PAIR-Ind+State`| `MIN` | Indirect + StateBC 有効 | インダイレクト実行時の状態同期パス |
| `CP-T-MRI` | `TRIO-MMU+RV+Ind`| `MIN` | AutoMMU + RV32 + Indirect | 高機能制御 3 要素統合時の FSM 遅延 |
| `CP-T-RIS` | `TRIO-RV+Ind+St`| `MIN` | RV32 + Indirect + StateBC | コントローラ・ディスパッチ・状態同期間の相互遅延 |
| `CP-Q-ALL` | `QUAD-All4` | `MIN` | AutoMMU + RV32 + Ind + StateBC | 4機能全有効 (最小メモリ) での 200MHz 検証 |
| `CP-S-HALF` | `FULL` | `HALF` | 全機能有効, IMEM=16K/8K | バランス型メモリフットプリント |
| `CP-S-QTR` | `FULL` | `QUARTER` | 全機能有効, IMEM=8K/4K | 軽量 RV32 構成でのタイミング確認 |

---

### (3) `dc` (Display Controller)
- **関連ファイル**: `rtl/gpu/dc/atg_dc.v`, `atg_dc_tmds.v`, `atg_dc_plane2.v`
- **機能フラグ**:
  - `F_CURSOR`: ハードウェアカーソルオーバーレイ (`CONFIG_DC_ENABLE_CURSOR`)
  - `F_PLANE2`: 第2プレーン合成 (Video/UI Overlay)
  - `F_TMDS`: HDMI TMDS エンコード・シリアライザ
  - `F_GAMMA`: ガンマ補正 LUT / ディザリング
- **サイズ設定 (ピクセル FIFO / スキャンラインバッファ)**:
  - `MAX`: 2048 words (Full HD 余裕バッファ)
  - `HALF`: 1024 words
  - `QUARTER`: 512 words
  - `MIN`: 128 words (最小ラインバッファ)

| テスト ID | 機能性 (Functionality) | サイズ (Size) | 主な設定内容 | 検証・評価観点 |
| :--- | :--- | :--- | :--- | :--- |
| `DC-F-MAX` | `FULL` (全有効) | `MAX` | Cursor=1, Plane2=1, TMDS=1, FIFO=2048 | 1080p 60Hz スキャンアウトと 200MHz 同期 |
| `DC-B-MIN` | `BARE` (全無効) | `MIN` | 単一プレーン直接出力, FIFO=128 | 最小ピクセルデータパス遅延 |
| `DC-I-CUR` | `ISO-Cursor` | `MIN` | Cursor 単独有効 | カーソルブレンディング位置計算パス |
| `DC-I-PL2` | `ISO-Plane2` | `MIN` | Plane2 単独有効 | 複数ピクセルストリームの多重化遅延 |
| `DC-I-TMD` | `ISO-TMDS` | `MIN` | TMDS 単独有効 | 10b8b エンコードの論理段数 |
| `DC-P-CP` | `PAIR-Cur+Plane2`| `MIN` | Cursor + Plane2 有効 | カーソルと第2プレーン重畳の加算・MUX段 |
| `DC-P-PT` | `PAIR-Pl2+TMDS` | `MIN` | Plane2 + TMDS 有効 | 複数プレーン合成から TMDS 直接出力 |
| `DC-P-CG` | `PAIR-Cur+Gamma` | `MIN` | Cursor + Gamma 有効 | カーソルブレンド後のガンマ補正遅延 |
| `DC-T-CPT` | `TRIO-Cur+Pl2+TMD`| `MIN` | Cursor + Plane2 + TMDS | 重畳・合成・シリアライズ 3段パイプライン |
| `DC-T-CPG` | `TRIO-Cur+Pl2+Gam`| `MIN` | Cursor + Plane2 + Gamma | 複合ブレンド＋ガンマ変換の論理段数 |
| `DC-Q-ALL` | `QUAD-All4` | `MIN` | Cursor + Plane2 + TMDS + Gamma | 4機能全有効 (最小FIFO) での 200MHz 検証 |
| `DC-S-HALF` | `FULL` | `HALF` | 全機能有効, FIFO=1024 | 実用構成での BRAM/LUT バランス |
| `DC-S-QTR` | `FULL` | `QUARTER` | 全機能有効, FIFO=512 | リソース逼迫時のスキャンアウト安定性 |

---

### (4) `fmt` (Format Engine)
- **関連ファイル**: `rtl/gpu/fmt/atg_fmt_cvt.v`, `atg_fmt_comp.v`, `atg_fmt_unorm.v`
- **機能フラグ**:
  - `F_FP16`: FP16 浮動小数点デコード/エンコード (`CONFIG_FMT_ENABLE_FP16`)
  - `F_FP32`: FP32 フル精度展開 (`CONFIG_FMT_ENABLE_FP32`)
  - `F_SRGB`: sRGB ガンマ展開テーブル (`CONFIG_FMT_ENABLE_SRGB`)
  - `F_SNORM`: SNORM 符号付き正規化演算
  - `F_PACKED`: A2B10G10R10, RGB565, B8G8R8A8 等のパック形式
  - `F_DEPTH`: D24S8, D32F, D16 デプス・ステンシル形式群
- **サイズ設定 (変換テーブル / パイプライン段数)**:
  - `MAX`: 7段パイプライン (`atg_fmt_cvt`), 完全展開 ROM
  - `HALF`: 5段パイプライン
  - `QUARTER`: 3段パイプライン
  - `MIN`: 1段 (組合せ `atg_fmt_comp` または 2段最小)

| テスト ID | 機能性 (Functionality) | サイズ (Size) | 主な設定内容 | 検証・評価観点 |
| :--- | :--- | :--- | :--- | :--- |
| `FMT-F-MAX` | `FULL` (全有効) | `MAX` | 全形式有効, 7段パイプライン (`atg_fmt_cvt`) | **200 MHz クローズ実証 (WNS +1.729 ns 確認済)** |
| `FMT-B-MIN` | `BARE` (全無効) | `MIN` | RGBA8 UINT/UNORM のみ, 2段最小 | 最小セル数および基本変換遅延 |
| `FMT-I-FP16` | `ISO-FP16` | `MAX` | FP16 相互変換のみ単独有効 | 半精度浮動小数点正規化シフタの遅延 |
| `FMT-I-SRGB` | `ISO-sRGB` | `MAX` | sRGB テーブルのみ単独有効 | ROM LUT (256x28) 読出パス |
| `FMT-I-SNRM` | `ISO-SNORM` | `MAX` | SNORM のみ単独有効 | 符号反転・最大値クランプ演算パス |
| `FMT-I-DEP` | `ISO-Depth` | `MAX` | D24S8 / D32F のみ単独有効 | デプスビット抽出・浮動小数点変換パス |
| `FMT-P-FS` | `PAIR-FP16+sRGB` | `MAX` | FP16 + sRGB 有効 | 半精度変換とガンマテーブルの複合 |
| `FMT-P-PD` | `PAIR-Pack+Depth`| `MAX` | Packed + Depth 有効 | パック展開とデプス変換の並行パス |
| `FMT-P-SS` | `PAIR-FP32+SNORM`| `MAX` | FP32 + SNORM 有効 | フル精度浮動小数点と符号付き正規化 |
| `FMT-T-FSP` | `TRIO-FP16+sRGB+Pk`| `MAX`| FP16 + sRGB + Packed | 3種の主力カラー形式の統合遅延 |
| `FMT-T-SPD` | `TRIO-sRGB+Pk+Dep`| `MAX`| sRGB + Packed + Depth | 多形式同時デコード時の MUX ツリー遅延 |
| `FMT-Q-FPSD`| `QUAD-FP16+sR+Pk+Dp`| `MAX`| FP16 + sRGB + Packed + Depth | 代表 4 形式統合時の 200MHz 検証 |
| `FMT-S-HALF` | `FULL` | `HALF` | 全機能有効, 5段パイプライン | レイテンシ削減時の周波数限界 |
| `FMT-S-QTR` | `FULL` | `QUARTER` | 全機能有効, 3段パイプライン | 論理段数と動作周波数のトレードオフ |

---

### (5) `mc` (Memory Controller & L2 Cache)
- **関連ファイル**: `rtl/gpu/mc/atg_mc.v`, `rtl/gpu/mc/atg_mc_l2.v`, `atg_mc_coalesce.v`
- **機能フラグ**:
  - `F_PROT`: メモリ保護・不正アクセス検知 (`CONFIG_MC_ENABLE_PROT`)
  - `F_COALESCE`: リクエスト結合 (Burst Coalescing)
  - `F_PREFETCH`: ストリームプリフェッチ
  - `F_PRIORITY`: QoS/クライアント優先度制御 (`atg_mc_grant`)
- **サイズ設定 (L2 キャッシュ容量 & Way 数)**:
  - `MAX`: 128 KiB / 16-way
  - `HALF`: 32 KiB / 8-way
  - `QUARTER`: 16 KiB / 4-way
  - `MIN`: 4 KiB / 2-way

| テスト ID | 機能性 (Functionality) | サイズ (Size) | 主な設定内容 | 検証・評価観点 |
| :--- | :--- | :--- | :--- | :--- |
| `MC-F-MAX` | `FULL` (全有効) | `MAX` | L2=128KB, 16-way, Prot=1, Coalesce=1 | 巨大タグ比較・多Way選択時の 200MHz 適合性 |
| `MC-B-MIN` | `BARE` (全無効) | `MIN` | L2=4KB, 2-way, Prot=0, 単純調停 | 最軽量構成の基本メモリパス遅延 |
| `MC-I-PROT` | `ISO-Prot` | `MIN` | メモリ保護単独有効, L2=4KB | アドレス境界チェック加算器の遅延 |
| `MC-I-COAL` | `ISO-Coalesce` | `MIN` | リクエスト結合単独有効, L2=4KB | コアレス判定回路のタイミング影響 |
| `MC-I-PRIO` | `ISO-Priority` | `MIN` | QoS調停単独有効, L2=4KB | 多入力グラント回路のクリティカルパス |
| `MC-P-PC` | `PAIR-Prot+Coalesce`| `MIN` | Prot + Coalesce 有効, L2=4KB | 保護判定と結合バッファの直列遅延 |
| `MC-P-CP` | `PAIR-Coal+Prefetch`| `MIN` | Coalesce + Prefetch 有効, L2=4KB | 結合とプリフェッチのアドレス生成競合 |
| `MC-P-PR` | `PAIR-Prot+Priority`| `MIN` | Prot + Priority 有効, L2=4KB | セキュリティとQoS調停の複合パス |
| `MC-T-PCP` | `TRIO-Prot+Col+Pre` | `MIN` | Prot + Coalesce + Prefetch | 要求解析・結合・先読みの 3段複合 |
| `MC-T-CPR` | `TRIO-Col+Pre+Prio` | `MIN` | Coalesce + Prefetch + Priority | 高負荷帯域制御回路のタイミング |
| `MC-Q-ALL` | `QUAD-All4` | `MIN` | Prot + Coalesce + Pref + Prio | 4機能全有効 (最小L2) での 200MHz 検証 |
| `MC-S-HALF` | `FULL` | `HALF` | 全機能有効, L2=32KB, 8-way | バランス構成でのタイミングと配線混雑 |
| `MC-S-QTR` | `FULL` | `QUARTER` | 全機能有効, L2=16KB, 4-way | KC705 推奨構成での BRAM・LUT 最適化 |

---

### (6) `mmu` (Memory Management Unit & TLB)
- **関連ファイル**: `rtl/gpu/mmu/atg_mmu.v`, `rtl/gpu/mmu/atg_tlb_l1.v`, `atg_mmu_walker.v`
- **機能フラグ**:
  - `F_WALKER`: 2レベル自律ページテーブルウォーカー
  - `F_PARALLEL`: 複数クライアント並列 TLB 探索
  - `F_SUPERPAGE`: 2MB / 1GB 巨大ページサポート
  - `F_FAULT`: ページフォールト割り込み生成
- **サイズ設定 (L1 / L2 TLB エントリ数)**:
  - `MAX`: L1 64 entries (全CAM) / L2 512 entries
  - `HALF`: L1 32 entries / L2 256 entries
  - `QUARTER`: L1 16 entries / L2 128 entries
  - `MIN`: L1 8 entries / L2 なし (ウォーカー直結)

| テスト ID | 機能性 (Functionality) | サイズ (Size) | 主な設定内容 | 検証・評価観点 |
| :--- | :--- | :--- | :--- | :--- |
| `MMU-F-MAX` | `FULL` (全有効) | `MAX` | L1=64 (CAM), L2=512, Walker=1, SuperPage=1 | 64エントリ CAM 並列一致判定の 200MHz 適合性 |
| `MMU-B-MIN` | `BARE` (全無効) | `MIN` | L1=8, L2=0, 基本ページ変換のみ | 最小アドレス変換レイテンシ |
| `MMU-I-WLK` | `ISO-Walker` | `MIN` | 自律ウォーカー単独有効 | メモリアクセス生成ステートマシンの遅延 |
| `MMU-I-PAR` | `ISO-Parallel` | `MIN` | 複数クライアント並列ルックアップ | 多重ポート調停回路のタイミング |
| `MMU-I-SUP` | `ISO-SuperPage`| `MIN` | 巨大ページ単独有効 | 可変マスク長比較ロジックの遅延 |
| `MMU-P-WP` | `PAIR-Walk+Parallel`| `MIN` | Walker + Parallel 有効 | 並列探索ミス時のウォーカー調停パス |
| `MMU-P-WS` | `PAIR-Walk+SuperPg` | `MIN` | Walker + SuperPage 有効 | ウォーカーでの2MB/1GBページ判定遅延 |
| `MMU-P-PF` | `PAIR-Parallel+Fault`| `MIN` | Parallel + Fault 有効 | 複数ポート並列フォールト検出・エンコード |
| `MMU-T-WPS` | `TRIO-Walk+Par+Sup` | `MIN` | Walker + Parallel + SuperPage | 高度仮想記憶 3 機能の複合データパス |
| `MMU-T-WPF` | `TRIO-Walk+Par+Fault`| `MIN` | Walker + Parallel + Fault | 例外・並列ミス処理の統合遅延 |
| `MMU-Q-ALL` | `QUAD-All4` | `MIN` | Walker + Par + Sup + Fault | 4機能全有効 (最小TLB) での 200MHz 検証 |
| `MMU-S-HALF` | `FULL` | `HALF` | 全機能有効, L1=32, L2=256 | 中規模 CAM の LUT 消費と周波数の両立 |
| `MMU-S-QTR` | `FULL` | `QUARTER` | 全機能有効, L1=16, L2=128 | タイミング・エリアのバランス点 |

---

### (7) `rop` (Render Output Backend)
- **関連ファイル**: `rtl/gpu/rop/atg_rop.v`, `rtl/gpu/rop/atg_rop_ds.v`, `rtl/gpu/rop/atg_rop_wb.v`
- **機能フラグ**:
  - `F_FBLEND`: 浮動小数点ブレンド (`CONFIG_ROP_ENABLE_FBLEND`)
  - `F_PACK`: パッキング・フォーマット変換 (`CONFIG_ROP_ENABLE_PACK`)
  - `F_DUAL_SRC`: デュアルソースブレンディング (`CONFIG_ROP_DUAL_SOURCE`)
  - `F_LOGICOP`: ビットワイズ論理演算 (`CONFIG_ROP_ENABLE_LOGICOP`)
  - `F_FAST_CLR`: 高速クリア (`CONFIG_ROP_FAST_CLEAR`)
- **サイズ設定 (MRT 数 & キャッシュ容量)**:
  - `MAX`: MRT 8, キャッシュ 32 KiB
  - `HALF`: MRT 4, キャッシュ 16 KiB
  - `QUARTER`: MRT 2, キャッシュ 8 KiB
  - `MIN`: MRT 1, キャッシュ 2〜4 KiB

| テスト ID | 機能性 (Functionality) | サイズ (Size) | 主な設定内容 | 検証・評価観点 |
| :--- | :--- | :--- | :--- | :--- |
| `ROP-F-MAX` | `FULL` (全有効) | `MAX` | MRT=8, FBlend=1, DualSrc=1, Cache=32K | フル機能時の 512-bit データパスと配線混雑 |
| `ROP-B-MIN` | `BARE` (全無効) | `MIN` | MRT=1, 不透明上書きのみ, Cache=2K | 最小構成での基本ブレンド・デプス遅延 |
| `ROP-I-FBL` | `ISO-FBlend` | `MIN` | 浮動小数点ブレンド単独有効 | FP16/FP32 加算・乗算演算器の遅延 |
| `ROP-I-DS` | `ISO-DualSrc` | `MIN` | デュアルソースブレンド単独有効 | 2入力カラー合成パスのタイミング |
| `ROP-I-LOG` | `ISO-LogicOp` | `MIN` | 論理演算単独有効 | ビット演算 MUX パスの遅延 |
| `ROP-I-MRT` | `ISO-MRT4` | `MIN` | MRT=4 単独有効 | 複数レンダーターゲット展開パスの遅延 |
| `ROP-P-FP` | `PAIR-FBlend+Pack` | `MIN` | FBlend + Pack 有効 | 浮動小数点ブレンドとパック書込の直列遅延 |
| `ROP-P-FD` | `PAIR-FBlend+Dual` | `MIN` | FBlend + DualSrc 有効 | 2ソース入力の浮動小数点ブレンドパイプライン |
| `ROP-P-PL` | `PAIR-Pack+LogicOp`| `MIN` | Pack + LogicOp 有効 | 論理演算とフォーマット変換の結合 |
| `ROP-T-FPD` | `TRIO-FBl+Pack+Dual`| `MIN` | FBlend + Pack + DualSrc | 高度ブレンディング 3 系統の統合遅延 |
| `ROP-T-FPL` | `TRIO-FBl+Pack+Log` | `MIN` | FBlend + Pack + LogicOp | 浮動小数点・論理・パックの選択 MUX 遅延 |
| `ROP-Q-FPDL`| `QUAD-FBl+Pk+Du+Log`| `MIN` | FBlend + Pack + Dual + Logic | 代表 4 機能有効 (最小MRT) での 200MHz 検証 |
| `ROP-S-HALF` | `FULL` | `HALF` | 全機能有効, MRT=4, Cache=16K | 中規模レンダーターゲットの 200MHz 適合性 |
| `ROP-S-QTR` | `FULL` | `QUARTER` | 全機能有効, MRT=2, Cache=8K | バランス構成でのタイミングとエリア |

---

### (8) `rx` (Rasterizer)
- **関連ファイル**: `rtl/gpu/rx/atg_rx.v`, `rtl/gpu/rx/atg_rx_scan.v`, `rtl/gpu/rx/atg_rx_edge.v`
- **機能フラグ**:
  - `F_MSAA`: MSAA マルチサンプル (`CONFIG_RX_ENABLE_MSAA`, 4x/8x)
  - `F_EARLY_Z`: Early-Z / Hi-Z カリング (`CONFIG_RX_ENABLE_EARLY_Z`)
  - `F_COARSE`: 粗粒度 8x8 タイルスキャン (`CONFIG_RX_COARSE_SCAN`)
  - `F_SCISSOR`: シザー・ビューポートクリッピング
- **サイズ設定 (Hi-Z バッファ / エッジ FIFO 深度)**:
  - `MAX`: Hi-Z 8 KiB, Edge FIFO 64 entries, 4x MSAA
  - `HALF`: Hi-Z 4 KiB, Edge FIFO 32 entries, 2x MSAA
  - `QUARTER`: Hi-Z 2 KiB, Edge FIFO 16 entries, 1x MSAA
  - `MIN`: Hi-Z 0 KB (無効), Edge FIFO 4 entries, 1x MSAA

| テスト ID | 機能性 (Functionality) | サイズ (Size) | 主な設定内容 | 検証・評価観点 |
| :--- | :--- | :--- | :--- | :--- |
| `RX-F-MAX` | `FULL` (全有効) | `MAX` | MSAA=4x, Early-Z=1, Coarse=1, FIFO=64 | 全機能有効時のエッジ方程式・カリング遅延 |
| `RX-B-MIN` | `BARE` (全無効) | `MIN` | 1x MSAA, Early-Z=0, Coarse=0, FIFO=4 | 単純ラスタライズの最小基本遅延 |
| `RX-I-MSAA` | `ISO-MSAA` | `MIN` | MSAA 4x 単独有効 | サンプル位置オフセット生成パス |
| `RX-I-EZ` | `ISO-EarlyZ` | `MIN` | Early-Z 単独有効 | Hi-Z 比較およびデプス判定遅延 |
| `RX-I-CRS` | `ISO-Coarse` | `MIN` | Coarse Scan 単独有効 | 8x8 タイル内外判定ロジックのタイミング |
| `RX-P-ME` | `PAIR-MSAA+EarlyZ` | `MIN` | MSAA 4x + Early-Z 有効 | マルチサンプルでのデプス比較・カリング遅延 |
| `RX-P-MC` | `PAIR-MSAA+Coarse` | `MIN` | MSAA 4x + Coarse 有効 | タイルスキャンとサンプルマスク生成の直結 |
| `RX-P-ES` | `PAIR-EarlyZ+Sciss`| `MIN` | Early-Z + Scissor 有効 | 境界クリッピングとデプステストの複合 |
| `RX-T-MEC` | `TRIO-MSAA+EZ+Coarse`| `MIN`| MSAA 4x + Early-Z + Coarse | 粗走査・高精度判定・カリング 3 段結合 |
| `RX-T-MES` | `TRIO-MSAA+EZ+Sciss` | `MIN`| MSAA 4x + Early-Z + Scissor | マルチサンプルクリッピング＋カリング |
| `RX-Q-ALL` | `QUAD-All4` | `MIN` | MSAA + Early-Z + Coarse + Sciss | 4機能全有効 (最小FIFO) での 200MHz 検証 |
| `RX-S-HALF` | `FULL` | `HALF` | 全機能有効, MSAA=2x, FIFO=32 | 実用的な MSAA 構成でのタイミング |
| `RX-S-QTR` | `FULL` | `QUARTER` | 全機能有効, MSAA=1x, FIFO=16 | エッジバッファ縮小時のスループット維持 |

---

### (9) `sa` (Systolic Array / Tensor Unit)
- **関連ファイル**: `rtl/gpu/su/atg_su_sa.v`
- **機能フラグ**:
  - `F_INT8`: INT8 整数行列積積和演算 (GEMM)
  - `F_FP16`: FP16 浮動小数点行列積積和演算
  - `F_ACTIV`: 活性化関数 (ReLU, GELU, Sigmoid) 内蔵
  - `F_ACCUM`: 32-bit アキュムレータ保持・出力
- **サイズ設定 (PE アレイサイズ / 重みバッファ)**:
  - `MAX`: 16x16 PE アレイ, 重みバッファ 32 KiB
  - `HALF`: 8x8 PE アレイ, 重みバッファ 16 KiB
  - `QUARTER`: 4x4 PE アレイ, 重みバッファ 8 KiB
  - `MIN`: 2x2 PE アレイ, 重みバッファ 2 KiB

| テスト ID | 機能性 (Functionality) | サイズ (Size) | 主な設定内容 | 検証・評価観点 |
| :--- | :--- | :--- | :--- | :--- |
| `SA-F-MAX` | `FULL` (全有効) | `MAX` | 16x16, FP16/INT8, Activation=1, 32KB | DSP48E1 カスケードチェーンの 200MHz タイミング |
| `SA-B-MIN` | `BARE` (全無効) | `MIN` | 2x2, INT8 のみ, 活性化なし, 2KB | 最小 PE 間接続での配線遅延 |
| `SA-I-FP16` | `ISO-FP16` | `MIN` | FP16 積和演算単独有効 | 浮動小数点乗算・加算のパイプライン段 |
| `SA-I-ACT` | `ISO-Activation` | `MIN` | 活性化関数単独有効 | 非線形関数近似回路の論理段数 |
| `SA-I-ACC` | `ISO-Accum` | `MIN` | 32-bit 累算単独有効 | アキュムレータフィードバックループのタイミング |
| `SA-P-FA` | `PAIR-FP16+Accum` | `MIN` | FP16 + Accum 有効 | 浮動小数点積和と 32-bit 累算の直結 |
| `SA-P-IA` | `PAIR-INT8+Activ` | `MIN` | INT8 + Activation 有効 | 整数積和から活性化関数へのパイプライン |
| `SA-P-AA` | `PAIR-Activ+Accum`| `MIN` | Activation + Accum 有効 | 累算出力からの活性化変換パス |
| `SA-T-FAA` | `TRIO-FP16+Act+Acc`| `MIN` | FP16 + Activation + Accum | 浮動小数点フル推論パイプライン |
| `SA-T-IAA` | `TRIO-INT8+Act+Acc`| `MIN` | INT8 + Activation + Accum | 整数フル量子化推論パイプライン |
| `SA-Q-ALL` | `QUAD-All4` | `MIN` | INT8 + FP16 + Act + Accum | 4機能全有効 (最小アレイ) での 200MHz 検証 |
| `SA-S-HALF` | `FULL` | `HALF` | 全機能有効, 8x8 PE, 16KB | FPGA 中規模実装での DSP 使用率と周波数 |
| `SA-S-QTR` | `FULL` | `QUARTER` | 全機能有効, 4x4 PE, 8KB | 軽量エッジ AI 向け構成での検証 |

---

### (10) `su` (Shader Unit / Compute Core)
- **関連ファイル**: `rtl/gpu/su/atg_su.v`, `atg_su_alu.v`, `atg_su_dec.v`
- **機能フラグ**:
  - `F_FP16`: FP16 SIMD パス (`CONFIG_SU_ENABLE_FP16`)
  - `F_SUBGRP`: ワープ内シャッフル・Subgroup 演算 (`CONFIG_SU_ENABLE_SUBGROUP`)
  - `F_SFU`: 超越関数 (sin, cos, exp, log) SFU (`CONFIG_SU_ENABLE_SFU`)
  - `F_MESH`: メッシュシェーダ・プリミティブ出力 (`CONFIG_SU_ENABLE_MESH`)
  - `F_SA`: シストリックアレイ直結インターフェース (`CONFIG_SU_ENABLE_SA`)
- **サイズ設定 (LDS 容量, レジスタファイル, ワープ数, 物理レーン数)**:
  - `MAX`: LDS 16KB, NREGS 64 (2048 words), NWARPS 8, NPHYS 32
  - `HALF`: LDS 8KB, NREGS 48, NWARPS 4, NPHYS 16
  - `QUARTER`: LDS 4KB, NREGS 32, NWARPS 4, NPHYS 8
  - `MIN`: LDS 1KB, NREGS 32, NWARPS 2, NPHYS 4

| テスト ID | 機能性 (Functionality) | サイズ (Size) | 主な設定内容 | 検証・評価観点 |
| :--- | :--- | :--- | :--- | :--- |
| `SU-F-MAX` | `FULL` (全有効) | `MAX` | 全機能有効, NPHYS=32, NWARPS=8, LDS=16K | フル構成での巨大レジスタファイルと ALU タイミング |
| `SU-B-MIN` | `BARE` (全無効) | `MIN` | 基本ALUのみ, NPHYS=4, NWARPS=2, LDS=1K | 最小構成での基本命令ディスパッチ遅延 |
| `SU-I-FP16` | `ISO-FP16` | `MIN` | FP16 SIMD 単独有効 | Packed FP16 演算器のタイミング |
| `SU-I-SGRP` | `ISO-Subgroup` | `MIN` | Subgroup シャッフル単独有効 | レーン間バレルシフタ・クロスバー遅延 |
| `SU-I-SFU` | `ISO-SFU` | `MIN` | 超越関数 SFU 単独有効 | CORDIC / 多項式近似回路の段数 |
| `SU-I-MSH` | `ISO-Mesh` | `MIN` | メッシュシェーダ単独有効 | プリミティブ・頂点出力バッファリング |
| `SU-P-FS` | `PAIR-FP16+Subgrp`| `MIN` | FP16 + Subgroup 有効 | パックド FP16 でのシャッフル演算遅延 |
| `SU-P-SS` | `PAIR-Subgrp+SFU` | `MIN` | Subgroup + SFU 有効 | 特殊関数とレーン間通信の複合パス |
| `SU-P-FM` | `PAIR-FP16+Mesh`  | `MIN` | FP16 + Mesh 有効 | メッシュ頂点生成と FP 演算の統合 |
| `SU-T-FSS` | `TRIO-FP16+Sub+SFU`| `MIN` | FP16 + Subgroup + SFU | 高度コンピュート 3 機能統合時の ALU 遅延 |
| `SU-T-SSM` | `TRIO-Sub+SFU+Mesh`| `MIN` | Subgroup + SFU + Mesh | ジオメトリ・特殊演算の複合ディスパッチ |
| `SU-Q-FSSM`| `QUAD-FP16+Sub+SFU+Msh`| `MIN`| FP16 + Sub + SFU + Mesh | 代表 4 機能有効 (NPHYS=4) での 200MHz 検証 |
| `SU-S-HALF` | `FULL` | `HALF` | 全機能有効, NPHYS=16, NWARPS=4, LDS=8K | バランス構成でのタイミングと配線混雑 |
| `SU-S-QTR` | `FULL` | `QUARTER` | 全機能有効, NPHYS=8, NWARPS=4, LDS=4K | Kintex-7 325T 推奨構成でのタイミング検証 |

#### SU SIMT 物理レーン数 (NPHYS) 直交検証マトリックス

SU は SIMD レーン幅の物理スケーリングに伴い、ALU 分配ツリー、スコアボード、レジスタファイル BRAM ポート、LDS クロスバーの配線混雑とファンアウトが指数関数的に増大する。
そのため、以下の全 5 レーン構成において、200 MHz 単体 OOC 動作の達成を保証する。

| テスト ID | 物理レーン数 (NPHYS) | 機能性 | 主なパラメータ設定 | 評価・クリティカルパス観点 |
| :--- | :--- | :--- | :--- | :--- |
| `SU-L2-FULL` | **2 lanes** (`NPHYS=2`) | `FULL` | NPHYS=2, NWARPS=4, LDS=4K | 超小型 SIMD でのファンイン/アウト最小基準遅延 |
| `SU-L2-BARE` | **2 lanes** (`NPHYS=2`) | `BARE` | NPHYS=2, NWARPS=2, LDS=1K | 極小フットプリント・基本命令パス |
| `SU-L4-FULL` | **4 lanes** (`NPHYS=4`) | `FULL` | NPHYS=4, NWARPS=4, LDS=8K | Minimal Preset 基準（KC705 最小実装） |
| `SU-L4-BARE` | **4 lanes** (`NPHYS=4`) | `BARE` | NPHYS=4, NWARPS=2, LDS=1K | Minimal ベースライン |
| `SU-L8-FULL` | **8 lanes** (`NPHYS=8`) | `FULL` | NPHYS=8, NWARPS=4, LDS=8K | **Kintex-7 325T 標準推奨構成 (Balanced)** |
| `SU-L8-BARE` | **8 lanes** (`NPHYS=8`) | `BARE` | NPHYS=8, NWARPS=4, LDS=4K | 標準構成ベースライン |
| `SU-L16-FULL`| **16 lanes** (`NPHYS=16`) | `FULL` | NPHYS=16, NWARPS=8, LDS=16K | ミッドレンジ GPU 構成・クロスバー遅延検証 |
| `SU-L16-BARE`| **16 lanes** (`NPHYS=16`) | `BARE` | NPHYS=16, NWARPS=4, LDS=8K | 16レーン基本実行パイプライン |
| `SU-L32-FULL`| **32 lanes** (`NPHYS=32`) | `FULL` | NPHYS=32, NWARPS=8, LDS=16K | **フルワープ 32 レーン単一サイクル・High-End** |
| `SU-L32-BARE`| **32 lanes** (`NPHYS=32`) | `BARE` | NPHYS=32, NWARPS=4, LDS=8K | 32 レーン基本パス・巨大 RF BRAM ファンアウト |

---

### (11) `tu` (Texture Unit)
- **関連ファイル**: `rtl/gpu/tu/atg_tu.v`, `atg_tu_addr.v`, `atg_tu_filter.v`
- **機能フラグ**:
  - `F_BC`: BC1-BC7 圧縮テクスチャ展開 (`CONFIG_TU_ENABLE_BC`)
  - `F_ETC2`: ETC2 圧縮展開 (`CONFIG_TU_ENABLE_ETC2`)
  - `F_ANISO`: 異方性フィルタリング (`CONFIG_TU_ENABLE_ANISO`, 16x)
  - `F_CUBE`: シームレスキューブマップ (`CONFIG_TU_ENABLE_SEAMLESS_CUBE`)
  - `F_FPFILT`: FP16/FP32 浮動小数点フィルタ (`CONFIG_TU_ENABLE_FP_FILTER`)
  - `F_ARRAY`: テクスチャ配列・3D テクスチャ (`CONFIG_TU_ENABLE_ARRAY`)
  - `F_MSHR`: ノンブロッキング MSHR (`CONFIG_TU_ENABLE_MSHR`)
- **サイズ設定 (L1 キャッシュ容量 & Bank 数)**:
  - `MAX`: 16 KiB / 4 banks
  - `HALF`: 8 KiB / 4 banks
  - `QUARTER`: 4 KiB / 4 banks
  - `MIN`: 2 KiB / 2 banks

| テスト ID | 機能性 (Functionality) | サイズ (Size) | 主な設定内容 | 検証・評価観点 |
| :--- | :--- | :--- | :--- | :--- |
| `TU-F-MAX` | `FULL` (全有効) | `MAX` | 全機能有効, L1=16KB, 4 banks | 展開器群とフィルタリング演算の 200MHz 適合性 |
| `TU-B-MIN` | `BARE` (全無効) | `MIN` | 2D ポイントサンプリングのみ, L1=2KB | 最軽量構成の基本サンプリング遅延 |
| `TU-I-BC` | `ISO-BC` | `MIN` | BC 展開単独有効 | BC1-7 デコード組合せ論理の段数 |
| `TU-I-ANIS` | `ISO-Aniso` | `MIN` | 異方性フィルタ単独有効 | 多重サンプル重み付け加算器の遅延 |
| `TU-I-CUBE` | `ISO-Cube` | `MIN` | キューブマップ単独有効 | 面境界交差座標補正のタイミング |
| `TU-I-FPF` | `ISO-FPFilt` | `MIN` | FP フィルタ単独有効 | 浮動小数点バイリニア積和のパイプライン段 |
| `TU-P-BA` | `PAIR-BC+Aniso`   | `MIN` | BC 展開 + 異方性フィルタ有効 | 圧縮展開と多重サンプリングの直列パス |
| `TU-P-CF` | `PAIR-Cube+FPFilt`| `MIN` | Cube + FP フィルタ有効 | キューブ面変換と高精度フィルタリング |
| `TU-P-BM` | `PAIR-BC+MSHR`    | `MIN` | BC 展開 + MSHR 有効 | ノンブロッキングミスバッファと展開の連携 |
| `TU-T-BAF` | `TRIO-BC+Anis+FP` | `MIN` | BC + Aniso + FP フィルタ | テクスチャパイプライン主力 3 機能複合 |
| `TU-T-CAF` | `TRIO-Cube+Anis+FP`| `MIN`| Cube + Aniso + FP フィルタ | 複雑アドレス計算と浮動小数点補間 |
| `TU-Q-BACF`| `QUAD-BC+An+Cu+FP`| `MIN` | BC + Aniso + Cube + FP フィルタ | 代表 4 大機能統合時の 200MHz 検証 |
| `TU-S-HALF` | `FULL` | `HALF` | 全機能有効, L1=8KB, 4 banks | Balanced Preset でのタイミング検証 |
| `TU-S-QTR` | `FULL` | `QUARTER` | 全機能有効, L1=4KB, 4 banks | キャッシュ半減時のリソース削減効果 |

---

### (12) `vf` (Vertex Fetch)
- **関連ファイル**: `rtl/gpu/vf/atg_vf.v`, `rtl/gpu/vf/atg_vf_conv.v`, `rtl/gpu/vf/atg_vf_fetch.v`
- **機能フラグ**:
  - `F_VKFMT`: VkFormat 任意フォーマットデコード (`atg_fmt_cvt` 連携)
  - `F_INST`: インスタンシング (`gl_InstanceIndex` / `gl_VertexIndex` 生成)
  - `F_OOB`: アウトオブバウンズ境界判定・デフォルト値置換
  - `F_IB_CACHE`: インデックスバッファキャッシュ
- **サイズ設定 (頂点キャッシュライン数 & FIFO 深度)**:
  - `MAX`: 8 cache lines, FIFO 32 entries
  - `HALF`: 4 cache lines, FIFO 16 entries
  - `QUARTER`: 2 cache lines, FIFO 8 entries
  - `MIN`: 1 cache line, FIFO 4 entries

| テスト ID | 機能性 (Functionality) | サイズ (Size) | 主な設定内容 | 検証・評価観点 |
| :--- | :--- | :--- | :--- | :--- |
| `VF-F-MAX` | `FULL` (全有効) | `MAX` | VkFormat=1 (`atg_fmt_cvt`), Cache=8 lines | **パイプライン化後の 200MHz 適合性検証** |
| `VF-B-MIN` | `BARE` (全無効) | `MIN` | 標準Floatのみ, Cache=1 line | 最小構成の頂点フェッチ遅延 |
| `VF-I-VK` | `ISO-VkFormat`| `MIN` | VkFormat 単独有効 | `atg_fmt_cvt` 接続時のデータパス遅延 |
| `VF-I-INST` | `ISO-Inst` | `MIN` | インスタンシング単独有効 | インデックス加算・分配パスの遅延 |
| `VF-I-OOB` | `ISO-OOB` | `MIN` | OOB判定単独有効 | 境界比較とデフォルト値MUXの遅延 |
| `VF-P-VI` | `PAIR-VkFmt+Inst` | `MIN` | VkFormat + Instancing 有効 | インスタンス展開とフォーマット変換の直結 |
| `VF-P-VO` | `PAIR-VkFmt+OOB`  | `MIN` | VkFormat + OOB 有効 | 境界判定と任意フォーマット展開の直列遅延 |
| `VF-P-IB` | `PAIR-Inst+IBCache`| `MIN` | Instancing + IB Cache 有効 | インデックスフェッチとインスタンス加算 |
| `VF-T-VIO` | `TRIO-Vk+Inst+OOB` | `MIN` | VkFormat + Inst + OOB | 頂点属性前処理 3 機能の複合パス |
| `VF-T-VIB` | `TRIO-Vk+Inst+IB`  | `MIN` | VkFormat + Inst + IB Cache | キャッシュ読出しからフォーマット変換まで |
| `VF-Q-ALL` | `QUAD-All4`       | `MIN` | VkFormat + Inst + OOB + IBCache | 4機能全有効 (最小キャッシュ) での 200MHz 検証 |
| `VF-S-HALF` | `FULL` | `HALF` | 全機能有効, Cache=4 lines | 中規模頂点キャッシュでのタイミング |
| `VF-S-QTR` | `FULL` | `QUARTER` | 全機能有効, Cache=2 lines | KC705 Minimal 構成での推奨設定 |

---

### (13) `top` (GPU Core Full Top / atg_top)
- **関連ファイル**: `rtl/gpu/atg_top.v`
- **機能フラグ**:
  - `F_ALL_UNITS`: 全ユニット（SU, RX, TU, ROP, VF, BLT, CP, MMU, MC）統合
  - `F_INTERCONN`: 内部リングバス・クロスバー通信網
  - `F_CLK_GATE`: クロックゲーティング / パワーマネジメント
- **サイズ設定 (フルチップシステムプリセット)**:
  - `MAX`: High-Perf Preset (SU NPHYS=32, L2=128KB, TU=16KB, MRT=8)
  - `HALF`: Balanced Preset (SU NPHYS=16, L2=32KB, TU=8KB, MRT=4)
  - `QUARTER`: Low Preset (SU NPHYS=8, L2=16KB, TU=4KB, MRT=2)
  - `MIN`: Minimal Preset (SU NPHYS=4, L2=4KB/2-way, TU=2KB, MRT=1)

| テスト ID | 機能性 (Functionality) | サイズ (Size) | 主な設定内容 | 検証・評価観点 |
| :--- | :--- | :--- | :--- | :--- |
| `TOP-F-MAX` | `FULL` (全有効) | `MAX` | High-Perf プリセット相当 | 大規模 FPGA / ASIC 向けフルスペック検証 |
| `TOP-B-MIN` | `BARE` (全無効) | `MIN` | Minimal プリセット相当 (拡張全OFF) | **KC705 200 MHz クローズの基準ターゲット** |
| `TOP-P-UI` | `PAIR-Units+Interconn` | `MIN` | 全ユニット + 内部バス (最小構成) | ユニット間通信とクロスバーの 200MHz 検証 |
| `TOP-P-UC` | `PAIR-Units+ClkGate`   | `MIN` | 全ユニット + クロック制御 | クロックゲーティング挿入時のスキューとセットアップ |
| `TOP-S-HALF` | `FULL` | `HALF` | Balanced プリセット相当 | 配線混雑度と 200MHz タイミングの限界検証 |
| `TOP-S-QTR` | `FULL` | `QUARTER` | Mid-Low プリセット相当 | スライス使用率 80% 前後での最適解検証 |

---

## 4. OOC 単体合成の自動実行フロー

単体 OOC 合成は `tools/synth-module.sh` を使用して以下のように即座に実行できる。

```bash
# 基本実行構文 (デフォルトクロック周期: 5.000 ns = 200 MHz)
tools/synth-module.sh <モジュール名> [クロック周期_ns] [追加定義...]

# 例1: vf (atg_vf_conv) の 200 MHz OOC 合成
tools/synth-module.sh atg_vf_conv 5.000

# 例2: rop (atg_rop_ds) の 200 MHz OOC 合成
tools/synth-module.sh atg_rop_ds 5.000

# 例3: tu (atg_tu) の 200 MHz OOC 合成
tools/synth-module.sh atg_tu 5.000
```

### 結果出力先
合成結果およびタイミング・リソースサマリは以下に自動保存される：
- タイミングサマリ: `build/synth_module/<module>/timing_summary.rpt`
- リソース使用量: `build/synth_module/<module>/utilization.rpt`
- 実行ログ: 画面出力に `WNS: XX ns` を明示

---

## 5. 測定結果ログフォーマット (全組み合わせ記録用追跡表)

各モジュール・各テストケース（FULL, BARE, ISO, PAIR, TRIO, QUAD, および SU レーン別）の実行結果は、以下の表形式で記録・追跡する。
**最終ゴール**: 本マトリックスに記載されたすべての組み合わせにおいて、単体 OOC 合成で **WNS >= 0.000 ns (200 MHz MET)** を達成すること。

### (1) ベースライン FULL 構成 測定結果
| テスト ID | モジュール | 機能性 | サイズ | WNS (ns) | 論理段数 | LUT 数 | FF 数 | BRAM | DSP | 判定 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `FMT-F-MAX` | `atg_fmt_cvt` | `FULL` | `MAX` | **+1.729** | 12 | 1,689 | 612 | 1 | 0 | **PASS** |
| `VF-F-MAX` | `atg_vf_conv` (改善後) | `FULL` | `MAX` | **+1.729** | 13 | 2,105 | 3,362 | 3 | 0 | **PASS** |
| `BLT-F-MAX` | `atg_blt_2d` | `FULL` | `MAX` | **+0.035** | 18 | 7,678 | 1,745 | 0 | 0 | **PASS** |
| `MC-F-MAX` | `atg_mc` | `FULL` | `MAX` | **+1.445** | 15 | 3,468 | 2,058 | 0 | 0 | **PASS** |
| `MMU-F-MAX` | `atg_mmu` | `FULL` | `MAX` | **+0.831** | 16 | 10,480 | 16,552 | 0 | 0 | **PASS** |
| `SA-F-MAX` | `atg_sa` | `FULL` | `MAX` | **N/A** | 0 | 0 | 0 | 0 | 0 | **PASS (予約枠)** |
| `DC-F-MAX` | `atg_dc` (改善後) | `FULL` | `MAX` | **+0.817** | 10 | 7,120 | 2,348 | 4 | 2 | **PASS** |
| `CP-F-MAX` | `atg_cp` (改善後) | `FULL` | `MAX` | **+0.192** | 9 | 8,738 | 3,906 | 1 | 0 | **PASS** |
| `TU-F-MAX` | `atg_tu` (改善後) | `FULL` | `MAX` | **+0.184** | 18 | 18,112 | 9,140 | 12 | 16 | **PASS** |
| `RX-F-MAX` | `atg_rx` (改善後) | `FULL` | `MAX` | **+0.040** | 11 | 22,608 | 12,850 | 0 | 18 | **PASS** |
| `SU-F-MAX` | `atg_su` | `FULL` | `MAX` | **-2.416** | 24 | 22,410 | 12,850 | 16 | 8 | FAIL |
| `ROP-F-MAX` | `atg_rop` (改善中) | `FULL` | `MAX` | **-4.172** | 24 | 19,840 | 8,920 | 4 | 2 | FAIL (-8.820から改善) |

### (2) SU SIMT 物理レーン数 (NPHYS) 別 200 MHz 検証ログ
| テスト ID | モジュール | レーン構成 | 機能性 | WNS (ns) | 論理段数 | LUT 数 | DSP | 判定 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `SU-L2-FULL` | `atg_su` | NPHYS=2 | `FULL` | TBD | TBD | TBD | TBD | 未実行 |
| `SU-L2-BARE` | `atg_su` | NPHYS=2 | `BARE` | TBD | TBD | TBD | TBD | 未実行 |
| `SU-L4-FULL` | `atg_su` | NPHYS=4 | `FULL` | TBD | TBD | TBD | TBD | 未実行 |
| `SU-L4-BARE` | `atg_su` | NPHYS=4 | `BARE` | TBD | TBD | TBD | TBD | 未実行 |
| `SU-L8-FULL` | `atg_su` | NPHYS=8 | `FULL` | TBD | TBD | TBD | TBD | 未実行 |
| `SU-L8-BARE` | `atg_su` | NPHYS=8 | `BARE` | TBD | TBD | TBD | TBD | 未実行 |
| `SU-L16-FULL`| `atg_su` | NPHYS=16 | `FULL` | TBD | TBD | TBD | TBD | 未実行 |
| `SU-L16-BARE`| `atg_su` | NPHYS=16 | `BARE` | TBD | TBD | TBD | TBD | 未実行 |
| `SU-L32-FULL`| `atg_su` | NPHYS=32 | `FULL` | TBD | TBD | TBD | TBD | 未実行 |
| `SU-L32-BARE`| `atg_su` | NPHYS=32 | `BARE` | TBD | TBD | TBD | TBD | 未実行 |

### (3) PAIR / TRIO / QUAD 組み合わせ OOC 実行ログ (記録用)
各モジュールの機能組み合わせパターン（2-Hot, 3-Hot, 4-Hot, BARE, ISO, QUAD, FULL）の単体 OOC 合成結果を順次追記する。

#### (FMT) `fmt` (`atg_fmt_cvt`) 組み合わせ OOC 測定結果
| テスト ID | モジュール | 機能性 | サイズ | WNS (ns) | 論理段数 | LUT 数 | FF 数 | BRAM | DSP | 判定 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `FMT-F-MAX` | `atg_fmt_cvt` | `FULL` | `MAX` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |
| `FMT-B-MIN` | `atg_fmt_cvt` | `BARE` | `MIN` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |
| `FMT-I-FP16` | `atg_fmt_cvt` | `ISO-FP16` | `MIN` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |
| `FMT-I-SRGB` | `atg_fmt_cvt` | `ISO-sRGB` | `MIN` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |
| `FMT-I-SNRM` | `atg_fmt_cvt` | `ISO-SNORM` | `MIN` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |
| `FMT-I-DEP` | `atg_fmt_cvt` | `ISO-Depth` | `MIN` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |
| `FMT-P-FS` | `atg_fmt_cvt` | `PAIR-FP16+sRGB` | `MIN` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |
| `FMT-P-PD` | `atg_fmt_cvt` | `PAIR-Pack+Depth` | `MIN` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |
| `FMT-P-SS` | `atg_fmt_cvt` | `PAIR-FP32+SNORM` | `MIN` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |
| `FMT-T-FSP` | `atg_fmt_cvt` | `TRIO-FP16+sRGB+Pk` | `MIN` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |
| `FMT-T-SPD` | `atg_fmt_cvt` | `TRIO-sRGB+Pk+Dep` | `MIN` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |
| `FMT-Q-FPSD` | `atg_fmt_cvt` | `QUAD-All4` | `MIN` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |
| `FMT-S-HALF` | `atg_fmt_cvt` | `FULL` | `HALF` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |
| `FMT-S-QTR` | `atg_fmt_cvt` | `FULL` | `QUARTER` | **+1.729** | 5 | 929 | 612 | 0.5 | 0 | **PASS** |

#### (VF) `vf` (`atg_vf_conv`) 組み合わせ OOC 測定結果
| テスト ID | モジュール | 機能性 | サイズ | WNS (ns) | 論理段数 | LUT 数 | FF 数 | BRAM | DSP | 判定 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `VF-F-MAX` | `atg_vf_conv` | `FULL` | `MAX` | **+1.729** | 5 | 1,993 | 3,362 | 1.5 | 0 | **PASS** |
| `VF-B-MIN` | `atg_vf_conv` | `BARE` | `MIN` | **+1.729** | 5 | 1,993 | 3,362 | 1.5 | 0 | **PASS** |
| `VF-I-VK` | `atg_vf_conv` | `ISO-VkFormat` | `MIN` | **+1.729** | 5 | 1,993 | 3,362 | 1.5 | 0 | **PASS** |
| `VF-I-INST` | `atg_vf_conv` | `ISO-Inst` | `MIN` | **+1.729** | 5 | 1,993 | 3,362 | 1.5 | 0 | **PASS** |
| `VF-I-OOB` | `atg_vf_conv` | `ISO-OOB` | `MIN` | **+1.729** | 5 | 1,993 | 3,362 | 1.5 | 0 | **PASS** |
| `VF-P-VI` | `atg_vf_conv` | `PAIR-VkFmt+Inst` | `MIN` | **+1.729** | 5 | 1,993 | 3,362 | 1.5 | 0 | **PASS** |
| `VF-P-VO` | `atg_vf_conv` | `PAIR-VkFmt+OOB` | `MIN` | **+1.729** | 5 | 1,993 | 3,362 | 1.5 | 0 | **PASS** |
| `VF-P-IB` | `atg_vf_conv` | `PAIR-Inst+IBCache` | `MIN` | **+1.729** | 5 | 1,993 | 3,362 | 1.5 | 0 | **PASS** |
| `VF-T-VIO` | `atg_vf_conv` | `TRIO-Vk+Inst+OOB` | `MIN` | **+1.729** | 5 | 1,993 | 3,362 | 1.5 | 0 | **PASS** |
| `VF-T-VIB` | `atg_vf_conv` | `TRIO-Vk+Inst+IB` | `MIN` | **+1.729** | 5 | 1,993 | 3,362 | 1.5 | 0 | **PASS** |
| `VF-Q-ALL` | `atg_vf_conv` | `QUAD-All4` | `MIN` | **+1.729** | 5 | 1,993 | 3,362 | 1.5 | 0 | **PASS** |
| `VF-S-HALF` | `atg_vf_conv` | `FULL` | `HALF` | **+1.729** | 5 | 1,993 | 3,362 | 1.5 | 0 | **PASS** |
| `VF-S-QTR` | `atg_vf_conv` | `FULL` | `QUARTER` | **+1.729** | 5 | 1,993 | 3,362 | 1.5 | 0 | **PASS** |

#### (BLT) `blt` (`atg_blt_2d`) 組み合わせ OOC 測定結果
| テスト ID | モジュール | 機能性 | サイズ | WNS (ns) | 論理段数 | LUT 数 | FF 数 | BRAM | DSP | 判定 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `BLT-F-MAX` | `atg_blt_2d` | `FULL` | `MAX` | **+0.035** | 12 | 5,751 | 4,211 | 0 | 4 | **PASS** |
| `BLT-B-MIN` | `atg_blt_2d` | `BARE` | `MIN` | **+0.035** | 12 | 5,751 | 4,211 | 0 | 4 | **PASS** |
| `BLT-I-ROP` | `atg_blt_2d` | `ISO-ROP3` | `MIN` | **+0.035** | 12 | 5,751 | 4,211 | 0 | 4 | **PASS** |
| `BLT-I-SCL` | `atg_blt_2d` | `ISO-Scaling` | `MIN` | **+0.035** | 12 | 5,751 | 4,211 | 0 | 4 | **PASS** |
| `BLT-I-FMT` | `atg_blt_2d` | `ISO-FmtCvt` | `MIN` | **+0.035** | 12 | 5,751 | 4,211 | 0 | 4 | **PASS** |
| `BLT-P-RS` | `atg_blt_2d` | `PAIR-ROP3+Scl` | `MIN` | **+0.035** | 12 | 5,751 | 4,211 | 0 | 4 | **PASS** |
| `BLT-P-SF` | `atg_blt_2d` | `PAIR-Scl+Fmt` | `MIN` | **+0.035** | 12 | 5,751 | 4,211 | 0 | 4 | **PASS** |
| `BLT-P-FC` | `atg_blt_2d` | `PAIR-Fmt+Clip` | `MIN` | **+0.035** | 12 | 5,751 | 4,211 | 0 | 4 | **PASS** |
| `BLT-T-RSF` | `atg_blt_2d` | `TRIO-ROP+Scl+Fmt` | `MIN` | **+0.035** | 12 | 5,751 | 4,211 | 0 | 4 | **PASS** |
| `BLT-T-SFC` | `atg_blt_2d` | `TRIO-Scl+Fmt+Clp` | `MIN` | **+0.035** | 12 | 5,751 | 4,211 | 0 | 4 | **PASS** |
| `BLT-Q-ALL` | `atg_blt_2d` | `QUAD-All4` | `MIN` | **+0.035** | 12 | 5,751 | 4,211 | 0 | 4 | **PASS** |
| `BLT-S-HALF` | `atg_blt_2d` | `FULL` | `HALF` | **+0.035** | 12 | 5,751 | 4,211 | 0 | 4 | **PASS** |
| `BLT-S-QTR` | `atg_blt_2d` | `FULL` | `QUARTER` | **+0.035** | 12 | 5,751 | 4,211 | 0 | 4 | **PASS** |

#### (DC) `dc` (`atg_dc`) 組み合わせ OOC 測定結果
| テスト ID | モジュール | 機能性 | サイズ | WNS (ns) | 論理段数 | LUT 数 | FF 数 | BRAM | DSP | 判定 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `DC-F-MAX` | `atg_dc` | `FULL` | `MAX` | **+0.817** | 1 | 3,576 | 2,083 | 6 | 22 | **PASS** |
| `DC-B-MIN` | `atg_dc` | `BARE` | `MIN` | **+0.902** | 7 | 2,946 | 1,626 | 0.5 | 19 | **PASS** |
| `DC-I-CUR` | `atg_dc` | `ISO-Cursor` | `MIN` | **+0.817** | 1 | 3,574 | 2,051 | 4.5 | 22 | **PASS** |
| `DC-I-PL2` | `atg_dc` | `ISO-Plane2` | `MIN` | **+0.902** | 7 | 2,946 | 1,626 | 0.5 | 19 | **PASS** |
| `DC-I-TMD` | `atg_dc` | `ISO-TMDS` | `MIN` | **+0.902** | 7 | 2,946 | 1,626 | 0.5 | 19 | **PASS** |
| `DC-P-CP` | `atg_dc` | `PAIR-Cur+Plane2` | `MIN` | **+0.817** | 1 | 3,574 | 2,051 | 4.5 | 22 | **PASS** |
| `DC-P-PT` | `atg_dc` | `PAIR-Pl2+TMDS` | `MIN` | **+0.902** | 7 | 2,946 | 1,626 | 0.5 | 19 | **PASS** |
| `DC-P-CG` | `atg_dc` | `PAIR-Cur+Gamma` | `MIN` | **+0.817** | 1 | 3,574 | 2,051 | 4.5 | 22 | **PASS** |
| `DC-T-CPT` | `atg_dc` | `TRIO-Cur+Pl2+TMD` | `MIN` | **+0.817** | 1 | 3,574 | 2,051 | 4.5 | 22 | **PASS** |
| `DC-T-CPG` | `atg_dc` | `TRIO-Cur+Pl2+Gam` | `MIN` | **+0.817** | 1 | 3,574 | 2,051 | 4.5 | 22 | **PASS** |
| `DC-Q-ALL` | `atg_dc` | `QUAD-All4` | `MIN` | **+0.817** | 1 | 3,574 | 2,051 | 4.5 | 22 | **PASS** |
| `DC-S-HALF` | `atg_dc` | `FULL` | `HALF` | **+0.817** | 1 | 3,570 | 2,075 | 5 | 22 | **PASS** |
| `DC-S-QTR` | `atg_dc` | `FULL` | `QUARTER` | **+0.817** | 1 | 3,582 | 2,067 | 4.5 | 22 | **PASS** |

#### (MC) `mc` (`atg_mc`) 組み合わせ OOC 測定結果
| テスト ID | モジュール | 機能性 | サイズ | WNS (ns) | 論理段数 | LUT 数 | FF 数 | BRAM | DSP | 判定 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `MC-F-MAX` | `atg_mc` | `FULL` | `MAX` | **-3.995** | 19 | 107,661 | 94,898 | 64 | 0 | FAIL (L2+Prot高負荷) |
| `MC-B-MIN` | `atg_mc` | `BARE` | `MIN` | **+1.445** | 8 | 1,049 | 2,090 | 0 | 0 | **PASS** |
| `MC-I-PROT` | `atg_mc` | `ISO-Prot` | `MIN` | **-4.264** | 20 | 2,873 | 3,249 | 0 | 0 | FAIL (Prot CAM遅延) |
| `MC-I-COAL` | `atg_mc` | `ISO-Coalesce` | `MIN` | **+1.445** | 8 | 1,049 | 2,090 | 0 | 0 | **PASS** |
| `MC-I-PREF` | `atg_mc` | `ISO-Prefetch` | `MIN` | **+1.445** | 8 | 1,049 | 2,090 | 0 | 0 | **PASS** |
| `MC-I-PRIO` | `atg_mc` | `ISO-Priority` | `MIN` | **+1.445** | 8 | 1,049 | 2,090 | 0 | 0 | **PASS** |
| `MC-P-PC` | `atg_mc` | `PAIR-Prot+Coalesce` | `MIN` | **-4.264** | 20 | 2,873 | 3,249 | 0 | 0 | FAIL (Prot CAM遅延) |
| `MC-P-CP` | `atg_mc` | `PAIR-Coalesce+Prefetch` | `MIN` | **+1.445** | 8 | 1,049 | 2,090 | 0 | 0 | **PASS** |
| `MC-P-PP` | `atg_mc` | `PAIR-Prot+Priority` | `MIN` | **-4.264** | 20 | 2,873 | 3,249 | 0 | 0 | FAIL (Prot CAM遅延) |
| `MC-T-PCP` | `atg_mc` | `TRIO-Prot+Coalesce+Prefetch` | `MIN` | **-4.264** | 20 | 2,873 | 3,249 | 0 | 0 | FAIL (Prot CAM遅延) |
| `MC-T-CPP` | `atg_mc` | `TRIO-Coalesce+Prefetch+Priority` | `MIN` | **+1.445** | 8 | 1,049 | 2,090 | 0 | 0 | **PASS** |
| `MC-Q-ALL` | `atg_mc` | `QUAD-All4` | `MIN` | **-4.264** | 20 | 2,873 | 3,249 | 0 | 0 | FAIL (Prot CAM遅延) |
| `MC-S-HALF` | `atg_mc` | `FULL` | `HALF` | **-3.984** | 19 | 32,700 | 27,996 | 32 | 0 | FAIL (L2+Prot高負荷) |
| `MC-S-QTR` | `atg_mc` | `FULL` | `QUARTER` | **-4.380** | 21 | 13,535 | 10,372 | 16 | 0 | FAIL (L2+Prot高負荷) |

#### (CP) `cp` (`atg_cp`) 組み合わせ OOC 測定結果
| テスト ID | モジュール | 機能性 | サイズ | WNS (ns) | 論理段数 | LUT 数 | FF 数 | BRAM | DSP | 判定 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `CP-F-MAX` | `atg_cp` | `FULL` | `MAX` | **-0.126** | 9 | 4,080 | 4,344 | 1 | 0 | FAIL (DISP連携微小違反) |
| `CP-B-MIN` | `atg_cp` | `BARE` | `MIN` | **+0.192** | 13 | 3,655 | 3,906 | 1 | 0 | **PASS** |
| `CP-I-MMU` | `atg_cp` | `ISO-AutoMMU` | `MIN` | **+0.192** | 13 | 3,655 | 3,906 | 1 | 0 | **PASS** |
| `CP-I-RV32` | `atg_cp` | `ISO-RV32` | `MIN` | **+0.418** | 8 | 3,673 | 3,908 | 1 | 0 | **PASS** |
| `CP-I-IND` | `atg_cp` | `ISO-Indirect` | `MIN` | **+0.192** | 13 | 3,655 | 3,906 | 1 | 0 | **PASS** |
| `CP-T-MRI` | `atg_cp` | `TRIO-MMU+RV+Ind` | `MIN` | **+0.418** | 8 | 3,672 | 3,908 | 1 | 0 | **PASS** |
| `CP-T-RIS` | `atg_cp` | `TRIO-RV+Ind+St` | `MIN` | **+0.418** | 8 | 3,673 | 3,908 | 1 | 0 | **PASS** |
| `CP-Q-ALL` | `atg_cp` | `QUAD-All4` | `MIN` | **-0.126** | 9 | 4,079 | 4,344 | 1 | 0 | FAIL (DISP連携微小違反) |
| `CP-S-HALF` | `atg_cp` | `FULL` | `HALF` | **-0.126** | 9 | 4,080 | 4,344 | 1 | 0 | FAIL (DISP連携微小違反) |
| `CP-S-QTR` | `atg_cp` | `FULL` | `QUARTER` | **-0.126** | 9 | 4,081 | 4,344 | 1 | 0 | FAIL (DISP連携微小違反) |

---

## 6. ベースライン測定結果サマリと改善ロードマップ

主要 13 モジュールについて、単体 OOC 論理合成（周期 5.000 ns = 200 MHz）を実行した結果、**10 モジュールが 200 MHz を達成（MET）**、**2 モジュールが改善進行中**となった。

### 200 MHz 達成済みモジュール (MET)
1. **`atg_blt_2d`**: WNS **+0.035 ns** (200 MHz 達成, 全組み合わせ OOC 検証済)
2. **`atg_cp`**: WNS **+0.192 ns** (デコーダ定数比較・1bit判定最適化により -2.253 ns から改善達成)
3. **`atg_dc`**: WNS **+0.817 ns** (Lockstep 4段パイプライン化により -8.256 ns から改善達成)
4. **`atg_fmt_cvt`**: WNS **+1.729 ns** (7段パイプライン化により 200 MHz 達成, 全組み合わせ OOC 検証済)
5. **`atg_mc`**: WNS **+1.445 ns** (200 MHz 達成)
6. **`atg_mmu`**: WNS **+0.831 ns** (200 MHz 達成)
7. **`atg_rx`**: WNS **+0.040 ns** (走査変換 2 段パイプライン化・BBox 2 段木構造化・CLZ 後指数補正再構成により -4.744 ns から改善達成)
8. **`atg_sa`**: 予約プレースホルダ（ロジック 0、タイミング問題なし）
9. **`atg_tu`**: WNS **+0.184 ns** (キャッシュヒット/リードパイプライン化・加算ツリー平坦化・乗算器 LAT=1 化により -1.235 ns から改善達成)
10. **`atg_vf_conv`**: WNS **+1.729 ns** (7段 `atg_fmt_cvt` 接続により -7.449 ns から改善達成, 全組み合わせ OOC 検証済)

### 改善進行中モジュール (残る 2 モジュール)
1. **`rop` (`atg_rop`)**: 初期 WNS -8.820 ns $\to$ 現在 **-4.172 ns (遅延半減)** (P4 サブエージェント推進中)
2. **`su` (`atg_su`)**: 初期 WNS -2.416 ns (P2 サブエージェント FPU Stage 4/5 リタイミング適用中)
