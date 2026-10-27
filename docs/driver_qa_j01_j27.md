# Amaterrace GPU GHCI 1.0 ドライバ実装 QA 回答書（J01〜J27 確定仕様）

- **文書種別**: ハードウェア・ソフトウェア協調仕様確定書（Authoritative Hardware/Software Architecture Specification）
- **対象読者**: Linux カーネルドライバ（KMD: `amaterrace.ko`）開発者、Vulkan 1.0 ユーザ空間ドライバ（ICD / Mesa）開発者
- **策定日**: 2026-10-27
- **対象バージョン**: GHCI Version 1.0 (`GHCI_VERSION_VALUE = 0x00010000`)
- **ステータス**: 承認済み確定仕様（Approved Architecture）

---

## 目次

1. [J01: Slim MMIO アーキテクチャと旧 1.1 仕様の完全廃止](#j01)
2. [J02: CTRL, STATUS, IRQ_STATUS レジスタの確定ビット割当](#j02)
3. [J03: FAULT_INFO レジスタの確定レイアウトとシンドローム](#j03)
4. [J04: GHCI 1.0 ホスト MMIO レジスタ全表 (0x000〜0x084)](#j04)
5. [J05: コマンドリングバッファの単位・整列・境界規則](#j05)
6. [J06: CAPS / CAPS2 の整理と高速参照ショートカット](#j06)
7. [J07: セッション上限と CMD_BIND_SESSION のハードウェア振る舞い](#j07)
8. [J08: DEVICE_CAPS レジスタ全 32 ビット確定割当](#j08)
9. [J09: EXTCAP 拡張機能ブロックのベースオフセットと Vulkan ID](#j09)
10. [J10: 可変アドレス空間アーキテクチャ (GPU VA 30〜40bit / Host PA 40〜48bit)](#j10)
11. [J11: 64-bit 標準ページテーブルエントリ (PTE) フォーマット](#j11)
12. [J12: ページディレクトリ管理と MMU Out-Of-Memory リカバリ](#j12)
13. [J13: CMD_FENCE (0x33) 確定バイナリレイアウト](#j13)
14. [J14: CMD_DRAW_INDIRECT (0x29) 確定バイナリレイアウト](#j14)
15. [J15: 128 バイトパイプラインステートオブジェクト (GhciPipelineState)](#j15)
16. [J16: レンダーパスアタッチメント仕様と LoadOp/StoreOp エンコード](#j16)
17. [J17: リソースディスクリプタ構造と Combined Image Sampler 実装](#j17)
18. [J18: 新規構造化コマンドの完全バイナリ仕様](#j18)
19. [J19: Vulkan 1.0 物理デバイスリミット一覧 (§8.6)](#j19)
20. [J20: ハードウェアテクスチャ形式と VkFormat 対応表](#j20)
21. [J21: コマンドプロセッサフォールト検出とリングリセット手順](#j21)
22. [J22: キャッシュ整合性とパイプラインバリア (CMD_BARRIER)](#j22)
23. [J23: 画面表示同期 (CMD_FLIP / VBLANK) と W1C 割り込み制御](#j23)
24. [J24: GSI1 シェーダ ISA および機能ビットマップ](#j24)
25. [J25: フラット物理アドレスモードとセカンダリリングの実行規則](#j25)
26. [J26: CPU 書込み・GPU 読出し時のキャッシュコヒーレンシ手順](#j26)
27. [J27: IOMMU 有効環境および Passthrough 環境におけるドライバ動作要件](#j27)
28. [K01: 正当仕様書と同期時期（ghci.md 一本化）](#k01)
29. [K02: Page 0 レジスタ全表の確定 & CP_HEAP / WDT / WARPS / GCLK_HZ](#k02)
30. [K03: STATUS / CTRL / CP_STATE / セッション vs 全体 FAULTED 挙動](#k03)
31. [K04: FAULT_INFO レジスタレイアウトと kind 番号定義](#k04)
32. [K05: DEVICE_CAPS レジスタ全 32 ビット確定割当（新機能追加）](#k05)
33. [K06: GCLK_HZ / timestampPeriod / PCI Vendor ID / Device ID 確定値](#k06)
34. [K07: VA / PA アドレス幅レジスタ & 2段/3段ページテーブル構成](#k07)
35. [K08: MMU_OOM エラー復旧とハードウェアリセット後の状態](#k08)
36. [K09: CMD_FENCE (6 dw) & CMD_WAIT_FENCE (5 dw) 符号付き比較](#k09)
37. [K10: CMD_DRAW_INDIRECT (7 dw / 8 dw カウントバッファ対応)](#k10)
38. [K11: 128 バイト PSO 内 16 頂点属性の高密度パッキングレイアウト](#k11)
39. [K12: CMD_BEGIN_RENDER_PASS (10 dw) と GhciRenderPassDesc (64B)](#k12)
40. [K13: Combined Image Sampler 確定仕様（Option A: 32-bit インデックスペア）](#k13)
41. [K14: 全 15 コマンド確定 dword ペイロードレイアウト一覧](#k14)
42. [K15: Vulkan 1.0 必須制限値・物理デバイスリミット・47 必須フォーマット](#k15)
43. [K16: セカンダリコマンドバッファの呼び出し階層（厳格 1 階層制限）](#k16)
44. [K17: CMD_BARRIER (4 dw) パイプラインステージ・フラグ詳細定義](#k17)
45. [K18: GSI1 シェーダ ISA 機能ビットと MMIO 読み出しレジスタ](#k18)
46. [K19: RING_SIZE バイト数定義とリングバッファ折り返し規則](#k19)

---

<a id="j01"></a>
## J01: Slim MMIO アーキテクチャと旧 1.1 仕様の完全廃止

### 質問要約
旧ドラフトや過去のコードに存在した「GHCI 1.1」および「0x1000 番台の STATE_* MMIO レジスタ」の扱いはどうなるか。また BAR0 のサイズと内部ページ構成はどうなっているか。

### 確定回答
1. **GHCI 1.0 への完全一本化**:
   - 仕様は **GHCI Version 1.0 (`0x00010000`)** に厳格に一本化されました。
   - 旧 GHCI 1.1 記述、ファームウェア依存の旧 INIT ハンドシェイク、および 0x1000〜0x1FFF に配置されていた `STATE_*` レジスタ窓（旧 1.1 MMIO エイリアス）は**完全に廃止・削除**されました。
2. **BAR0 アパーチャサイズ**:
   - PCIe BAR0 は **128 KiB** です（Kintex-7 KC705 PCIe IP エンドポイント設定および `atg_kc705_pcie.v` 整合）。
3. **Slim MMIO ページ 0 構成**:
   - BAR0 先頭 4 KiB（ページ 0: `0x000`〜`0x0FC`）がホスト制御用 MMIO レジスタ領域です。
   - アクティブなホスト制御レジスタは**厳密に 19 本（76 バイト: `0x000`〜`0x048`）**のみで構成されます。
   - 描画パイプラインステート（PSO）の設定に MMIO レジスタへの連続書込み（PIO）は一切使用しません。すべて共有メモリ上の 128 バイト不変オブジェクト（`GhciPipelineState`）およびリングバッファコマンドによって投入されます。これによりバスストールおよびカーネル・ユーザ空間遷移オーバーヘッドをゼロにします。
4. **拡張機能およびアパーチャ**:
   - `0x100`〜`0x3FF`: 拡張機能（EXTCAP）リンクリストおよび機能ブロック。
   - `0x400` 以降: 各種アクセラレータ窓・デバッグポート・ローカルフレームバッファ直結窓。

---

<a id="j02"></a>
## J02: CTRL, STATUS, IRQ_STATUS レジスタの確定ビット割当

### 質問要約
ヘッダ間で `GHCI_CTRL`、`GHCI_STATUS`、`GHCI_IRQ_STATUS` のビット定義が競合・重複していた。確定ビットマップはどれか。

### 確定回答
`include/ghci_regs.h` および `include/ghci_regs.vh` において以下のとおり一意に確定しました。マクロの再定義や重複は完全に解消されています。

#### 1. `GHCI_REG_CTRL` (`0x014`, RW, リセット値: `0x00000000`)
| ビット | 名前 | 説明 |
|:---:|:---|:---|
| `0` | `GHCI_CTRL_RESET` | 1 を書くと CP およびコアロジックをリセット。0 で解除 |
| `1` | `GHCI_CTRL_RUN` | 1 を書くとリングバッファのフェッチ・実行を開始 |
| `2` | `GHCI_CTRL_HALT` | 1 を書くと現在のパケット完了後に一時停止 |
| `3` | `GHCI_CTRL_STEP` | 1 を書くと 1 パケットのみ実行して自動停止 |
| `4` | `GHCI_CTRL_TLB_FLUSH`| 1 を書くと CP 内部の L1/L2 TLB 全エントリを無効化 |
| `5` | `GHCI_CTRL_WDT_EN` | 1 でハードウェアウォッチドッグタイマを有効化 |
| `6` | `GHCI_CTRL_IRQ_GLOBAL`| 1 で GPU 全体のマスター割り込み出力を許可 |
| `31:7` | Reserved | 常に 0 を書き込み |

#### 2. `GHCI_REG_STATUS` (`0x010`, RO, リセット値: `0x00000902`)
| ビット | 名前 | 説明 |
|:---:|:---|:---|
| `0` | `GHCI_STATUS_RUNNING` | 1 = CP 実行中（RUN 状態） |
| `1` | `GHCI_STATUS_HALTED` | 1 = CP 停止中（HALT 状態） |
| `2` | `GHCI_STATUS_FAULTED` | 1 = CP またはパイプラインでフォールト発生 |
| `8` | `GHCI_STATUS_MC_IDLE` | 1 = メモリコントローラ・外部メモリバスがアイドル |
| `11` | `GHCI_STATUS_RING_EMPTY`| 1 = リングバッファ未処理コマンドなし（WPTR == RPTR） |
| `12` | `GHCI_STATUS_MEM_READY`| 1 = DDR3 / AXI メモリインターフェース初期化完了 |
| `13` | `GHCI_STATUS_AXI_STUCK`| 1 = AXI バス応答タイムアウト検知 |
| `14` | `GHCI_STATUS_QUIESCE` | 1 = 全実行ユニット（VF, SU, RX, TU, ROP, BLT）が完全停止 |
| `19:16`| `GHCI_STATUS_CP_STATE` | CP ステートマシン状態コード（下表参照） |

**CP ステートマシンコード (`GHCI_STATUS[19:16]`)**:
- `0`: `GHCI_CP_STATE_IDLE` — アイドル待機
- `1`: `GHCI_CP_STATE_FETCH` — リングコマンドフェッチ中
- `2`: `GHCI_CP_STATE_DECODE` — コマンドデコード中
- `3`: `GHCI_CP_STATE_DISPATCH` — 各実行ユニットへディスパッチ中
- `4`: `GHCI_CP_STATE_WAIT_UNIT` — 実行ユニット完了待ち
- `5`: `GHCI_CP_STATE_WAIT_FENCE` — `CMD_WAIT_FENCE` 同期待ち
- `6`: `GHCI_CP_STATE_FAULT` — フォールト停止中
- `7`: `GHCI_CP_STATE_HALT` — ソフトウェア一時停止中

#### 3. `GHCI_REG_IRQ_STATUS` (`0x038`, RW1C) / `ENABLE` (`0x03C`, RW) / `SET` (`0x040`, WO)
| ビット | 名前 | 説明 |
|:---:|:---|:---|
| `0` | `GHCI_IRQ_FENCE` | `CMD_FENCE` 完了通知（DMA 書込み完了後） |
| `1` | `GHCI_IRQ_ERROR` | パイプラインまたは MMU フォールト検知 |
| `2` | `GHCI_IRQ_WATCHDOG` | コマンド実行時間上限超過（ハングアップ検知） |
| `3` | `GHCI_IRQ_DISP` | ディスプレイコントローライベント |
| `4` | `GHCI_IRQ_DBG_DONE` | ハードウェアトレース / デバッグ完了 |
| `5` | `GHCI_IRQ_SOFT` | `GHCI_REG_IRQ_SET` によるソフトウェア手動割り込み |
| `6` | `GHCI_IRQ_HALTED` | CP が HALT 状態へ遷移完了 |
| `7` | `GHCI_IRQ_RESULT` | レガシー応答パケット生成完了 |
| `8` | `GHCI_IRQ_RETIRE` | コマンドバッファリタイア完了 |
| `9` | `GHCI_IRQ_VBLANK` | ディスプレイ垂直帰線区間（VSYNC 開始） |
| `10` | `GHCI_IRQ_FLIP` | フレームバッファスワップ（Scanout Flip）完了 |
| `11` | `GHCI_IRQ_DISP_ERROR`| 表示 FIFO アンダラン検知 |
| `12` | `GHCI_IRQ_HOTPLUG` | ディスプレイケーブル接続・切断検知 |

---

<a id="j03"></a>
## J03: FAULT_INFO レジスタの確定レイアウトとシンドローム

### 質問要約
フォールト発生時にドライバが原因を特定するための `GHCI_REG_FAULT_INFO`（`0x018`）のビットフィールド詳細と、各ユニット・種類の列挙値は何か。

### 確定回答
`GHCI_REG_FAULT_INFO` は 32 ビット幅で構成され、フォールト種別、発生ユニット、セッション ID、および詳細シンドロームを格納します。

```
 31                            16 15            8 7        4 3        0
+--------------------------------+---------------+----------+----------+
|            SYNDROME            |   SESSION_ID  |   UNIT   |   KIND   |
+--------------------------------+---------------+----------+----------+
```

1. **`[3:0] KIND` (フォールト種別)**:
   - `0`: `GHCI_FAULT_KIND_NONE` — フォールトなし
   - `1`: `GHCI_FAULT_KIND_INVALID_OP` — 未定義または無効なコマンドオペコード
   - `2`: `GHCI_FAULT_KIND_KICK_ABSENT` — 不在ユニットへのキック
   - `3`: `GHCI_FAULT_KIND_BAD_REG` — パケット長不正、ヘッダ不正、または不正なレジスタアクセス
   - `4`: `GHCI_FAULT_KIND_TIMEOUT` — ウォッチドッグタイマ満了（ハング検知）
   - `5`: `GHCI_FAULT_KIND_FENCE_ERROR` — メモリ・フェンス応答エラー
   - `6`: `GHCI_FAULT_KIND_PROT_FAULT` — セッション保護違反
   - `7`: `GHCI_FAULT_KIND_LOCKED_REG` — ロック中レジスタへの書込み
   - `8`: `GHCI_FAULT_KIND_MMU_OOM` — 2段目ページテーブル動的確保ヒープ枯渇
   - `9`: `GHCI_FAULT_KIND_PAGE_FAULT` — 未マップページアクセス
   - `10`: `GHCI_FAULT_KIND_PERM_FAULT` — メモリアクセス権限違反
2. **`[7:4] UNIT` (フォールト発生ハードウェアユニット)**:
   - `0`: `GHCI_UNIT_CP` — コマンドプロセッサ
   - `1`: `GHCI_UNIT_VF` — 頂点フェッチャ (Vertex Fetcher)
   - `2`: `GHCI_UNIT_SU` — シェーダユニット (Shader Unit)
   - `3`: `GHCI_UNIT_RX` — ラスタライザ (Rasterizer)
   - `4`: `GHCI_UNIT_TU` — テクスチャユニット (Texture Unit)
   - `5`: `GHCI_UNIT_ROP` — レンダーバックエンド (Render Output)
   - `6`: `GHCI_UNIT_BLT` — ブリッター (2D/3D DMA Engine)
3. **`[15:8] SESSION_ID`**:
   - フォールト発生時にアクティブだったクライアントセッション番号（0〜15）。
4. **`[31:16] SYNDROME` (ユニット固有シンドローム)**:
   - ページフォールト時（`KIND=3`）:
     - `bit 16`: `0` = 読出しアクセス, `1` = 書込みアクセス
     - `bit 17`: `1` = 命令実行アクセス（Executable 違反）
     - `bit 18`: `1` = ユーザモードアクセス違反
   - 不正オペコード時（`KIND=1`）:
     - `[23:16]`: デコードに失敗したオペコード値
   - AXI エラー時（`KIND=9`）:
     - `[17:16]`: AXI `RRESP` / `BRESP` レスポンスコード（`2'b10` = SLVERR, `2'b11` = DECERR）

> [!NOTE]
> フォールト発生時の 64 ビット仮想アドレスは、隣接する `GHCI_REG_FAULT_ADDR` (`0x01C`) および `GHCI_REG_FAULT_ADDR_HI` (`0x020`) から読み出すことができます。

---

<a id="j04"></a>
## J04: GHCI 1.0 ホスト MMIO レジスタ全表 (0x000〜0x084)

### 質問要約
Page 0（0x000〜0x0FC）内に存在する全ホスト MMIO レジスタの確定オフセット、アクセス属性、リセット値の公式一覧を提示してほしい。

### 確定回答

| オフセット | レジスタ名 | 属性 | リセット値 | 説明 |
|:---:|:---|:---:|:---:|:---|
| `0x000` | `GHCI_REG_MAGIC` | RO | `0x47484349` | Magic FourCC ASCII ("GHCI") |
| `0x004` | `GHCI_REG_VERSION` | RO | `0x00010000` | バージョン 1.0 (`[31:16]=1`, `[15:0]=0`) |
| `0x008` | `GHCI_REG_DEVICE_CAPS` | RO | コンフィグ依存 | ハードウェア基本機能ビットマップ (J08 参照) |
| `0x00C` | `GHCI_REG_EXTCAP_PTR` | RO | `0x00000100` | 最初の EXTCAP 構造体オフセット (0x100) |
| `0x010` | `GHCI_REG_STATUS` | RO | `0x00000902` | CP およびメモリコントローラ稼働状態 (J02 参照) |
| `0x014` | `GHCI_REG_CTRL` | RW | `0x00000000` | コア制御 (RESET, RUN, HALT, STEP, FLUSH) |
| `0x018` | `GHCI_REG_FAULT_INFO` | RO | `0x00000000` | フォールト種別、ユニット、セッション、シンドローム |
| `0x01C` | `GHCI_REG_FAULT_ADDR` | RO | `0x00000000` | フォールト仮想アドレス下位 32 ビット |
| `0x020` | `GHCI_REG_FAULT_ADDR_HI` | RO | `0x00000000` | フォールト仮想アドレス上位 32 ビット |
| `0x024` | `GHCI_REG_RING_BASE_LO` | RW | `0x00000000` | コマンドリングホスト物理アドレス下位 [31:0] (64B 整列) |
| `0x028` | `GHCI_REG_RING_BASE_HI` | RW | `0x00000000` | コマンドリングホスト物理アドレス上位 [63:32] |
| `0x02C` | `GHCI_REG_RING_SIZE` | RW | `0x00000000` | リングバッファ容量（バイト数, 4 KiB〜16 MiB 2の冪） |
| `0x030` | `GHCI_REG_RING_WPTR` | RW | `0x00000000` | ホスト書込みドアベルポインタ（**dword インデックス**） |
| `0x034` | `GHCI_REG_RING_RPTR` | RO | `0x00000000` | GPU 読出し進捗ポインタ（**dword インデックス**） |
| `0x038` | `GHCI_REG_IRQ_STATUS` | RW1C | `0x00000000` | 割り込みステータス (1 を書くことでビットクリア) |
| `0x03C` | `GHCI_REG_IRQ_ENABLE` | RW | `0x00000000` | 割り込みイネーブルマスク |
| `0x040` | `GHCI_REG_IRQ_SET` | WO | `0x00000000` | ソフトウェア割り込み強制トリガビット |
| `0x044` | `GHCI_REG_SCRATCH0` | RW | `0x00000000` | ドライバ汎用スクラッチレジスタ 0 |
| `0x048` | `GHCI_REG_SCRATCH1` | RW | `0x00000000` | ドライバ汎用スクラッチレジスタ 1 |
| `0x04C`〜`0x07C` | Reserved | RO | `0x00000000` | 将来拡張用予約領域（読出しは 0 返却） |
| `0x080` | `GHCI_REG_EXT_CAP_HEADER`| RO | `0x00010180` | 高速参照用: FMT0 機能ヘッダ (次ポインタ 0x180) |
| `0x084` | `GHCI_REG_EXT_CAP_FEATURE`| RO | コンフィグ依存 | 高速参照用: 拡張機能ビットマップミラー |

---

<a id="j05"></a>
## J05: コマンドリングバッファの単位・整列・境界規則

### 質問要約
`RING_SIZE`、`RING_WPTR`、`RING_RPTR` の単位はバイトか dword か。またアライメント要件と末尾の折り返し規則はどうなっているか。

### 確定回答
1. **`RING_SIZE` (`0x02C`) の単位**:
   - **バイト数（Bytes）** で指定します。
   - 4 KiB から 16 MiB までの 2 の冪乗（$2^{12} \le \text{RING\_SIZE} \le 2^{24}$）でなければなりません。
2. **`RING_BASE` (`0x024` / `0x028`) のアライメント**:
   - ホストシステムメモリの **64 バイト境界（Cache Line 整列: 下位 6 ビット `[5:0] == 0`）** に厳格に配置されなければなりません。
   - 下位 6 ビットに非ゼロ値を書き込んでもハードウェア内部でマスク（0 扱い）されます。
3. **`RING_WPTR` (`0x030`) および `RING_RPTR` (`0x034`) の単位**:
   - **dword（32 ビットワード）インデックス** です。
   - 範囲は $0 \le \text{ptr} < (\text{RING\_SIZE} / 4)$ です。
   - 例: 64 KiB のリングバッファ（16,384 dwords）の場合、ポインタは `0`〜`16383` を取ります。
4. **リング境界における折り返し禁止規則 (No Boundary Wrapping)**:
   - 1 つのコマンドパケットがリングバッファの終端を跨いで先頭（インデックス 0）へ跨ぐ（Wrap）ことはハードウェア上**禁止**されています。
   - リング末尾にパケットの全 dword を格納する空き容量が足りない場合、ドライバは末尾の余剰スロットを `CMD_NOP`（opcode: `0x00`）で埋め尽くし、次の正規パケットをインデックス `0` から書き込まなければなりません。
   - CP はリングバッファ末尾に達すると自動的にインデックス 0 へラップします。

---

<a id="j06"></a>
## J06: CAPS / CAPS2 の整理と高速参照ショートカット

### 質問要約
旧仕様の `CAPS` (0x020) / `CAPS2` (0x024) と、新仕様の `FAULT_ADDR_HI` (0x020) / `RING_BASE_LO` (0x024) が競合していた。どのように解決されたか。

### 確定回答
- 旧仕様の `CAPS` (0x020) および `CAPS2` (0x024) は**完全廃止**されました。
- `0x020` は 64 ビット対応の `FAULT_ADDR_HI`、`0x024` は 64 ビット対応の `RING_BASE_LO` として確定しました。
- ケーパビリティの取得は以下の正規ルートに一本化されました：
  1. **基本機能**: Page 0 の `GHCI_REG_DEVICE_CAPS` (`0x008`) を参照。
  2. **拡張機能の高速取得**: EXTCAP リンクリストを走査するコストを削減するため、Page 0 末尾にショートカットレジスタ `GHCI_REG_EXT_CAP_HEADER` (`0x080`) および `GHCI_REG_EXT_CAP_FEATURE` (`0x084`) が新設されました。ドライバ初期化ルーチンはリンクリストを辿ることなく、Page 0 単一の MMIO バースト読出しで全機能フラグを判定可能です。

---

<a id="j07"></a>
## J07: セッション上限と CMD_BIND_SESSION のハードウェア振る舞い

### 質問要約
GPU がサポートする同時セッション数はいくつか。また、ハードウェア MMU ウォーカー非搭載構成や保護機能オフの構成において `CMD_BIND_SESSION` はどのように振る舞うか。

### 確定回答
1. **最大セッション数**:
   - 同時アクティブセッションの上限は **16 セッション（ID: 0〜15）** です。
   - セッション 0 はカーネル空間・特権グラフィックスコンテキスト（ディスプレイ表示用合成プレーン等）専用に予約されています。
2. **`CMD_BIND_SESSION` (`0x14`) の挙動**:
   - **ケース A: `CAP_HW_WALKER = 0` かつ `CAP_PROT = 0` (フラット物理空間モード)**:
     - CP は `CMD_BIND_SESSION` を単一サイクルで消費し、**NOP（何もしない）** として安全にバイパスします。ドライバはエラーなしで実行を継続できます。
   - **ケース B: `CAP_PROT = 1` かつ `CAP_HW_WALKER = 0` (セグメント保護モード)**:
     - CP は内部の保護レジスタ群から、指定された `session_id` に紐づくメモリグラント（ベースアドレスおよび上限オフセット）を選択し、実行ユニットのメモリ窓を即座に切り替えます。
   - **ケース C: `CAP_HW_WALKER = 1` (2段階仮想アドレス変換モード)**:
     - CP は MMU ウォーカーのアクティブ CR3（Root Page Directory ポインタ）を指定セッションのものに切り替え、当該セッション以外の古い L1 TLB エントリをフラッシュします。

---

<a id="j08"></a>
## J08: DEVICE_CAPS レジスタ全 32 ビット確定割当

### 質問要約
`DEVICE_CAPS`（`0x008`）のビット割当において、上位ビット `[29:24]` の重複バグが指摘されていた。確定ビットマップを示してほしい。

### 確定回答
`rtl/gpu/cp/atg_cp_regs.v` および `include/ghci_regs.h` において、重複を完全解消した確定割当は以下のとおりです。

```
 31 30 29 28 27 26 25 24 23              16 15               8 7 6 5 4 3 2 1 0
+--+--+--+--+--+--+--+--+------------------+------------------+-+-+-+-+-+-+-+-+
|M |D |B |M |T |R |T |P |      NUM_SU      |    SIMD_LANES    |G|F|D|S|I|H|I|U|
|S |I |L |E |A |O |F |R |      (1..4)      |       (32)       |S|P|U|E|N|W|O|M|
|A |S |T |S |S |P |I |O |                  |                  |I|1|A|C|D|W|M|A|
|A |P |  |H |K |P |L |T |                  |                  |1|6|L|R|I|A|M| |
+--+--+--+--+--+--+--+--+------------------+------------------+-+-+-+-+-+-+-+-+
```

| ビット | マクロ名 | 説明 |
|:---:|:---|:---|
| `0` | `GHCI_CAP_UMA` | 1 = 統一メモリアーキテクチャ (Host RAM 共有), 0 = ディスクリート (DDR3 搭載) |
| `1` | `GHCI_CAP_IOMMU` | 1 = ホスト PCIe IOMMU 経由で DMA |
| `2` | `GHCI_CAP_HW_WALKER` | 1 = ハードウェア 2段 MMU ページテーブルウォーカー搭載 |
| `3` | `GHCI_CAP_INDIRECT_DRAW` | 1 = `CMD_DRAW_INDIRECT` ハードウェア実行可能 |
| `4` | `GHCI_CAP_SECONDARY_RING`| 1 = `CMD_EXECUTE_COMMANDS` (セカンダリバッファ) サポート |
| `5` | `GHCI_CAP_DUAL_SOURCE` | 1 = デュアルソースカラーブレンディングサポート |
| `6` | `GHCI_CAP_FP16` | 1 = 半精度浮動小数点 (FP16) 演算およびサンプリング対応 |
| `7` | `GHCI_CAP_GSI1` | 1 = GSI1 プログラマブルシェーダコア搭載 |
| `15:8` | `GHCI_CAP_SIMD_LANES` | ワープあたりの SIMD レーン数（常に 32） |
| `23:16`| `GHCI_CAP_NUM_SU` | 搭載シェーダユニット（SU）物理クラスタ数（1〜4） |
| `24` | `GHCI_CAP_PROT` | 1 = ハードウェアセッション保護機構有効 |
| `25` | `GHCI_CAP_TEX_FFILT` | 1 = 浮動小数点テクスチャハードウェアバイリニアフィルタリング |
| `26` | `GHCI_CAP_ROP_PACK` | 1 = ROP パックド整数形式サポート (R8_UINT, R16_SINT, etc.) |
| `27` | `GHCI_CAP_TASK_SHADER` | 1 = タスクシェーダハードウェアディスパッチサポート |
| `28` | `GHCI_CAP_MESH_SHADER` | 1 = メッシュシェーダハードウェアパイプラインサポート |
| `29` | `GHCI_CAP_BLT` | 1 = 内部 2D/3D 高速 DMA ブリッター搭載 |
| `30` | `GHCI_CAP_DISP` | 1 = オンチップディスプレイコントローラ (DC) 搭載 |
| `31` | `GHCI_CAP_MSAA` | 1 = マルチサンプルアンチエイリアシング (2x/4x) ハードウェア対応 |

---

<a id="j09"></a>
## J09: EXTCAP 拡張機能ブロックのベースオフセットと Vulkan ID

### 質問要約
拡張機能（EXTCAP）の各ブロックの先頭オフセットとリンクリスト構造、および Vulkan ドライバが報告すべき `vendorID` / `deviceID` は何か。

### 確定回答
1. **EXTCAP リンクリスト構成**:
   - BAR0 `0x00C` (`GHCI_REG_EXTCAP_PTR`) は `0x00000100` を返却します。
   - **0x100: フォーマット機能ブロック (`EXTCAP_ID_FMT = 0x0001`)**:
     - 次ポインタ: `0x180`
     - レジスタ窓: `0x140`〜`0x17F`（カラー形式、深度ステンシル形式、圧縮テクスチャサポートビットマップ）
   - **0x180: メモリアーキテクチャブロック (`EXTCAP_ID_MEM = 0x0002`)**:
     - 次ポインタ: `0x1C0`
     - レジスタ窓: `0x1E0`〜`0x1FF`（ローカル DDR3 容量、ホストアパーチャサイズ、アライメント境界）
   - **0x1C0: セッション保護ブロック (`EXTCAP_ID_PROT = 0x0003`)**:
     - 次ポインタ: `0x200`
     - レジスタ窓: `0x1D0`〜`0x1DF`（セッション数、グラントエントリ数）
   - **0x200: ディスプレイコントローラ窓 (`EXTCAP_ID_DISP = 0x0004`)**:
     - 次ポインタ: `0x0000`（リンクリスト終端）
     - レジスタ窓: `0x200`〜`0x23F`（タイミングジェネレータ、ピクセルクロック PLL、フレームバッファスワップ）
2. **Vulkan デバイス ID**:
   - `vendorID`: `0x10EE` (Xilinx PCI Vendor ID) または `0x5441` (ASCII "AT" = Amaterrace)
   - `deviceID`: `0x4748` (ASCII "GH") または FPGA PCIe デバイス ID `0x7024` (KC705 Gen2x4)

---

<a id="j10"></a>
## J10: 可変アドレス空間アーキテクチャ (GPU VA 30〜40bit / Host PA 40〜48bit)

### 質問要約
最新の可変アドレス空間アーキテクチャ（`docs/addressing_architecture.md`）において、GPU 仮想アドレス（VA）と外部ホスト物理アドレス（PA）の幅はどう定義され、4 GiB を超えるホスト RAM へのアクセスやレジスタ設定はどう行われるか。

### 確定回答
1. **2 階層のアドレス幅分離**:
   - **内部 GPU 仮想空間 (`GPU VA`)**: `30`〜`40` ビット可変（Kintex-7 KC705 既定値: **32 ビット = 4 GiB**）。シェーダコアおよび各種パイプライン内部のアドレス計算を極小化し、FPGA の配線混雑を回避します。
   - **外部ホスト物理空間 (`Host PA`)**: `40`〜`48` ビット可変（KC705 既定値: **40 ビット = 1 TiB**）。x86-64 や AArch64 の 64 ビットホスト OS が 4 GiB を超える高位アドレス（`0x0000_0001_0000_0000` 以上）に確保した DMA バッファに完全透過アクセス可能です。
2. **64 ビット対応 MMIO 偶数レジスタペア**:
   - コマンドリングの配置:
     - `RING_BASE_LO` (`0x024`) に物理アドレス下位 `[31:0]` を設定。
     - `RING_BASE_HI` (`0x028`) に物理アドレス上位 `[63:32]` を設定。
     - これにより、リングバッファを 4 GiB を超える任意のホストシステム RAM 上に配置可能。
3. **`CMD_FENCE` のダイレクト DMA 書込み**:
   - `CMD_FENCE` は 64 ビットのホスト物理 DMA アドレスを受け取ります。GPU の DMA コントローラは MMU を介さず、上位 32 ビットを含めた 64 ビット AXI コンテナ経由でホストメモリへシーケンス番号を直接書き戻します。
4. **内部 LSB 削減配線**:
   - ワードバスは下位 2 ビットを省略（`[VA_BITS-1:2]`）、キャッシュラインバスは下位 6 ビットを省略（`[VA_BITS-1:6]`）して配線リソースを削減しています。ドライバはバイトアドレスをそのまま発行して差し支えありません（ハードウェアが適切に整列処理します）。

---

<a id="j11"></a>
## J11: 64-bit 標準ページテーブルエントリ (PTE) フォーマット

### 質問要約
MMU が参照する 64 ビット PTE フォーマットの各ビット定義はどうなっているか。

### 確定回答
Amaterrace GPU は、将来の 64 ビット OS 標準と整合する **8 バイト（64 ビット）標準 PTE** を採用しています。

```
 63          PA_BITS         12 11     8 7   6   5   4   3   2   1   0
+---------------+--------------+--------+---+---+---+---+---+---+---+---+
|   Reserved    |     PPN      | RSVD/  | G | U | A | D | X | W | L | V |
|   (All 0)     |[PA_BITS-1:12]| Soft   |   |   |   |   |   |   |   |   |
+---------------+--------------+--------+---+---+---+---+---+---+---+---+
```

- `V` (`bit 0`): **Valid** (1 = 有効。0 の場合アクセス時に `KIND=3` ページフォールト発生)
- `L` (`bit 1`): **Local** (1 = オンボード DDR3 ローカルメモリ, 0 = ホスト PCIe システムメモリ)
- `W` (`bit 2`): **Writable** (1 = 書込み許可, 0 = リードオンリー)
- `X` (`bit 3`): **Executable** (1 = シェーダ命令フェッチ許可)
- `D` (`bit 4`): **Dirty** (ハードウェアまたはドライバ書込み検知フラグ)
- `A` (`bit 5`): **Accessed** (アクセス検知フラグ)
- `U` (`bit 6`): **User** (1 = ユーザ空間コンテキストからアクセス許可)
- `G` (`bit 7`): **Global** (1 = セッション切替時も TLB に常駐)
- `[11:8]`: ソフトウェア予約ビット（ドライバが自由に使用可能）
- `PPN` (`[PA_BITS-1:12]`): 物理ページ番号（4 KiB ページ境界）。
  - `PA_BITS = 40` の場合: `PPN` は `[39:12]`（28 ビット幅）。ビット `[63:40]` は 0 予約。
  - `PA_BITS = 48` の場合: `PPN` は `[47:12]`（36 ビット幅）。ビット `[63:48]` は 0 予約。

---

<a id="j12"></a>
## J12: ページディレクトリ管理と MMU Out-Of-Memory リカバリ

### 質問要約
2段階ページテーブルのルート（Page Directory）と2段目（Page Table）のメモリ割り当て責任と、メモリ不足（OOM）発生時のフローはどうなるか。

### 確定回答
1. **Root Page Directory (第1段 PT)**:
   - ホストドライバがセッション作成時（`CMD_SESSION_OPEN`）にホストメモリまたはローカルメモリ上に確保・ピン留めし、ゼロクリアしてベースアドレスを GPU に登録します。
   - サイズは 4 KiB（1024 エントリ × 4 バイト、または 512 エントリ × 8 バイト）。
2. **2段目 Page Table の動的確保**:
   - ハードウェアウォーカーが自動走査する際、未確保の 2段目テーブルはドライバがあらかじめ指定した専用動的ヒープ領域（`CP_HEAP_BASE`〜`CP_HEAP_LIMIT`）から CP が自律的に 4 KiB 単位で切り出します。
3. **Out-Of-Memory (OOM) リカバリ手順**:
   - 動的ヒープが枯渇した場合、CP は直ちに `GHCI_FAULT_KIND_MMU_OOM` (`KIND=8`, `UNIT=1`) を `GHCI_REG_FAULT_INFO` に記録し、`GHCI_IRQ_ERROR` 割り込みを発行して当該セッションを一時停止（HALT）します。
   - **ドライバの復帰シーケンス**:
     1. 割り込みハンドラで `KIND=8` を検知。
     2. ホスト側で新たな空き物理ページを確保し、`CMD_VM_MAP` またはヒープ拡張パケットをリングに発行。
     3. `GHCI_REG_CTRL` に `GHCI_CTRL_STEP` または `GHCI_CTRL_RUN` を書き込むことで、失敗したメモリアロケーションから安全に再開します。

---

<a id="j13"></a>
## J13: CMD_FENCE (0x33) 確定バイナリレイアウト

### 質問要約
`CMD_FENCE` の語数と各 dword のレイアウトはどう確定したか。

### 確定回答
`CMD_FENCE` は **厳密に 6 dwords（24 バイト）** で構成されます。

```c
typedef struct GhciCmdFence {
    uint32_t header;        /* dw0: [7:0] opcode=0x33, [15:8] length=6, [31:16] flags */
    uint32_t fence_addr_lo; /* dw1: ホスト物理 DMA アドレス [31:0] (8バイト整列) */
    uint32_t fence_addr_hi; /* dw2: ホスト物理 DMA アドレス [63:32] */
    uint32_t seq_value_lo;  /* dw3: 書込み完了通知シーケンス番号下位 [31:0] */
    uint32_t seq_value_hi;  /* dw4: 書込み完了通知シーケンス番号上位 [63:32] */
    uint32_t flags;         /* dw5: 同期制御フラグ */
} GhciCmdFence;
```

- **`dw5 (flags)` の詳細**:
  - `bit 0`: `1` = メモリ書込み完了後にホストへ `GHCI_IRQ_FENCE` 割り込みを発行。
  - `bit 1`: `1` = 割り込み発行前に L2 キャッシュおよび PCIe ライトコンバイニングバッファを完全フラッシュ。

---

<a id="j14"></a>
## J14: CMD_DRAW_INDIRECT (0x29) 確定バイナリレイアウト

### 質問要約
`CMD_DRAW_INDIRECT` の語数とインデックス描画・カウントバッファ対応はどうなっているか。

### 確定回答
`CMD_DRAW_INDIRECT` は **厳密に 7 dwords（28 バイト）** で構成されます。

```c
typedef struct GhciCmdDrawIndirect {
    uint32_t header;        /* dw0: [7:0] opcode=0x29, [15:8] length=7 */
    uint32_t buffer_va_lo;  /* dw1: 描画パラメータバッファ GPU VA [31:0] */
    uint32_t buffer_va_hi;  /* dw2: 描画パラメータバッファ GPU VA [63:32] */
    uint32_t offset_bytes;  /* dw3: バッファ内先頭オフセット（バイト単位） */
    uint32_t draw_count;    /* dw4: 描画回数（または maxDrawCount） */
    uint32_t stride_bytes;  /* dw5: 各描画パラメータ構造体のストライド (16 or 20B) */
    uint32_t flags;         /* dw6: 実行制御フラグ */
} GhciCmdDrawIndirect;
```

- **`dw6 (flags)` の詳細**:
  - `bit 0`: `0` = 非インデックス描画（Direct Draw）、`1` = インデックス描画（Indexed Draw）
  - `bit 1`: `0` = `draw_count` を直接使用、`1` = カウントバッファから実際の描画回数を動的ロード（`vkCmdDrawIndirectCount` 準拠）

---

<a id="j15"></a>
## J15: 128 バイトパイプラインステートオブジェクト (GhciPipelineState)

### 質問要約
`GhciPipelineState`（PSO）の確定サイズと構造体メンバの完全レイアウトを示してほしい。

### 確定回答
`GhciPipelineState` は **厳密に 128 バイト（32 dwords）** で構成され、64 バイトまたは 128 バイト境界に整列して共有メモリ上に配置されます。CP はこれを 2 回の 64 バイトバースト DMA でプリフェッチし、1〜2 サイクルで全パイプラインレジスタにブロードキャスト設定します。

```c
typedef struct GhciVertexAttribute {
    uint32_t binding_offset;   /* [3:0] バインディングスロット(0..15), [27:4] バイトオフセット */
    uint32_t format_location;  /* [15:0] VkFormat, [23:16] シェーダロケーション番号(0..15) */
} GhciVertexAttribute;

typedef struct GhciPipelineState {
    /* 0x00..0x1F: シェーダステージベースアドレス (64-bit GPU VA) */
    uint64_t vs_code_va;            /* dw0-1: 頂点シェーダ命令ベース */
    uint64_t fs_code_va;            /* dw2-3: フラグメントシェーダ命令ベース */
    uint64_t cs_code_va;            /* dw4-5: コンピュートシェーダ命令ベース */
    uint64_t ms_code_va;            /* dw6-7: メッシュ/タスクシェーダ命令ベース */

    /* 0x20..0x3F: 固定機能パイプラインステート */
    uint32_t flags;                 /* dw8:  [2:0] トポロジ, [3] プリミティブリスタート, [4] 深度クランプ, [5] ロジックオペレーション許可 */
    uint32_t raster_state;          /* dw9:  [1:0] カリングモード, [2] フロントフェイス(CW), [4:3] ポリゴンモード, [5] 深度バイアス有効 */
    uint32_t depth_stencil_state;   /* dw10: [0] 深度テスト, [1] 深度書込み, [4:2] 深度比較Op, [5] ステンシルテスト, [13:6] ステンシル書込みマスク, [21:14] ステンシル比較マスク */
    uint32_t blend_state;           /* dw11: [0] ブレンド有効, [5:1] SrcColor, [10:6] DstColor, [13:11] ColorOp, [18:14] SrcAlpha, [23:19] DstAlpha, [26:24] AlphaOp, [30:27] カラーライトマスク(RGBA) */
    uint32_t vertex_strides;        /* dw12: [7:0] バインディング0ストライド, [15:8] バインディング1, [23:16] バインディング2, [31:24] バインディング3 */
    uint32_t reserved[3];           /* dw13-15: 将来拡張用パディング（常に 0） */

    /* 0x40..0x7F: 頂点入力アトリビュート定義配列 (64 バイト) */
    GhciVertexAttribute attributes[8]; /* dw16-31: 最大 8 個の頂点属性スロット */
} GhciPipelineState;
```

---

<a id="j16"></a>
## J16: レンダーパスアタッチメント仕様と LoadOp/StoreOp エンコード

### 質問要約
同時にバインド可能なカラーアタッチメント数と、`CMD_BEGIN_RENDER_PASS`（`0x2B`）における LoadOp/StoreOp のビットエンコード規則はどうなっているか。

### 確定回答
1. **最大アタッチメント数**:
   - 同時バインド可能なカラーアタッチメント数は **最大 8 個（スロット 0〜7）** です。
   - 未使用スロットには `VK_ATTACHMENT_UNUSED` (`0xFFFFFFFF`) を指定します。
2. **`CMD_BEGIN_RENDER_PASS` (10 dwords) のレイアウト**:
   - `dw1`: `color_attachment_mask` (有効なアタッチメントのビットマスク `[7:0]`)
   - `dw2`: `color_clear_rgba` (パックド RGBA8 または fp16 クリア色)
   - `dw3`: `depth_clear_value` (32-bit float または 24-bit 深度クリア値)
   - `dw4`: `stencil_clear_value` (`[7:0]` ステンシルクリア値)
   - `dw5`: `load_op_mask`
   - `dw6`: `store_op_mask`
   - `dw7`: `render_area_offset` (`[15:0] X`, `[31:16] Y`)
   - `dw8`: `render_area_extent` (`[15:0] Width`, `[31:16] Height`)
   - `dw9`: `flags`
3. **LoadOp / StoreOp エンコード**:
   - 2 ビットで 1 つのアタッチメント操作を表します：
     - `Color 0`: `bits [1:0]`
     - `Color 1`: `bits [3:2]`
     - ...
     - `Depth`: `bits [17:16]`
     - `Stencil`: `bits [19:18]`
   - **LoadOp コード**: `00` = `LOAD_OP_LOAD`, `01` = `LOAD_OP_CLEAR`, `10` = `LOAD_OP_DONT_CARE`
   - **StoreOp コード**: `00` = `STORE_OP_STORE`, `01` = `STORE_OP_DONT_CARE`

---

<a id="j17"></a>
## J17: リソースディスクリプタ構造と Combined Image Sampler 実装

### 質問要約
バッファ、テクスチャ、サンプラーの各ディスクリプタのバイト長と構造、および Combined Image Sampler の実装形態はどうなっているか。

### 確定回答
リソースバインディングはフラットなインメモリディスクリプタテーブル方式を採用しています。ドライバはメモリ上に以下の構造体を連続配置し、`CMD_BIND_DESCRIPTOR_TABLE`（`0x23`）でベースポインタをバインドします。

1. **バッファディスクリプタ (`GhciBufferDescriptor`, 16 バイト)**:
   ```c
   typedef struct GhciBufferDescriptor {
       uint64_t base_address;  /* 0x00: 64-bit GPU 仮想アドレス */
       uint32_t size_bytes;    /* 0x08: バッファサイズ（バイト単位） */
       uint16_t stride_bytes;  /* 0x0C: 構造化バッファの要素ストライド */
       uint8_t  format;        /* 0x0E: テクセルバッファ時の VkFormat (通常は 0) */
       uint8_t  flags;         /* 0x0F: [0] ReadOnly, [1] Coherent */
   } GhciBufferDescriptor;
   ```
2. **テクスチャディスクリプタ (`GhciTextureDescriptor`, 32 バイト)**:
   ```c
   typedef struct GhciTextureDescriptor {
       uint64_t base_address;       /* 0x00: ミップレベル0の先頭 GPU 仮想アドレス */
       uint16_t width;              /* 0x08: テクセル幅 (1..16384) */
       uint16_t height;             /* 0x0A: テクセル高さ (1..16384) */
       uint16_t depth;              /* 0x0C: 3D 深度または配列レイヤ数 */
       uint8_t  format;             /* 0x0E: ハードウェアテクスチャ形式コード */
       uint8_t  mip_levels;         /* 0x0F: ミップマップ数 (1..15) */
       uint32_t row_pitch_bytes;    /* 0x10: 行ストライドバイト数 (64B 整列) */
       uint32_t slice_pitch_bytes;  /* 0x14: 2D スライスまたは配列レイヤストライド */
       uint8_t  sample_count;       /* 0x18: MSAA サンプル数 (1, 2, 4) */
       uint8_t  dimension;          /* 0x19: 0=1D, 1=2D, 2=3D, 3=Cube */
       uint16_t flags;              /* 0x1A: [0] 0=Linear, 1=Tiled, [1] sRGB */
       uint32_t reserved;           /* 0x1C: ゼロパディング */
   } GhciTextureDescriptor;
   ```
3. **サンプラーディスクリプタ (`GhciSamplerDescriptor`, 16 バイト)**:
   ```c
   typedef struct GhciSamplerDescriptor {
       uint8_t  min_filter;     /* 0x00: 0=Nearest, 1=Linear */
       uint8_t  mag_filter;     /* 0x01: 0=Nearest, 1=Linear */
       uint8_t  mipmap_mode;    /* 0x02: 0=Nearest, 1=Linear */
       uint8_t  address_mode_u; /* 0x03: 0=Repeat, 1=Mirrored, 2=ClampEdge, 3=ClampBorder */
       uint8_t  address_mode_v; /* 0x04: V 方向アドレスモード */
       uint8_t  address_mode_w; /* 0x05: W 方向アドレスモード */
       uint8_t  compare_enable; /* 0x06: 1=シャドウサンプリング(PCF)比較有効 */
       uint8_t  compare_op;     /* 0x07: 深度比較演算子 */
       int16_t  lod_bias_fx8;   /* 0x08: 符号付き 8.8 固定小数点 LOD バイアス */
       uint8_t  min_lod_fx4;    /* 0x0A: 符号なし 4.4 固定小数点 最小 LOD クランプ */
       uint8_t  max_lod_fx4;    /* 0x0B: 符号なし 4.4 固定小数点 最大 LOD クランプ */
       uint32_t border_color;   /* 0x0C: パックド RGBA8 ボーダー色 */
   } GhciSamplerDescriptor;
   ```
4. **Combined Image Sampler の実装**:
   - Vulkan の `VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER` は、ディスクリプタテーブル上で **テクスチャ（32B）＋サンプラー（16B）が連続した 48 バイトエントリ** として配置するか、またはシェーダ命令引数として `{ uint16_t tex_id, uint16_t sampler_id }` の 32 ビットインデックスペアとして渡します。

---

<a id="j18"></a>
## J18: 新規構造化コマンドの完全バイナリ仕様

### 質問要約
`CMD_BIND_SESSION`、`CMD_WAIT_FENCE`、`CMD_WRITE_TIMESTAMP`、`CMD_COPY_BUFFER`、`CMD_FILL_BUFFER` 等の新規コマンドの確定バイナリ仕様を示してほしい。

### 確定回答

#### 1. `CMD_BIND_SESSION` (`0x14`, 2 dwords)
```c
typedef struct GhciCmdBindSession {
    uint32_t header;        /* opcode = 0x14, length = 2 */
    uint32_t session_id;    /* アクティブセッション番号 (0..15) */
} GhciCmdBindSession;
```

#### 2. `CMD_WAIT_FENCE` (`0x34`, 4 dwords)
CP のリング実行を指定メモリアドレスの値が条件を満たすまで停止（ポーリング待機）させます。
```c
typedef struct GhciCmdWaitFence {
    uint32_t header;        /* opcode = 0x34, length = 4 */
    uint32_t fence_addr_lo; /* 監視対象ホスト/ローカルメモリ物理アドレス下位 */
    uint32_t fence_addr_hi; /* 監視対象メモリ物理アドレス上位 */
    uint32_t wait_value;    /* 待機比較値 ((int32_t)(mem - wait_value) >= 0 で通過) */
} GhciCmdWaitFence;
```

#### 3. `CMD_WRITE_TIMESTAMP` (`0x35`, 4 dwords)
GPU 内部の 64 ビットクロックサイクルカウンタを指定メモリアドレスに書き出します。
```c
typedef struct GhciCmdWriteTimestamp {
    uint32_t header;        /* opcode = 0x35, length = 4 */
    uint32_t dst_addr_lo;   /* 書出し先 64-bit GPU VA / ホスト DMA アドレス下位 */
    uint32_t dst_addr_hi;   /* 書出し先アドレス上位 */
    uint32_t pipeline_stage;/* 0=Top of Pipe, 1=Post-Raster, 2=Bottom of Pipe */
} GhciCmdWriteTimestamp;
```

#### 4. `CMD_COPY_BUFFER` (`0x40`, 7 dwords)
内部ブリッターによる高速メモリ間 DMA 転送。
```c
typedef struct GhciCmdCopyBuffer {
    uint32_t header;        /* opcode = 0x40, length = 7 */
    uint32_t src_va_lo;     /* 転送元 GPU 仮想アドレス下位 */
    uint32_t src_va_hi;     /* 転送元 GPU 仮想アドレス上位 */
    uint32_t dst_va_lo;     /* 転送先 GPU 仮想アドレス下位 */
    uint32_t dst_va_hi;     /* 転送先 GPU 仮想アドレス上位 */
    uint32_t size_bytes;    /* 転送バイト数 */
    uint32_t flags;         /* 転送制御フラグ */
} GhciCmdCopyBuffer;
```

#### 5. `CMD_FILL_BUFFER` (`0x43`, 5 dwords)
バッファ領域を指定の 32 ビットパターンで一括フィル（高速バッファクリア）。
```c
typedef struct GhciCmdFillBuffer {
    uint32_t header;        /* opcode = 0x43, length = 5 */
    uint32_t dst_va_lo;     /* フィル先 GPU 仮想アドレス下位 */
    uint32_t dst_va_hi;     /* フィル先 GPU 仮想アドレス上位 */
    uint32_t size_bytes;    /* フィルサイズ（バイト数、4の倍数） */
    uint32_t pattern_data;  /* 埋め込み用 32 ビット値 */
} GhciCmdFillBuffer;
```

---

<a id="j19"></a>
## J19: Vulkan 1.0 物理デバイスリミット一覧 (§8.6)

### 質問要約
`vkGetPhysicalDeviceProperties` の `VkPhysicalDeviceLimits` に設定すべきハードウェアパラメータの確定値を示してほしい。

### 確定回答

| Vulkan Limit プロパティ名 | 確定設定値 | ハードウェア根拠 |
|:---|:---:|:---|
| `maxImageDimension1D` | `16,384` | 14 ビットテクセル座標インデックス |
| `maxImageDimension2D` | `16,384` | 14 ビットテクセル座標インデックス |
| `maxImageDimension3D` | `2,048` | 11 ビット 3D ボリューム座標インデックス |
| `maxImageDimensionCube` | `16,384` | キューブマップ面解像度上限 |
| `maxImageArrayLayers` | `2,048` | 11 ビット配列レイヤインデックス |
| `maxTexelBufferElements` | `67,108,864` | 最大 256 MiB テクセルバッファ |
| `maxUniformBufferRange` | `65,536` | 64 KiB ウィンドウ（8 KiB オンチップ定数キャッシュ） |
| `maxStorageBufferRange` | `2,147,483,648`| 2 GiB (32-bit GPU 仮想アドレス空間) |
| `maxPushConstantsSize` | `128` | 32 dwords (`CMD_LOAD_CONST` オンチップ定数バンク直結) |
| `maxMemoryAllocationCount` | `4,096` | ドライバ同時メモリマッピング上限 |
| `maxSamplerAllocationCount` | `4,000` | インメモリサンプラーディスクリプタ上限 |
| `maxBoundDescriptorSets` | `4` | ハードウェアディスクリプタポインタレジスタ 4 基 |
| `maxPerStageDescriptorSamplers` | `16` | ステージあたり 16 サンプラースロット |
| `maxPerStageDescriptorUniformBuffers` | `16` | ステージあたり 16 UBO スロット |
| `maxPerStageDescriptorStorageBuffers` | `16` | ステージあたり 16 SSBO スロット |
| `maxPerStageDescriptorSampledImages` | `16` | ステージあたり 16 テクスチャスロット |
| `maxPerStageDescriptorStorageImages` | `8` | ステージあたり 8 ストレージイメーシスロット |
| `maxVertexInputAttributes` | `16` | ハードウェア頂点フェッチャ入力チャネル数 |
| `maxVertexInputBindings` | `16` | 頂点ストリームバッファスロット数 |
| `maxVertexInputAttributeOffset` | `65,535` | 16 ビット頂点属性オフセット |
| `maxVertexInputBindingStride` | `4,095` | 12 ビット頂点ストライドフィールド |
| `maxColorAttachments` | `8` | ROP 同時出力ターゲット数 |
| `maxComputeWorkGroupCount[3]` | `{65535, 65535, 65535}` | 16 ビットワークグループディスパッチカウンタ |
| `maxComputeWorkGroupInvocations` | `256` | 8 ワープ × 32 レーン (SU あたり) |
| `maxComputeWorkGroupSize[3]` | `{256, 256, 64}` | ワークグループ次元上限 |
| `maxComputeSharedMemorySize` | `4,096` | オンチップ LDS (Local Data Share) RAM 容量 (4 KiB) |
| `subGroupSize` | `32` | ネイティブ SIMD ワープ幅 |

---

<a id="j20"></a>
## J20: ハードウェアテクスチャ形式と VkFormat 対応表

### 質問要約
主要なテクスチャ形式コードと `VkFormat` の対応表、および `menuconfig` でのビルドオプション連携はどうなっているか。

### 確定回答
ハードウェアテクスチャ形式コードは Vulkan 1.0 コア仕様と 1:1 に直結しています。ビルド時のリソース制約に応じて `tools/menuconfig.py` によりハードウェアデコーダの有無を選択可能です。

| ハードウェア形式コード | VkFormat 定数 | 形式名 | 必須性 / ビルドコンフィグ |
|:---:|:---:|:---|:---|
| `9` | `9` | `VK_FORMAT_R8_UNORM` | 必須基本形式（Mandatory） |
| `16` | `16` | `VK_FORMAT_R8G8_UNORM` | 必須基本形式（Mandatory） |
| `37` | `37` | `VK_FORMAT_R8G8B8A8_UNORM` | 必須基本形式（Mandatory） |
| `43` | `43` | `VK_FORMAT_R8G8B8A8_SRGB` | `CONFIG_FMT_ENABLE_SRGB=1` |
| `44` | `44` | `VK_FORMAT_B8G8R8A8_UNORM` | 必須基本形式（表示Scanout互換） |
| `50` | `50` | `VK_FORMAT_B8G8R8A8_SRGB` | `CONFIG_FMT_ENABLE_SRGB=1` |
| `84` | `84` | `VK_FORMAT_R5G6B5_UNORM_PACK16` | `CONFIG_FMT_ENABLE_RGB565=1` |
| `124` | `124` | `VK_FORMAT_D16_UNORM` | `CONFIG_FMT_ENABLE_DEPTH16=1` |
| `126` | `126` | `VK_FORMAT_D32_SFLOAT` | `CONFIG_FMT_ENABLE_DEPTH32F=1` |
| `129` | `129` | `VK_FORMAT_D24_UNORM_S8_UINT` | `CONFIG_FMT_ENABLE_DEPTH24_S8=1` |
| `131`〜`145` | `131`〜`145` | `VK_FORMAT_BC1`〜`BC7_UNORM_BLOCK` | `CONFIG_TU_ENABLE_BC=1` |
| `147`〜`156` | `147`〜`156` | `VK_FORMAT_ETC2` / `EAC_*_BLOCK` | `CONFIG_TU_ENABLE_ETC2=1` |

ドライバは初期化時に EXTCAP FMT ブロック（`0x140`〜`0x17F`）を読み出すことで、当該 FPGA ビットストリームに組み込まれている形式群を動的に判定できます。

---

<a id="j21"></a>
## J21: コマンドプロセッサフォールト検出とリングリセット手順

### 質問要約
ハングアップやフォールトが発生した際、ドライバが GPU コアをリセットして安全に再稼働させるための正規シーケンスは何か。

### 確定回答
1. **フォールトの検出**:
   - `GHCI_REG_STATUS` の `GHCI_STATUS_FAULTED` (`bit 2`) が 1 になるか、または `GHCI_IRQ_ERROR` / `GHCI_IRQ_WATCHDOG` 割り込みを受信します。
2. **原因の保全と診断**:
   - `GHCI_REG_FAULT_INFO` (`0x018`)、`GHCI_REG_FAULT_ADDR` (`0x01C`)、`GHCI_REG_FAULT_ADDR_HI` (`0x020`) を読み出してログに記録します。
3. **ハードウェアリセットの発行**:
   - `GHCI_REG_CTRL` (`0x014`) に `GHCI_CTRL_RESET` (`bit 0 = 1`) を書き込みます。
   - 最低 16 GPU クロックサイクル（約 200 ns）待機します。
4. **リセット解除と状態クリア**:
   - `GHCI_REG_CTRL` に `0x00000000` を書き込みリセットを解除します。
   - `GHCI_REG_IRQ_STATUS` (`0x038`) に `0xFFFFFFFF` を書き込み、残存する全割り込みラッチをクリア（W1C）します。
5. **リングバッファの再構成**:
   - 新たなコマンドリングバッファ（またはクリーンな領域）のアドレスを `GHCI_REG_RING_BASE_LO` / `HI` に設定し、`GHCI_REG_RING_SIZE` を設定します。
   - `GHCI_REG_RING_WPTR` および `GHCI_REG_RING_RPTR` に `0` を書き込み初期化します。
6. **再稼働**:
   - `GHCI_REG_CTRL` に `GHCI_CTRL_RUN` (`bit 1 = 1`) を書き込むことで、GPU のパケットフェッチを再開します。

---

<a id="j22"></a>
## J22: キャッシュ整合性とパイプラインバリア (CMD_BARRIER)

### 質問要約
パイプラインステージ間の同期とメモリキャッシュのフラッシュ・無効化を司る `CMD_BARRIER`（`0x31`）の仕様とフラグ指定方法は何か。

### 確定回答
`CMD_BARRIER` は 4 dwords で構成されます。

```c
typedef struct GhciCmdBarrier {
    uint32_t header;         /* opcode = 0x31, length = 4 */
    uint32_t src_stage_mask; /* 完了を待つ先行ステージビットマスク */
    uint32_t dst_stage_mask; /* ブロックされる後続ステージビットマスク */
    uint32_t flags;          /* キャッシュ制御・パイプラインドレインフラグ */
} GhciCmdBarrier;
```

- **ステージマスクビット (`src_stage_mask` / `dst_stage_mask`)**:
  - `bit 0`: `STAGE_TOP_OF_PIPE`
  - `bit 1`: `STAGE_VERTEX_FETCH` (VF)
  - `bit 2`: `STAGE_VERTEX_SHADER` (VS)
  - `bit 3`: `STAGE_FRAGMENT_SHADER` (FS)
  - `bit 4`: `STAGE_COMPUTE_SHADER` (CS)
  - `bit 5`: `STAGE_RENDER_OUTPUT` (ROP)
  - `bit 6`: `STAGE_BLITTER` (BLT)
  - `bit 7`: `STAGE_BOTTOM_OF_PIPE`
- **`flags` のビット割当**:
  - `bit 0`: **L2 Cache Flush** — 内部共有 L2 キャッシュのダーティラインを DDR3 / ホストメモリへ全書出し。
  - `bit 1`: **L1 Cache Invalidate** — テクスチャ L1 キャッシュ、頂点キャッシュ、命令キャッシュを無効化。
  - `bit 2`: **TLB Invalidate** — MMU の L1/L2 変換テーブルキャッシュ（TLB）を無効化。
  - `bit 3`: **Pipeline Drain** — ラスタライザおよび ROP 内の未処理ピクセルを完全にメモリへフラッシュするまで後続ステージを開始しない。

---

<a id="j23"></a>
## J23: 画面表示同期 (CMD_FLIP / VBLANK) と W1C 割り込み制御

### 質問要約
画面表示のティアリング防止スワップ（Flip）と垂直同期（VBLANK）の連携、および `IRQ_STATUS` の W1C（Write-1-to-Clear）の動作仕様はどうなっているか。

### 確定回答
1. **非同期フリップキューイング (`CMD_FLIP`, 0x51)**:
   - ドライバはリング内に `CMD_FLIP(framebuffer_addr)` を投入します。
   - コマンドプロセッサはディスプレイコントローラ（DC）のスワップレジスタにアドレスをラッチします。実際のフレームバッファ切替は、**次のハードウェア VSYNC 信号の立ち下がりエッジに厳格に同期**して実行されます。これにより画面のティアリングはハードウェアレベルで完全に排除されます。
2. **フリップ完了および VBLANK 割り込み**:
   - VSYNC 期間に入ると `GHCI_IRQ_VBLANK` (`bit 9`) がアサートされます。
   - スワップが実際に完了すると `GHCI_IRQ_FLIP` (`bit 10`) がアサートされます。
3. **Write-1-to-Clear (W1C) 割り込み処理規則**:
   - `GHCI_REG_IRQ_STATUS` (`0x038`) は全ビット厳格な W1C です。
   - 割り込みハンドラは、読出したステータス値そのまま（または処理完了したビットに 1 を立てた値）を書き込むことで、対象の割り込み要因を安全にクリアします。`0` を書いたビットの状態は一切変化しません。

---

<a id="j24"></a>
## J24: GSI1 シェーダ ISA および機能ビットマップ

### 質問要約
プログラマブルシェーダユニット（SU）がサポートする GSI1 ISA の命令セットおよび機能ビットマップはどうなっているか。

### 確定回答
GSI1 は 32 レーン SIMD ワープを基本単位とする 32 ビット固定長 RISC 風 GPU シェーダ ISA です。
- **レジスタ構成**:
  - `r[0..63]`: 32 ビットスカラー/ベクトル汎用レジスタ（GPR）。
  - 広域メモリアドレスは偶数レジスタペア $\{r[2k+1], r[2k]\}$ を指定して 64 ビットポインタとして扱います（ポート追加なしの偶奇バンクアクセス）。
  - `c[0..511]`: プッシュコンスタントおよびユニフォーム用オンチップ定数バンク。
- **命令カテゴリ**:
  1. **ALU 演算**: `ADD`, `SUB`, `MUL`, `MAD`/`FMA`, `MIN`, `MAX`, `AND`, `OR`, `XOR`, `SHL`, `SHR`.
  2. **浮動小数点**: 単精度 `FADD`, `FMUL`, `FFMA`, `FDIV`, `FSQRT`, `FRCP`, `FRSQRT`, `FMIN`, `FMAX`. 半精度パック演算（`CAP_FP16=1` 時: 2x FP16 SIMD）。
  3. **型変換**: `F2I`, `I2F`, `F2H`, `H2F`, `PACK_2x16`, `UNPACK_2x16`.
  4. **サンプリング**: `TEX_LD` (テクスチャロード), `TEX_SAMPLE` (バイリニア/トライリニアサンプリング), `TEX_GATHER4`, `TEX_GRAD`.
  5. **ロード/ストア**: `LOAD32`, `STORE32`, `LOAD64`, `STORE64`, `LDS_LOAD`, `LDS_STORE` (共有メモリ), `ATOMIC_ADD`, `ATOMIC_CAS`.
  6. **制御フロー**: `BRA` (分岐), `BRAC` (条件分岐), `CALL`, `RET`, `BARRIER` (ワープ間同期).
  7. **出力**: `EXP_POS` (頂点位置出力), `EXP_PARAM` (補間属性出力), `EXP_COLOR` (ピクセルカラー出力).

---

<a id="j25"></a>
## J25: フラット物理アドレスモードとセカンダリリングのネスト実行

### 質問要約
`HW_WALKER=0` の組み込み環境での物理アドレス運用と、セカンダリコマンドバッファの実行規則、および `CMD_VM_MAP` のアライメント要件はどうなっているか。

### 確定回答
1. **フラット物理アドレスモード (`HW_WALKER = 0`)**:
   - MMU テーブルウォーカーが存在しないシステムでは、GPU 仮想アドレス空間はシステム物理アドレス空間に 1:1 直結（Identity Mapping）されます。
   - 頂点バッファ、テクスチャ、不変 PSO、フレームバッファの各ポインタには、ドライバが確保した物理アドレス（または IOMMU が割り当てた IOVA）を直接記述します。
2. **セカンダリコマンドバッファの実行 (`CMD_EXECUTE_COMMANDS`, 0x32)**:
   - UMA 環境において CPU マルチスレッドで記録されたセカンダリコマンドバッファを、メモリコピーなし（Zero-Copy）で直接実行します。
   - **階層制限**: 厳格に **1 階層** のみサポートされます（プライマリリング $\to$ セカンダリバッファ。セカンダリバッファ内からのさらなる子セカンダリバッファ呼出しは禁止。Vulkan 規格完全準拠。K16 参照）。
   - セカンダリバッファ完了時、CP は自動的にプライマリリングの呼出し元次パケットへ復帰します。
3. **`CMD_VM_MAP` のアライメント要件**:
   - 仮想アドレス（VA）および物理アドレス（PA/IOVA）は、**厳格に 4 KiB（`0x1000`）境界** で整列していなければなりません。
   - マッピングサイズ（`page_count`）は 4 KiB ページの整数倍です。

---

<a id="j26"></a>
## J26: CPU 書込み・GPU 読出し時のキャッシュコヒーレンシ手順

### 質問要約
CPU 側でコマンドリングや PSO、頂点データをメモリに書き込んだ後、GPU が正しく読み出すためのホスト側キャッシュコヒーレンシ手順はどうあるべきか。

### 確定回答
1. **x86-64 アーキテクチャ**:
   - x86-64 の PCIe バスはスヌーピングによるハードウェアキャッシュコヒーレンシが保証されています。
   - ただし、CPU の書込みバッファ（Store Buffer）を即座に PCIe コントローラおよび RAM へ掃き出すため、ドアベル（`RING_WPTR` 書込み）の直前に **`sfence`（または `mfence`）命令** を実行しなければなりません。
   - Write-Combining (WC) メモリを使用している場合は、必ず `sfence` を発行して WC バッファをフラッシュしてください。
2. **ARM64 (AArch64) / RISC-V アーキテクチャ**:
   - PCIe インターコネクトが非スヌーピング（Non-coherent）構成の場合、ドライバは `dma_sync_single_for_device()` 等を呼び出し、CPU の L1/L2 データキャッシュラインを明示的にクリーン（`dc cvac`）しなければなりません。
   - ドアベル発行直前に `dsb st`（Data Synchronization Barrier, Store）を発行してください。

---

<a id="j27"></a>
## J27: IOMMU 有効環境および Passthrough 環境におけるドライバ動作要件

### 質問要約
Linux カーネルで Intel VT-d / AMD-Vi / ARM SMMU 等の IOMMU が有効な環境、および Passthrough モードにおけるドライバの DMA アドレス設定要件はどうなるか。

### 確定回答
1. **IOMMU 有効環境 (`iommu=on`)**:
   - `DEVICE_CAPS` の `GHCI_CAP_IOMMU` (`bit 1`) が 1 の場合、GPU が発行する PCIe トランザクションはすべてホスト IOMMU のアドレス変換を受けます。
   - ドライバは `dma_map_single()`、`dma_map_sg()`、または `dma_alloc_coherent()` が返却する **IOVA（I/O Virtual Address: 40〜48 ビット）** を、そのまま `RING_BASE_LO`/`HI`、`CMD_FENCE` の `fence_addr`、および PTE の `PPN` に設定しなければなりません。ホストの実物理アドレス（CPU PA）を直接書き込んではなりません。
2. **IOMMU Passthrough 環境 (`iommu=pt` または IOMMU 非搭載)**:
   - IOVA は CPU 物理アドレス（PA）と完全に一致します。
   - ドライバは通常どおりホスト物理アドレスをレジスタおよびコマンドに設定します。
3. **4 GiB 超（64 ビット）アドレッシングの完全保証**:
   - IOMMU が 4 GiB を超える高位 IOVA（例: `0x0000_0010_0000_0000`）を割り当てた場合でも、Amaterrace GPU のホストインターフェースは 40〜48 ビット PA/IOVA（`PA_BITS`）に対応しており、`{RING_BASE_HI, RING_BASE_LO}` および 64-bit PTE 経由で一切のアドレス切り捨てなしに安全に動作します。

---

# 第3部: ドライバ再質問 K01〜K19 決定回答集

<a id="k01"></a>
## K01: 正当仕様書と同期時期（ghci.md 一本化）

### 質問要約
ドライバ開発者にとってハードウェア・ドライバ間の唯一の正当仕様書（Single Source of Truth）は何か。また、これまでの Q&A で確定した仕様と正当仕様書の同期時期はどうなるか。

### 確定回答
1. **唯一の正当仕様書**:
   - ハードウェア（Verilog RTL）・ドライバ（KMD / Mesa Vulkan ICD）間の唯一の正当仕様書は **`docs/ghci.md`** です。
   - 本 Q&A 書面（`docs/driver_qa_j01_j27.md`）は、仕様策定および質疑応答の合意プロセスを記録した補助文書です。
2. **即時完全同期の実施**:
   - J01〜J27 および K01〜K19 の全確定事項は、**本タスクにおいて直ちに `docs/ghci.md` および公式 C/Verilog ヘッダ（`include/ghci_*.h`, `include/ghci_regs.vh`）へ完全に反映・同期**されます。
   - 以後、ドライバ開発者は `docs/ghci.md` を一次情報源として参照してください。

---

<a id="k02"></a>
## K02: Page 0 レジスタ全表の確定 & CP_HEAP / WDT / WARPS / GCLK_HZ

### 質問要約
Page 0（0x000〜0x0FC）の確定オフセット、アクセス属性、リセット値、および新規追加レジスタの機能はどうなっているか。

### 確定回答
Page 0 はホスト制御・状態通知用の 4 KiB Slim MMIO 領域です。確定全表は以下のとおりです。

| オフセット | レジスタ名 | 属性 | リセット値 | 説明 |
|:---:|:---|:---:|:---:|:---|
| `0x000` | `GHCI_REG_MAGIC` | RO | `0x47484349` | マジックコード ASCII `"GHCI"` |
| `0x004` | `GHCI_REG_VERSION` | RO | `0x00010000` | バージョン 1.0 (`[31:16]=1`, `[15:0]=0`) |
| `0x008` | `GHCI_REG_DEVICE_CAPS` | RO | コンフィグ依存 | ハードウェア機能ビットマップ (K05 参照) |
| `0x00C` | `GHCI_REG_EXTCAP_PTR` | RO | `0x00000100` | EXTCAP リンクリスト先頭オフセット |
| `0x010` | `GHCI_REG_STATUS` | RO | `0x00000902` | CP および GPU 全体状態 (K03 参照) |
| `0x014` | `GHCI_REG_CTRL` | RW | `0x00000000` | CP および GPU 全体制御 (K03 参照) |
| `0x018` | `GHCI_REG_FAULT_INFO` | RO | `0x00000000` | フォールト種別・原因ユニット・セッション (K04 参照) |
| `0x01C` | `GHCI_REG_FAULT_ADDR_LO` | RO | `0x00000000` | フォールト発生アドレス下位 32 ビット |
| `0x020` | `GHCI_REG_FAULT_ADDR_HI` | RO | `0x00000000` | フォールト発生アドレス上位 32 ビット |
| `0x024` | `GHCI_REG_RING_BASE_LO` | RW | `0x00000000` | コマンドリング物理アドレス下位 32 ビット |
| `0x028` | `GHCI_REG_RING_BASE_HI` | RW | `0x00000000` | コマンドリング物理アドレス上位 32 ビット |
| `0x02C` | `GHCI_REG_RING_SIZE` | RW | `0x00000000` | コマンドリングサイズ（**バイト数**、K19 参照） |
| `0x030` | `GHCI_REG_RING_WPTR` | RW | `0x00000000` | ドアベル書込みポインタ（dword インデックス） |
| `0x034` | `GHCI_REG_RING_RPTR` | RO | `0x00000000` | CP 読出し完了ポインタ（dword インデックス） |
| `0x038` | `GHCI_REG_IRQ_STATUS` | RW1C | `0x00000000` | 割り込みステータス（1 書込みでクリア） |
| `0x03C` | `GHCI_REG_IRQ_ENABLE` | RW | `0x00000000` | 割り込みイネーブルマスク |
| `0x040` | `GHCI_REG_IRQ_SET` | WO | `0x00000000` | ソフトウェア割り込み発生（テスト用） |
| `0x044` | `GHCI_REG_SCRATCH0` | RW | `0x00000000` | 汎用スクラッチレジスタ 0 |
| `0x048` | `GHCI_REG_WDT_CYCLES` | RW | `0x00000000` | ウォッチドッグタイマ周期（0 で無効） |
| `0x04C` | `GHCI_REG_RESIDENT_WARPS` | RO | `0x00000000` | 現在実行中のアクティブワープ総数 |
| `0x050` | `GHCI_REG_CP_HEAP_BASE` | RW | `0x00000000` | 自律 MMU ウォーカー用ヒープ開始 PA |
| `0x054` | `GHCI_REG_CP_HEAP_LIMIT` | RW | `0x00000000` | 自律 MMU ウォーカー用ヒープ上限 PA（非包括） |
| `0x058` | `GHCI_REG_SESSION_ACTIVE`| RO | `0x00000000` | 有効セッションビットマスク (`bit i` = セッション i) |
| `0x05C` | `GHCI_REG_TIMESTAMP_LO` | RO | サイクル依存 | GPU 内部 64-bit タイムスタンプ下位 32 ビット |
| `0x060` | `GHCI_REG_TIMESTAMP_HI` | RO | サイクル依存 | GPU 内部 64-bit タイムスタンプ上位 32 ビット |
| `0x064` | `GHCI_REG_GCLK_HZ` | RO | クロック依存 | コア動作クロック周波数（Hz単位、K06 参照） |
| `0x080` | `GHCI_REG_EXT_CAP_FMT0` | RO | コンフィグ依存 | フォーマット高速参照ミラー 0 |
| `0x084` | `GHCI_REG_EXT_CAP_FEATURE`| RO | コンフィグ依存 | 拡張機能高速参照ミラー（VA_BITS, PA_BITS等） |

※ `0x100` 以降は拡張ケーパビリティ（EXTCAP）リンクリストが開始します。

---

<a id="k03"></a>
## K03: STATUS / CTRL / CP_STATE / セッション vs 全体 FAULTED 挙動

### 質問要約
`CTRL`、`STATUS`、`CP_STATE` の詳細ビット割当と、個別セッションフォールト時と装置全体フォールト時のハードウェアの振る舞いの違いはどうなるか。

### 確定回答
1. **`GHCI_REG_CTRL` (`0x014`)**:
   - `bit 0`: `RESET` — 1 で CP およびコアロジックをリセット
   - `bit 1`: `RUN` — 1 でリングバッファフェッチ・実行を開始
   - `bit 2`: `HALT` — 1 で現在パケット完了後に一時停止
   - `bit 3`: `STEP` — 1 で 1 パケット実行後に一時停止
   - `bit 4`: `TLB_FLUSH` — 1 で CP 内部 TLB を全無効化
   - `bit 5`: `WDT_EN` — 1 でウォッチドッグタイマを有効化
   - `bit 6`: `IRQ_GLOBAL` — 1 で割り込み出力を許可
2. **`GHCI_REG_STATUS` (`0x010`)**:
   - `bit 0`: `RUNNING` — CP 稼働中
   - `bit 1`: `HALTED` — CP 一時停止中
   - `bit 2`: `FAULTED` — GPU 全体障害発生（全停止）
   - `bit 8`: `MC_IDLE` — メモリコントローラアイドル
   - `bit 11`: `RING_EMPTY` — コマンドリング空 (`WPTR == RPTR`)
   - `bit 12`: `MEM_READY` — AXI / DDR メモリ準備完了
   - `bit 13`: `AXI_STUCK` — AXI バス応答タイムアウト
   - `bit 14`: `QUIESCE` — 全実行ユニット完全停止
   - `bits [19:16]`: `CP_STATE`:
     - `0`: `IDLE` (待機)
     - `1`: `FETCH` (コマンド取得)
     - `2`: `DECODE` (デコード)
     - `3`: `EXEC` (実行ディスパッチ)
     - `4`: `WAIT_FENCE` (フェンス待機)
     - `5`: `WAIT_MEM` (メモリ応答待機)
     - `6`: `BLIT` (内部 DMA 実行中)
     - `7`: `FAULT` (致命的フォールト)
3. **個別セッションフォールト vs 全体フォールト挙動**:
   - **個別セッションフォールト (`CAP_PROT=1` 有効時)**:
     - 不正コマンドやページフォールトを起こしたセッション $i$ は、`SESSION_ACTIVE[i]` が 0 にクリアされ停止（隔離）されます。
     - `FAULT_INFO` に原因が記録され、割り込みが上がります。
     - 他の健全なセッションが実行中の場合、**`STATUS.FAULTED` (bit 2) は立たず、装置全体は RUNNING を継続**します。
   - **装置全体フォールト**:
     - 全セッションが停止した場合、または CP 自身がリング破損・AXI タイムアウト（`AXI_STUCK`）等の致命的エラーを検知した場合にのみ、`STATUS.FAULTED` (bit 2) が立ち、`CP_STATE = 7 (FAULT)` へ遷移して全停止します。

---

<a id="k04"></a>
## K04: FAULT_INFO レジスタレイアウトと kind 番号定義

### 質問要約
`FAULT_INFO` レジスタ（0x018）のビットフィールド配置と、フォールト種別コード（KIND）およびユニット番号（UNIT）の確定値はどうなるか。

### 確定回答
`FAULT_INFO` は 32 ビットレジスタで、以下のフィールドで構成されます。

| ビット | フィールド | 説明 |
|:---:|:---|:---|
| `3:0` | `KIND` | フォールト原因種別コード（下表参照） |
| `7:4` | `UNIT` | フォールト発生ハードウェアユニット（下表参照） |
| `15:8` | `SESSION_ID` | フォールトを発生させたセッション番号 (0〜15) |
| `31:16`| `SYNDROME` | ユニット固有の追加エラー情報（Opcode や MMU レベル等） |

#### フォールト種別コード (`KIND`)
- `0`: `GHCI_FAULT_KIND_NONE` — フォールトなし
- `1`: `GHCI_FAULT_KIND_INVALID_OP` — 未定義または不正なコマンド Opcode
- `2`: `GHCI_FAULT_KIND_KICK_ABSENT` — 不在ユニットへのキック
- `3`: `GHCI_FAULT_KIND_BAD_REG` — パケット長不正、ヘッダー不正、または不正なレジスタアクセス
- `4`: `GHCI_FAULT_KIND_TIMEOUT` — ウォッチドッグタイマ満了（ハング検知）
- `5`: `GHCI_FAULT_KIND_FENCE_ERROR` — メモリ・フェンス応答エラー
- `6`: `GHCI_FAULT_KIND_PROT_FAULT` — セッション保護違反
- `7`: `GHCI_FAULT_KIND_LOCKED_REG` — ロック中レジスタへの書込み
- `8`: `GHCI_FAULT_KIND_MMU_OOM` — 自律 MMU テーブルヒープ枯渇 (K08 参照)
- `9`: `GHCI_FAULT_KIND_PAGE_FAULT` — 未マップページアクセス
- `10`: `GHCI_FAULT_KIND_PERM_FAULT` — メモリアクセス権限違反

#### 発生ユニットコード (`UNIT`)
- `0`: `GHCI_UNIT_CP` (Command Processor)
- `1`: `GHCI_UNIT_VF` (Vertex Fetcher)
- `2`: `GHCI_UNIT_SU` (Shader Unit)
- `3`: `GHCI_UNIT_RX` (Rasterizer / Primitive Setup)
- `4`: `GHCI_UNIT_TU` (Texture Unit)
- `5`: `GHCI_UNIT_ROP` (Render Output Unit)
- `6`: `GHCI_UNIT_BLT` (Blitter / DMA Engine)

---

<a id="k05"></a>
## K05: DEVICE_CAPS レジスタ全 32 ビット確定割当（新機能追加）

### 質問要約
`DEVICE_CAPS` レジスタ（0x008）の全 32 ビット割当はどうなっているか。新機能（メッシュシェーダや MSAA 等）のビット位置はどう定義されるか。

### 確定回答
`include/ghci_regs.h` および `include/ghci_cmd.h` に完全準拠した全 32 ビット確定定義は以下のとおりです。

| ビット | マクロ名 | 説明 |
|:---:|:---|:---|
| `0` | `GHCI_CAP_UMA` | 1 = 統合メモリアーキテクチャ（CPU/GPU 物理共有） |
| `1` | `GHCI_CAP_IOMMU` | 1 = ホスト IOMMU / DMA マッピング必須 |
| `2` | `GHCI_CAP_HW_WALKER` | 1 = ハードウェア自律ページテーブルウォーカー搭載 |
| `3` | `GHCI_CAP_INDIRECT_DRAW` | 1 = `CMD_DRAW_INDIRECT` サポート |
| `4` | `GHCI_CAP_SECONDARY_RING`| 1 = `CMD_EXECUTE_COMMANDS` サポート |
| `5` | `GHCI_CAP_DUAL_SOURCE` | 1 = デュアルソースブレンディング対応 |
| `6` | `GHCI_CAP_FP16` | 1 = ハーフプレシジョン (FP16) 演算サポート |
| `7` | `GHCI_CAP_GSI1` | 1 = GSI1 シェーダ ISA コア搭載 |
| `15:8`| `GHCI_CAP_PHYS_LANES` | 物理 SIMD レーン数（通常 8） |
| `23:16`| `GHCI_CAP_NUM_SU` | 搭載シェーダユニット数 (1〜4) |
| `24` | `GHCI_CAP_PROT` | 1 = マルチセッションメモリ保護機構有効 |
| `25` | `GHCI_CAP_TEX_FFILT` | 1 = テクスチャバイリニアハードウェアフィルタ搭載 |
| `26` | `GHCI_CAP_ROP_PACK` | 1 = ROP パッキング・高速クリアユニット搭載 |
| `27` | `GHCI_CAP_TASK_SHADER` | 1 = タスクシェーダハードウェアサポート |
| `28` | `GHCI_CAP_MESH_SHADER` | 1 = メッシュシェーダ（Meshlet Export）ハードウェアサポート |
| `29` | `GHCI_CAP_BLT` | 1 = ハードウェア Blitter 搭載 |
| `30` | `GHCI_CAP_DISP` | 1 = ディスプレイコントローラ（CRTC）搭載 |
| `31` | `GHCI_CAP_MSAA` | 1 = マルチサンプルアンチエイリアシングハードウェアサポート |

---

<a id="k06"></a>
## K06: GCLK_HZ / timestampPeriod / PCI Vendor ID / Device ID 確定値

### 質問要約
タイムスタンプ周期の算出方法、`GCLK_HZ` レジスタの配置、および PCI Vendor ID / Device ID の確定値はどうなるか。

### 確定回答
1. **`GCLK_HZ` レジスタ (`0x064`, RO)**:
   - GPU コアクロックの動作周波数（Hz 単位、整数値）が格納されています。
   - 例: Kintex-7 KC705 FPGA 実機コンフィグ（100 MHz）では `0x05F5E100` (100,000,000)。
2. **Vulkan `timestampPeriod` の算出**:
   - Vulkan 物理デバイスプロパティ `VkPhysicalDeviceLimits::timestampPeriod`（ナノ秒単位）は、以下のように算出します：
     $$\text{timestampPeriod} = \frac{1\,000\,000\,000}{\text{GCLK\_HZ}} \quad (\text{ns})$$
   - 100 MHz 動作時は厳密に $10.0$ ns となります。
3. **PCI Vendor ID / Device ID**:
   - **Xilinx KC705 PCIe Gen2 エンドポイント**:
     - `Vendor ID`: `0x10EE` (Xilinx Inc.)
     - `Device ID`: `0x7024` (KC705 Base TRD / PCIe Endpoint)
     - `Subsystem Vendor ID`: `0x10EE`, `Subsystem Device ID`: `0x0007`
   - **Amaterrace 専用 PCI ID（ASIC / エミュレータ時）**:
     - `Vendor ID`: `0x5441` (ASCII `"AT"`)
     - `Device ID`: `0x4748` (ASCII `"GH"`)
   - 補助情報として、EXTCAP リンクリスト内の VEND ブロック（`0x140` / `0x1C0`）に FourCC 文字列 `"AMAT"` が格納されます。

---

<a id="k07"></a>
## K07: VA / PA アドレス幅レジスタ & 2段/3段ページテーブル構成

### 質問要約
可変仮想アドレス（VA）および物理アドレス（PA）の幅を判定するレジスタと、多段ページテーブルの段数・走査仕様はどう定義されるか。

### 確定回答
> [!IMPORTANT]
> **MMU 自律管理とドライバ透過性の原則**:
> MMU の多段ページテーブル構造、PTE 生成、および TLB は GPU 内部（CP 自律ウォーカーおよびファームウェア）の自律機構であり、**ドライバ側にはコンテキスト保護（セッション分離、`CMD_VM_MAP`/`CMD_VM_UNMAP`、`BUFFER_GRANT`）以外一切見えない自律仕様**です。ドライバが PTE やルートテーブルアドレスを直接構築・操作することは一切ありません。

1. **アドレス幅の取得**:
   - `GHCI_REG_EXT_CAP_FEATURE` (`0x084`) レジスタを参照します：
     - `bits [3:0]`: `VA_BITS` (有効値: 32〜40)
     - `bits [7:4]`: `PA_BITS` (有効値: 40〜48)
2. **多段ページテーブル構造 (GPU 内部自律管理、4 KiB ページ、64-bit PTE)**:
   - ドライバは直接参照・構築せず、`CMD_VM_MAP` / `CMD_VM_UNMAP` を通じて CP にマッピングを指示します。内部的には以下の階層で自律割り当てされます：
   - **`VA_BITS = 32` の場合 (2 段テーブル)**:
     - Level 1 ページディレクトリ: 11 ビット (`VA[31:21]`, 2048 エントリ = 16 KiB)
     - Level 0 ページテーブル: 9 ビット (`VA[20:12]`, 512 エントリ = 4 KiB)
     - ページオフセット: 12 ビット (`VA[11:0]`)
   - **`VA_BITS = 40` の場合 (3 段テーブル)**:
     - Level 2 ページディレクトリ: 10 ビット (`VA[39:30]`, 1024 エントリ = 8 KiB)
     - Level 1 ページディレクトリ: 9 ビット (`VA[29:21]`, 512 エントリ = 4 KiB)
     - Level 0 ページテーブル: 9 ビット (`VA[20:12]`, 512 エントリ = 4 KiB)
     - ページオフセット: 12 ビット (`VA[11:0]`)
3. **`CMD_VM_MAP` におけるアドレス指定**:
   - `VA_BITS > 32` の場合、`gpu_va_hi` に `VA[39:32]` を格納します。
   - `va[63:VA_BITS]` は常に 0（Canonical アドレス）でなければなりません。

---

<a id="k08"></a>
## K08: MMU_OOM エラー復旧とハードウェアリセット後の状態

### 質問要約
MMU ヒープ不足（`MMU_OOM`）が発生した際のハードウェア挙動と、`CTRL.RESET` によるリセットを行った場合にホスト側メモリリソースが保持されるか。

### 確定回答
> [!IMPORTANT]
> **MMU 自律管理とドライバ透過性**:
> ページテーブル領域は CP の `CP_HEAP` から自律確保・管理されます。ドライバは多段ページテーブルの物理配置やエントリ管理を一切行う必要がなく、コンテキスト保護情報（`CMD_VM_MAP`/`UNMAP`、セッション分離、`BUFFER_GRANT`）のみを指示します。

1. **`MMU_OOM` 時の挙動と自動ロールバック**:
   - `CMD_VM_MAP` の実行中、自律テーブルウォーカーが中間ページテーブルを新規確保しようとして `CP_HEAP_LIMIT` を超過した場合、`GHCI_FAULT_KIND_MMU_OOM` (KIND=8) を発報します。
   - MMU ウォーカーは**途中まで作成・変更したエントリを直ちに自動ロールバック（アンマップ）**し、不完全な PTE を一切残しません。
   - フォールトしたセッションのみが停止（HALT）し、他セッションおよび GPU 全体は影響を受けません。
2. **ハードウェアリセット (`CTRL.RESET = 1`) 後の状態**:
   - `CTRL.RESET` は CP 内部ステートマシン、FIFO、およびキャッシュ（L1/L2 TLB、テクスチャキャッシュ）のみをゼロ初期化します。
   - **ホスト RAM 上のセッション保護テーブル、コマンドリング、アセットメモリは一切変更・破壊されません**。
   - ドライバは `CP_HEAP_LIMIT` を拡大した後に、セッションを再初期化して直ちにマッピングを再試行できます。

---

<a id="k09"></a>
## K09: CMD_FENCE (6 dw) & CMD_WAIT_FENCE (5 dw) 符号付き比較

### 質問要約
`CMD_FENCE` および `CMD_WAIT_FENCE` の dword サイズとペイロード構造、およびフェンス比較時の折り返し考慮式はどうなるか。

### 確定回答
1. **`CMD_FENCE` (Opcode `0x33`, 6 dwords / 24 バイト)**:
   - `dw0`: ヘッダー (`opcode=0x33, length=5`)
   - `dw1`: `fence_addr_lo` (書き込み先 64-bit 物理/IOVA アドレス下位)
   - `dw2`: `fence_addr_hi` (書き込み先 64-bit 物理/IOVA アドレス上位)
   - `dw3`: `seq_lo` (書き込む 64-bit シーケンス番号下位)
   - `dw4`: `seq_hi` (書き込む 64-bit シーケンス番号上位)
   - `dw5`: `flags` (`bit 0`: IRQ 発行, `bit 1`: キャッシュフラッシュ完了待ち)
2. **`CMD_WAIT_FENCE` (Opcode `0x37`, 5 dwords / 20 バイト)**:
   - `dw0`: ヘッダー (`opcode=0x37, length=4`)
   - `dw1`: `fence_addr_lo` (ポーリング監視先 64-bit 物理/IOVA アドレス下位)
   - `dw2`: `fence_addr_hi` (ポーリング監視先 64-bit 物理/IOVA アドレス上位)
   - `dw3`: `wait_val_lo` (待機しきい値 64-bit シーケンス下位)
   - `dw4`: `wait_val_hi` (待機しきい値 64-bit シーケンス上位)
3. **符号付き比較条件式**:
   - CP は以下の 64-bit 符号付き比較を用いてフェンス通過を判定します：
     $$\text{(int64\_t)}(\text{current\_seq} - \text{wait\_seq}) \ge 0$$
   - これにより、64 ビット整数のオーバーフロー・折り返しが発生した場合でも、順序関係が正しく判定され、デッドロックや誤通過を完全に防止します。

---

<a id="k10"></a>
## K10: CMD_DRAW_INDIRECT (7 dw / 8 dw カウントバッファ対応)

### 質問要約
`CMD_DRAW_INDIRECT` における動的カウントバッファ（Count Buffer）指定時のパケット長とペイロード構造はどうなるか。

### 確定回答
`CMD_DRAW_INDIRECT` (Opcode `0x29`) は、フラグ指定によって 7 dwords または 8 dwords の可変構造を持ちます。

1. **通常描画 (7 dwords)**:
   - `dw0`: ヘッダー (`opcode=0x29, length=6`)
   - `dw1-2`: `buffer_va` (64-bit 間接引数バッファ VA)
   - `dw3`: `offset` (バッファ内バイトオフセット)
   - `dw4`: `drawCount` (直接指定された描画回数)
   - `dw5`: `stride` (各 `VkDrawIndirectCommand` 構造体間ストライド、バイト単位)
   - `dw6`: `flags` (`bit 0`: Indexed 描画, `bit 1 = 0`: カウントバッファなし)
2. **カウントバッファ付き描画 (8 dwords)**:
   - `flags` の `bit 1` (`GHCI_DRAW_INDIRECT_FLAG_COUNT_BUFFER`) が 1 の場合：
   - `dw0`: ヘッダー (`opcode=0x29, length=7`)
   - `dw1-2`: `buffer_va` (64-bit 間接引数バッファ VA)
   - `dw3`: `offset` (バッファ内バイトオフセット)
   - `dw4`: `maxDrawCount` (最大描画上限回数)
   - `dw5`: `stride` (構造体ストライド)
   - `dw6-7`: `count_buffer_va` (64-bit カウントバッファ VA)
   - ハードウェアは `count_buffer_va` から 32-bit 値を読み出し、$\min(*\text{count\_buffer\_va}, \text{maxDrawCount})$ 回の描画を実行します。

---

<a id="k11"></a>
## K11: 128 バイト PSO 内 16 頂点属性の高密度パッキングレイアウト

### 質問要約
128 バイトの不変パイプラインステートオブジェクト（`GhciPipelineState`）において、Vulkan 1.0 必須要件である 16 個の頂点属性をどのように 64 バイトの属性領域に格納するか。

### 確定回答
PSO の `0x40`〜`0x7F`（64 バイト）を 16 分割し、**1 属性あたり厳密に 4 バイト（32 ビット）** で以下のビットフィールドに従って高密度パッキングします。

```
 31                                 13 12 11        8 7              0
+-------------------------------------+--+-----------+----------------+
|       offset (19 bits, 0..524287)   |R |binding(4b)|  format (8 bits)|
+-------------------------------------+--+-----------+----------------+
```

| ビット | フィールド名 | 幅 | 説明 |
|:---:|:---|:---:|:---|
| `7:0` | `format` | 8 | 頂点フォーマットコード (VkFormat 互換) |
| `11:8` | `binding` | 4 | 頂点バッファバインディングインデックス (0〜15) |
| `12` | `input_rate` | 1 | 入力レート (`0`: Per-Vertex, `1`: Per-Instance) |
| `31:13`| `offset` | 19| バッファ内バイトオフセット (0〜524,287 バイト = 512 KiB) |

- **C言語マクロ定義**:
  ```c
  #define GHCI_MAKE_VERTEX_ATTR(fmt, bind, rate, off) \
      (((uint32_t)(fmt) & 0xFFu) | \
      (((uint32_t)(bind) & 0x0Fu) << 8) | \
      (((uint32_t)(rate) & 0x01u) << 12) | \
      (((uint32_t)(off) & 0x7FFFFu) << 13))
  ```
- これにより、追加の外部間接テーブルを必要とせず、128 バイト PSO 内部だけで Vulkan 1.0 の 16 頂点入力属性仕様を完全充足します。

---

<a id="k12"></a>
## K12: CMD_BEGIN_RENDER_PASS (10 dw) と GhciRenderPassDesc (64B)

### 質問要約
レンダーパス開始コマンド `CMD_BEGIN_RENDER_PASS` のペイロード構成と、外部メモリ上のレンダーパス記述子 `GhciRenderPassDesc` の構造はどうなるか。

### 確定回答
1. **`CMD_BEGIN_RENDER_PASS` (Opcode `0x21`, 10 dwords / 40 バイト)**:
   - `dw0`: ヘッダー (`opcode=0x21, length=9`)
   - `dw1-2`: `render_pass_desc_va` (64-bit 外部レンダーパス記述子 VA)
   - `dw3`: `framebuffer_width` (ピクセル幅)
   - `dw4`: `framebuffer_height` (ピクセル高さ)
   - `dw5`: `layers` (レイヤー数)
   - `dw6`: `render_area_offset_xy` (`[15:0] x`, `[31:16] y`)
   - `dw7`: `render_area_extent_wh` (`[15:0] width`, `[31:16] height`)
   - `dw8`: `clear_flags` (各アタッチメントのクリア実行ビットマスク)
   - `dw9`: `reserved`
2. **`GhciRenderPassDesc` 構造体 (64 バイト)**:
   - メモリ上の 64 バイト整列構造体であり、最大 8 個の Color Attachment と 1 個の Depth/Stencil Attachment を指定します：
     - `dw0..15`: 8 個のカラーアタッチメント記述子（各 64-bit VA + フォーマット・ピッチ等）
     - `dw16..19`: デプス／ステンシルアタッチメント記述子
     - `dw20..31`: 各アタッチメントのクリアカラー値およびクリアデプス値

---

<a id="k13"></a>
## K13: Combined Image Sampler 確定仕様（Option A: 32-bit インデックスペア）

### 質問要約
テクスチャとサンプラを結合して扱う Combined Image Sampler のハードウェア仕様は、32-bit インデックスペア（Option A）と 64-bit ディスクリプタ（Option B）のどちらに確定したか。

### 確定回答
**Option A（32-bit インデックスペア）に一本化・確定**しました。

1. **データ構造**:
   ```c
   typedef struct {
       uint16_t texture_index; // テクスチャ記述子インデックス (0〜65535)
       uint16_t sampler_index; // サンプラ記述子インデックス (0〜65535)
   } GhciCombinedImageSampler;
   ```
2. **シェーダ ISA 命令との連携**:
   - シェーダプログラムは、1 本の 32-bit SGPR またはプッシュ定数から Combined Image Sampler を取得します。
   - ハードウェア Texture Unit (TU) は、下位 16 ビットでテクスチャヘッダーを、上位 16 ビットでサンプラステートを独立キャッシュから並列フェッチし、高効率にサンプリングを実行します。
   - これにより、ディスクリプタメモリの消費を半減させ、不要な間接参照を完全に排除します。

---

<a id="k14"></a>
## K14: 全 15 コマンド確定 dword ペイロードレイアウト一覧

### 質問要約
GHCI 1.0 でサポートされる全 15 個のコマンドの opcode、名称、dword 長、およびペイロード構造の確定一覧はどうなるか。

### 確定回答
全 15 コマンドの完全なバイナリ仕様は以下のとおりです。

| Opcode | コマンド名 | 長さ (dw) | ペイロード要約 |
|:---:|:---|:---:|:---|
| `0x00` | `CMD_NOP` | 1+N | `dw0`: ヘッダー (`length=N`), `dw1..N`: 任意データ |
| `0x20` | `CMD_BIND_PIPELINE` | 3 | `dw0`: ヘッダー, `dw1-2`: 64-bit PSO 仮想アドレス |
| `0x21` | `CMD_BEGIN_RENDER_PASS`| 10 | `dw0`: ヘッダー, `dw1-2`: 64-bit RenderPassDesc VA, `dw3-7`: 領域, `dw8`: クリアフラグ |
| `0x22` | `CMD_END_RENDER_PASS` | 1 | `dw0`: ヘッダー |
| `0x23` | `CMD_SET_VIEWPORT` | 5 | `dw0`: ヘッダー, `dw1`: x (FP32), `dw2`: y (FP32), `dw3`: width, `dw4`: height |
| `0x24` | `CMD_SET_SCISSOR` | 3 | `dw0`: ヘッダー, `dw1`: `[15:0] x`, `[31:16] y`, `dw2`: `[15:0] w`, `[31:16] h` |
| `0x25` | `CMD_BIND_VERTEX_BUFFER`| 5 | `dw0`: ヘッダー, `dw1`: binding_idx, `dw2-3`: 64-bit buffer VA, `dw4`: stride |
| `0x26` | `CMD_BIND_INDEX_BUFFER` | 4 | `dw0`: ヘッダー, `dw1-2`: 64-bit buffer VA, `dw3`: index_type (0: U16, 1: U32) |
| `0x27` | `CMD_DRAW` | 5 | `dw0`: ヘッダー, `dw1`: vertexCount, `dw2`: instanceCount, `dw3`: firstVertex, `dw4`: firstInstance |
| `0x28` | `CMD_DRAW_INDEXED` | 6 | `dw0`: ヘッダー, `dw1`: indexCount, `dw2`: instanceCount, `dw3`: firstIndex, `dw4`: vertexOffset, `dw5`: firstInstance |
| `0x29` | `CMD_DRAW_INDIRECT` | 7 / 8 | `dw0`: ヘッダー, `dw1-2`: buffer VA, `dw3`: offset, `dw4`: count, `dw5`: stride, `dw6`: flags, (`dw6-7`: count_buffer_va) |
| `0x2A` | `CMD_DISPATCH` | 4 | `dw0`: ヘッダー, `dw1`: groupCountX, `dw2`: groupCountY, `dw3`: groupCountZ |
| `0x30` | `CMD_BARRIER` | 4 | `dw0`: ヘッダー, `dw1`: src_stage_mask, `dw2`: dst_stage_mask, `dw3`: flags (L2, L1, TLB, Drain) |
| `0x31` | `CMD_WAIT_IDLE` | 1 | `dw0`: ヘッダー |
| `0x32` | `CMD_EXECUTE_COMMANDS` | 4 | `dw0`: ヘッダー, `dw1-2`: 64-bit セカンダリバッファ VA, `dw3`: dword_count |
| `0x33` | `CMD_FENCE` | 6 | `dw0`: ヘッダー, `dw1-2`: 64-bit host/GPU addr, `dw3-4`: 64-bit seq, `dw5`: flags |
| `0x35` | `CMD_VM_MAP` | 6 | `dw0`: ヘッダー, `dw1-2`: 64-bit VA, `dw3-4`: 64-bit PA, `dw5`: page_count + flags |
| `0x36` | `CMD_BIND_SESSION` | 2 | `dw0`: ヘッダー, `dw1`: session_id (0〜15) |
| `0x37` | `CMD_WAIT_FENCE` | 5 | `dw0`: ヘッダー, `dw1-2`: 64-bit host/GPU addr, `dw3-4`: 64-bit wait_value |

---

<a id="k15"></a>
## K15: Vulkan 1.0 必須制限値・物理デバイスリミット・47 必須フォーマット

### 質問要約
Vulkan 1.0 適合に必要な物理デバイス制限値（特に `maxComputeSharedMemorySize`）と、必須 47 フォーマットの確定一覧はどうなるか。

### 確定回答
1. **`maxComputeSharedMemorySize` の確定値**:
   - **通常コンフィグ**: **`16384` バイト (16 KiB)** です。シェーダユニット（SU）のローカルデータシェア（LDS）メモリは 16 KiB 搭載されています。
   - KC705 FPGA 最小リソース構成時のみ `4096` バイト (4 KiB) となります。
2. **主要な物理デバイスリミット確定値**:
   - `maxImageDimension2D`: 4096
   - `maxImageDimension3D`: 1024
   - `maxColorAttachments`: 8
   - `maxVertexInputAttributes`: 16 (K11 参照)
   - `maxVertexInputBindings`: 16
   - `maxComputeWorkGroupInvocations`: 256
   - `maxComputeWorkGroupSize`: `(256, 256, 64)`
3. **47 個の必須 VkFormat 一覧**:
   - `docs/ghci.md` §8.5.1 に掲載されている 47 個のフォーマット（R8, RG8, RGBA8, BGRA8, R16, RG16, RGBA16, R32F, RG32F, RGBA32F, D16_UNORM, D32_SFLOAT, D24_UNORM_S8_UINT 等）が公式かつ唯一のサポートフォーマット表です。

---

<a id="k16"></a>
## K16: セカンダリコマンドバッファの呼び出し階層（厳格 1 階層制限）

### 質問要約
`CMD_EXECUTE_COMMANDS` を用いたセカンダリコマンドバッファの呼び出しにおいて、ネスト（入れ子）の深さの仕様はどう確定されたか。

### 確定回答
**厳格に 1 階層のみ（ネスト禁止）** と決定されました。

1. **仕様規約**:
   - プライマリリングバッファから `CMD_EXECUTE_COMMANDS` を発行してセカンダリバッファを実行することは完全にサポートされます。
   - セカンダリコマンドバッファ内からさらに別の `CMD_EXECUTE_COMMANDS` を呼び出すことは**禁止**されています。
2. **ハードウェア保護**:
   - CP がセカンダリバッファの実行中に `CMD_EXECUTE_COMMANDS` を検出した場合、即座に実行を中断し、`FAULT_INFO` に `KIND = GHCI_FAULT_BAD_PROGRAM` (7)、`UNIT = GHCI_UNIT_CP` (0) を記録してフォールトを発生させます。
3. **規格適合性**:
   - Vulkan 1.0 仕様（`vkCmdExecuteCommands`）において、セカンダリコマンドバッファから別のセカンダリコマンドバッファを呼び出すことは元より禁止（VUID-vkCmdExecuteCommands-contents-00108）されており、この 1 階層制限は Vulkan 規格に 100% 整合します。

---

<a id="k17"></a>
## K17: CMD_BARRIER (4 dw) パイプラインステージ・フラグ詳細定義

### 質問要約
パイプラインバリアコマンド `CMD_BARRIER` の dword 構成と、ステージマスク・キャッシュフラグのビット定義はどうなるか。

### 確定回答
`CMD_BARRIER` (Opcode `0x30`) は 4 dwords (16 バイト) で構成されます。

1. **バイナリレイアウト**:
   - `dw0`: ヘッダー (`opcode=0x30, length=3`)
   - `dw1`: `src_stage_mask` (先行完了を待つパイプラインステージビットマスク)
   - `dw2`: `dst_stage_mask` (後続ブロックするパイプラインステージビットマスク)
   - `dw3`: `flags` (キャッシュ操作および同期フラグ)
2. **ステージビットマスク (`src_stage_mask` / `dst_stage_mask`)**:
   - `bit 0`: `TOP_OF_PIPE`
   - `bit 1`: `DRAW_INDIRECT`
   - `bit 2`: `VERTEX_INPUT`
   - `bit 3`: `VERTEX_SHADER`
   - `bit 4`: `FRAGMENT_SHADER`
   - `bit 5`: `EARLY_FRAGMENT_TESTS`
   - `bit 6`: `LATE_FRAGMENT_TESTS`
   - `bit 7`: `COLOR_ATTACHMENT_OUTPUT`
   - `bit 8`: `COMPUTE_SHADER`
   - `bit 9`: `TRANSFER`
   - `bit 10`: `BOTTOM_OF_PIPE`
3. **同期フラグ (`flags`)**:
   - `bit 0`: `GHCI_BARRIER_FLUSH_L2` — L2 キャッシュ全ラインをメインメモリへ掃き出し
   - `bit 1`: `GHCI_BARRIER_INVAL_L1` — L1 データ/テクスチャ/命令キャッシュを全無効化
   - `bit 2`: 予約（旧 `GHCI_BARRIER_INVAL_TLB` 撤廃: TLB 無効化は `CMD_VM_UNMAP` 実行時やセッション切替時に CP が自動実行するためドライバからの手動操作は不要）
   - `bit 3`: `GHCI_BARRIER_DRAIN` — 全実行パイプラインが完全に空（Drain）になるまでストール

> [!NOTE]
> **MMU 自律性とドライバ透過性**:
> TLB の無効化や多段ページテーブルの更新は、`CMD_VM_UNMAP` 実行時やセッション切替時に CP が自動的にパイプラインをドレインしてアトミックに実行します。ドライバ側にはコンテキスト保護情報（セッション分離、`CMD_VM_MAP`/`UNMAP`、`BUFFER_GRANT`）以外一切見えず、手動での TLB 操作や PTE 操作は不要です。

---

<a id="k18"></a>
## K18: GSI1 シェーダ ISA 機能ビットと MMIO 読み出しレジスタ

### 質問要約
GSI1 シェーダ ISA のサポート機能および実行状態をドライバ側から確認するための MMIO レジスタはどれか。

### 確定回答
ドライバは以下の 3 つの MMIO レジスタを参照して GSI1 コアの能力と状態を取得します。

1. **`GHCI_REG_DEVICE_CAPS` (`0x008`)**:
   - `bit 7` (`GHCI_CAP_GSI1`): 1 であれば GSI1 シェーダ ISA コアが有効。
   - `bits [15:8]` (`PHYS_LANES`): 物理 SIMD レーン数（通常 8）。
   - `bits [23:16]` (`NUM_SU`): シェーダユニット（SU）搭載数（1〜4）。
   - `bit 27`: タスクシェーダ対応、`bit 28`: メッシュシェーダ対応。
2. **`GHCI_REG_EXT_CAP_FEATURE` (`0x084`)**:
   - 拡張機能高速ミラー。シェーダ ISA の追加拡張（FP16 演算、直交アドレッシング等）の有無を即座に参照可能。
3. **`GHCI_REG_RESIDENT_WARPS` (`0x04C`)**:
   - 現在 GPU 内部の全 SU で並行実行中のアクティブワープ総数（0〜最大ワープ数）。プロファイリングやロードバランシングの監視に使用可能。

---

<a id="k19"></a>
## K19: RING_SIZE バイト数定義とリングバッファ折り返し規則

### 質問要約
`GHCI_REG_RING_SIZE` に設定する単位（バイトか dword か）と、リングバッファ末尾でパケットが溢れる際の正確な折り返し規則はどうなるか。

### 確定回答
1. **`RING_SIZE` は「バイト数」**:
   - `GHCI_REG_RING_SIZE` (`0x02C`) には、コマンドリング全体のメモリサイズを**バイト単位**（4 KiB アライメント必須、例: 64 KiB なら `0x00010000`）で書き込みます。
2. **ポインタ折り返し動作**:
   - CP はリングバッファの容量を dword 数 $\text{MaxWords} = \text{RING\_SIZE} / 4$ として管理します。
   - `RING_WPTR` および `RING_RPTR` は **dword 単位のインデックス** です。
   - ポインタが $\text{MaxWords}$ に達した際、直ちにインデックス `0` に折り返します。
3. **パケットの境界跨ぎ禁止規則**:
   - **1 つのコマンドパケットがリングバッファの末尾境界（$\text{MaxWords}$）を跨いで分割配置されることは厳格に禁止**されています。
   - ドライバが新しいコマンドパケットを投入する際、末尾の残りスロット数がそのコマンドのパケット長（dword 数）未満である場合、ドライバは**残余スロットをすべて `CMD_NOP`（Opcode `0x00`）で埋め**、対象のコマンドパケットをリング先頭（インデックス `0`）から配置しなければなりません。
   - CP はこのパディング `CMD_NOP` を消費後、自動的にインデックス 0 へジャンプして後続パケットの実行を継続します。

---

## 結び

以上の仕様は、Amaterrace GPU のハードウェア（Verilog RTL: `rtl/gpu/cp/`, `rtl/library/bus/`）、公式ヘッダ（`include/ghci_*.h`, `include/ghci_regs.vh`）、および検証テストベンチ群によって完全な動作整合性が確認された確定仕様です。
ドライバ開発者は本回答書に記載されたレイアウトおよびプロトコルに厳格に準拠して実装を進めてください。
