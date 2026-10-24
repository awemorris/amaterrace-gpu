# atg_rx_cov

RTL: `rtl/gpu/rx/atg_rx_cov.v`.  Parent: atg_rx_scan.  Children: none.

## 1. Purpose and place

The sample offsets of the rasterizer's multisampling (docs/ghci.md §12.11): per edge, the change of the edge value from the pixel centre to each standard sample location, and the edges at the current quad plus a sample's offset for `atg_rx_scan`'s lane adders.

## 2. Parameters

None.

## 3. Ports

All in domain `clk` (no reset: the registers are loaded before use).

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock |
| `i_load` | in | 1 | The triangle's load: take A, B |
| `i_ab` | in | 144 | Edge e: {B, A} (signed 15.8, 24 bits each) at bits 48 e |
| `i_ec` | in | 144 | The edges at the quad (48 bits each, subpixel² units) |
| `i_start` | in | 1 | Load es with sample 0's edges |
| `i_step` | in | 1 | Load es with the next sample's (after `i_sc`) |
| `i_sc` | in | 2 | The sample of this cycle |
| `i_samp` | in | 1 | Select es on `o_eb` |
| `o_eb` | out | 144 | es while `i_samp`, else `i_ec` |
| `o_lowm` | out | 144 | Per edge, the bits below the top bit of \|P\| \| \|Q\|, set (valid the cycle after the load) |

10 ports.

## 4. Behaviour

- P = 32 A + 96 B, Q = 96 A − 32 B (shifts and adds); the offsets of samples 0..3 are −P, +Q, −Q, +P (the standard locations (0.375, 0.125), (0.875, 0.375), (0.125, 0.625), (0.625, 0.875) are (−32, −96), (96, −32), (−96, 32), (32, 96) subpixels from the centre and pair up as opposites).
- es: `i_start` → i_ec − P; `i_step` with `i_sc` = 0, 1, 2 → i_ec + Q, − Q, + P.

## 5. State machine

None.

## 6. Latency and throughput

es one cycle after `i_start`/`i_step`; `o_eb` combinational.

## 7. Corner cases and errors

- `MUT_SAMPLE_SWAP` swaps samples 1 and 2; `MUT_COV_SKIP` makes `o_lowm` too small (the TB's mutation checks).

## 8. What the TB checks

Through `sim/tb/atg_rx_scan_tb.v` (`.ms`).

## 9. References

design §15.3.  Values referenced: Vulkan specification, Multisampling, standard sample locations (VK_SAMPLE_COUNT_4_BIT).

## 10. Status

Implemented (the MSAA work).
