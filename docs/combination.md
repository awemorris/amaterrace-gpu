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

各モジュールについて、以下の 2 軸（直交組み合わせ）を交差させてテストケースを定義する。

### 軸 A: 機能性 (Functionality)
1. **`FULL`**: コンフィグで**すべての機能を有効**
2. **`BARE`**: コンフィグで**すべての拡張機能を無効**（ベースライン動作のみ）
3. **`ISO-<Feature>`**: コンフィグで**1つずつの機能を単独有効化**（機能単位のクリティカルパスおよび面積インパクトを単離）

### 軸 B: サイズ / キャッシュ容量 (Size & Capacity)
1. **`MAX`**: 最大構成（High-Performance Preset 相当）
2. **`HALF`**: 1/2 構成（Balanced Preset 相当）
3. **`QUARTER`**: 1/4 構成（Mid-Low 構成）
4. **`MIN`**: 最小構成（Minimal Preset 相当）

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
| `SU-S-HALF` | `FULL` | `HALF` | 全機能有効, NPHYS=16, NWARPS=4, LDS=8K | バランス構成でのタイミングと配線混雑 |
| `SU-S-QTR` | `FULL` | `QUARTER` | 全機能有効, NPHYS=8, NWARPS=4, LDS=4K | Kintex-7 325T 推奨構成でのタイミング検証 |

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

## 5. 測定結果ログフォーマット (記録用テンプレート)

各モジュール・各テストケースの実行結果は、以下の表形式で記録・追跡する。

| テスト ID | モジュール | 機能性 | サイズ | WNS (ns) | 論理段数 | LUT 数 | FF 数 | BRAM | DSP | 判定 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `FMT-F-MAX` | `atg_fmt_cvt` | `FULL` | `MAX` | **+1.729** | 12 | 1,689 | 612 | 1 | 0 | **PASS** |
| `VF-B-MIN` | `atg_vf_conv` (現状) | `BARE` | `MIN` | **-7.449** | 34 | 2,595 | 5,295 | 1 | 0 | FAIL |
| `ROP-B-MIN` | `atg_rop_ds` (現状) | `BARE` | `MIN` | **-7.847** | 36 | 2,447 | 1,967 | 4 | 2 | FAIL |
| `ROP-B-WB` | `atg_rop_wb` (現状) | `BARE` | `MIN` | **-8.223** | 38 | 7,463 | 1,840 | 0 | 2 | FAIL |
| ... | ... | ... | ... | ... | ... | ... | ... | ... | ... | ... |
