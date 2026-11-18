# am_afifo_bram

RTL: `rtl/library/bus/am_afifo_bram.v`.

## 1. Purpose and place

An asynchronous dual-clock FIFO inferable into dedicated FPGA Block RAM (Xilinx `RAMB18E1` / `RAMB36E1`) with zero-bubble, 0-cycle FWFT (First-Word Fall-Through) output capability.

Unlike distributed-RAM FIFOs (`am_afifo.v`) which rely on asynchronous memory reads (`assign r_data = mem[...]`) and consume thousands of LUTs for large depths, `am_afifo_bram.v` uses strictly synchronous memory reads (`always @(posedge r_clk) ram_rdata <= mem[...]`). The 1-cycle BRAM read latency is hidden from the read interface by an integrated 2-entry registered skid buffer (`am_skid.v`), allowing continuous single-cycle streaming transfers and zero latency after data reaches the output register.

Parent: Inter-clock domain large buffers (e.g., Display Controller pixel buffer, AXI/AMB CDC buffers). Children: `am_skid`.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `W` | 32 | Entry payload width in bits | ≥ 1 |
| `DEPTH_LOG2` | 11 | $\log_2$ of BRAM capacity (default 2048 words, 8 KiB) | ≥ 3 |

## 3. Ports

| Name | Dir | Width | Domain | Meaning, handshake, timing |
| --- | --- | --- | --- | --- |
| `w_clk` | in | 1 | — | Write domain clock |
| `w_rst_n` | in | 1 | `w_clk` | Synchronous active-low reset (write domain) |
| `w_valid` | in | 1 | `w_clk` | Write push valid |
| `w_ready` | out | 1 | `w_clk` | Write ready ("not full") |
| `w_data` | in | `W` | `w_clk` | Write payload data |
| `r_clk` | in | 1 | — | Read domain clock |
| `r_rst_n` | in | 1 | `r_clk` | Synchronous active-low reset (read domain) |
| `r_valid` | out | 1 | `r_clk` | Read valid ("not empty", FWFT: data is already presented) |
| `r_ready` | in | 1 | `r_clk` | Read pop request |
| `r_data` | out | `W` | `r_clk` | Read payload data (FWFT) |
| `r_count` | out | `DEPTH_LOG2+1` | `r_clk` | Synchronized total occupancy watermark in read clock domain |

## 4. Architecture and Behaviour

### Memory Storage
- Inferred as true dual-port Block RAM (`(* ram_style = "block" *)`).
- Write port clocked by `w_clk`.
- Read port clocked by `r_clk`, with synchronous read register `ram_rdata`.

### CDC Synchronization
- Binary write and read pointers of width `P = DEPTH_LOG2 + 1`.
- Converted to Gray code and passed across clock domains through two-stage flip-flop synchronizers marked with `(* ASYNC_REG = "TRUE" *)`.
- Full detection in `w_clk` compares `w_gray` against `w_rgray2` with top two bits inverted.
- Empty / data available detection in `r_clk` compares `r_gray` against `r_wgray2`.

### Skid Buffer Integration & BRAM Latency Hiding
- BRAM read address `r_bin` is incremented on `ram_ren`.
- `ram_ren` is asserted when unread data is present in BRAM (`r_gray != r_wgray2`) AND the skid buffer has room to accept incoming data.
- The space check condition:
  `fetch_space = !r_valid || r_ready || (skid_in_ready && !ram_rvalid);`
- When data emerges from the BRAM 1 cycle later (`ram_rvalid = 1`), it is received by `am_skid`.
- If downstream stalls (`r_ready = 0`), the skid buffer absorbs the in-flight data. Once full, `ram_ren` pauses without dropping data.
- When `r_ready = 1`, the FIFO sustains 1 transfer per clock cycle (100% throughput).

### Watermark (`r_count`)
- The synchronized write Gray pointer `r_wgray2` is converted back to binary (`w_bin_in_rclk`).
- Total watermark equals:
  `r_count = (w_bin_in_rclk - r_bin) + skid_entries + ram_rvalid`
- Arithmetic operations are strictly performed using `am_add` and `am_sub`.

## 5. Latency and Throughput

- **Write-to-Read CDC Latency**: Approximately 3-4 read clock cycles after write (2 cycles synchronizer + 1 cycle BRAM read + 1 cycle skid register).
- **Throughput**: 1 transfer per cycle sustained in both write and read domains.
- **FWFT Fall-Through**: 0 cycle delay when data has reached `r_data` (`r_valid = 1`).

## 6. Status

- Implemented: `rtl/library/bus/am_afifo_bram.v`.
- Unit testbench: `sim/tb/am_afifo_bram_tb.v`.
