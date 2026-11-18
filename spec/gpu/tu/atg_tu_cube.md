# atg_tu_cube

RTL: `rtl/gpu/tu/atg_tu_cube.v`.  Parent: atg_tu_addr.  Implemented in: p009 (part F).

## 1. Purpose and place

The face and the face coordinates of a cube map direction (docs/ghci.md §8.4): Vulkan's face selection and the division s_c / |m_a| done exactly, one bit a cycle.  Child: `atg_tu_cube_sc` (s_c', t_c' before the division; two instances).

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `go` | in | 1 | One cycle while !bsy: start with x, y, z, fix, fface. |
| `x` | in | 32 | The direction (fp32). |
| `y` | in | 32 | |
| `z` | in | 32 | |
| `fix` | in | 1 | 1: use fface instead of selecting the face. |
| `fface` | in | 3 | The face to use (0 +X, 1 −X, 2 +Y, 3 −Y, 4 +Z, 5 −Z). |
| `bsy` | out | 1 | Dividing (high from the cycle after go). |
| `face` | out | 3 | The face; held from bsy falling until the next go. |
| `s` | out | 27 | The face coordinate s with 24 fraction bits, signed. |
| `t` | out | 27 | t, likewise. |

12 ports.

## 4. Behaviour

Bit for bit as `tools/tumodel.py` `cube_proj`:

- A component that is zero, a denormal or NaN reads as +0; an infinity as the largest finite value of its sign.
- Face: the largest magnitude, z before y before x on ties (Vulkan's first two rules); its sign picks + or −.  With fix, fface.
- (s_c, t_c, m_a) by Vulkan's table.  With m the major axis's significand (24 bits) and e its exponent: sc' = floor(s_c × 2^(150 − e)) clamped to [−3 m, 3 m]; s = floor(2^23 (sc' + 3 m) / m) − 2^24 (in [0, 2^24] for the selected face; [−2^24, 2^25] for a fixed one); t alike.  A zero major axis gives s = t = 2^23.
- The two divisions run together (restoring, 26 quotient bits).

## 5. State machine

IDLE →(go)→ DIV (26 cycles) → IDLE.

## 6. Latency and throughput

27 cycles from go to the result (p015 can replace the division by a reciprocal and multipliers).

## 7. Corner cases and errors

- go while bsy is ignored (atg_tu_addr waits for !bsy).
- All-zero, NaN and infinite directions give defined results (above); Vulkan leaves them undefined.

## 8. What the TB checks

No unit testbench of its own: `sim/tb/atg_tu_addr_tb.v` (`PASS atg_tu_addr.cube`) checks it through atg_tu_addr; `tools/tu-vectors.py` checks the model's face coordinates against floating point.

## 9. References

docs/ghci.md §8.4; Vulkan's "Cube Map Face Selection".

## 10. Status

New in WS288 p009 part F (P3, branch p3-p009f).  Reading: an exact division (the TU has no divider; a reciprocal table would need its own model of the rounding), clamping a fixed face's ratio to [−3, 3] (only texb's derivatives use a fixed face).
