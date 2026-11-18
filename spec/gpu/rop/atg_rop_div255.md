# atg_rop_div255

RTL: `rtl/gpu/rop/atg_rop_div255.v`.  Parent: atg_rop_blend (stage 3: the blend result of each channel, and the 8-bit to 5- and 6-bit conversions).  Implemented in: p007; updated in p014.

## 1. Purpose and place

round(x / 255) for 0 ≤ x ≤ 255 × 255 (65025) using a single 17-bit adder and wiring (docs/style.md, "Arithmetic"); it replaces the legacy 5-stage carry-chain cascade of atg_rop_div255 with a single-stage adder (~0.6 ns latency).

## 2. Parameters

None.

## 3. Ports

`x` (18) / `q` (9): 2 ports.

## 4. Behaviour

Mathematical identity for 0 ≤ x ≤ 65025:
$$t = x + 128 \implies q = (t + (t \gg 8)) \gg 8$$
Since $(x + 128) \gg 8 = (x \gg 8) + x[7]$,
$$t + (t \gg 8) = x + ((x \gg 8) + 128) + x[7]$$
For $x \le 65025$, $((x \gg 8) + 128) = \{x[15], \sim x[15], x[14:8]\}$ by pure bit wiring and one inverter ($\sim x[15]$).
Thus, $q = (x + \{x[15], \sim x[15], x[14:8]\} + x[7]) \gg 8$ is evaluated in a single 17-bit `am_add` with carry-in $ci = x[7]$ and no intermediate carry chains.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational: a single 17-bit adder (`am_add #(.W(17))`), ~0.6 ns delay.

## 7. Corner cases and errors

Checked exhaustively across all $0 \le x \le 65025$ against mathematical $\lfloor (x + 127) / 255 \rfloor$ and the 5-stage reference (0 mismatches).

## 8. What the TB checks

`sim/tb/atg_rop_div255_tb.v` exhaustively checks all 65,026 inputs against the mathematical reference and the 5-stage legacy reference.

## 9. References

`spec/gpu/rop/atg_rop_blend.md`, [ws001-p014](../../plan/ws001/phase014/phase.md).

## 10. Status

Implemented and verified (amaterrace-gpu, 2026-10-26, Phase 014).
