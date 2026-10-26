# am_mul

RTL: `rtl/library/arith/am_mul.v`. Written for the shared arithmetic (docs/style.md, "Arithmetic", 2026-10-25).

## 1. Purpose and place

An AW x BW multiplier for DSP48E1 slices: `p = a * b`, both signed (`SIGNED = 1`, two's complement) or both unsigned, the full AW + BW bits.
- In generic / simulation mode (`ifndef SYNTH_KINTEX7`), written with standard Verilog `*` and pipeline registers.
- Under `SYNTH_KINTEX7`, fully implemented using `DSP48E1` primitive instantiations and dedicated `PCOUT -> PCIN` cascade across all operand widths (8x8 up to 42x42). Fabric adders and `*` inference are completely eliminated.

## 2. Parameters

- `AW` (18): input `a` bit width.
- `BW` (18): input `b` bit width.
- `SIGNED` (0): 1 if signed, 0 if unsigned.
- `LAT` (0): pipeline latency (0 to 3 cycles).

## 3. Ports

- `clk`: clock
- `en`: stage enable
- `a` [AW-1:0]: operand a
- `b` [BW-1:0]: operand b
- `p` [AW+BW-1:0]: product output

## 4. Behaviour

`p = a * b` after `LAT` cycles enabled by `en`.
In both generic mode and `SYNTH_KINTEX7` DSP48E1 cascade mode, behavior is bit- and cycle-identical across all valid configurations.

### DSP48E1 Cascade Architecture (`SYNTH_KINTEX7`)

1. **Operand Normalization & Swap**:
   - `MAX_A = SIGNED ? 25 : 24`, `MAX_B = SIGNED ? 18 : 17`.
   - Automatic operand swapping assigns the operand fitting in fewer tiles to `X` (A-port) and the other to `Y` (B-port).
2. **Tiling**:
   - `NX = (XW <= MAX_A) ? 1 : ((XW + 16) / 17)`
   - `NY = (YW <= MAX_B) ? 1 : ((YW + 16) / 17)`
   - Total DSP slices: `NX * NY` (1 to 9 slices).
3. **Weight Chain (`PCOUT -> PCIN`)**:
   - DSPs are chained along weight indices $k = i + j$.
   - Head DSP: `OPMODE = 7'b0000101` ($P = M$).
   - First DSP of weight $k > 0$: `OPMODE = 7'b1010101` ($P = (PCIN \gg 17) + M$).
   - Intra-weight DSPs: `OPMODE = 7'b0010101` ($P = PCIN + M$).
   - Output slices $p[17k +: 17]$ are extracted from the final DSP of each weight $k$.
4. **Latency (`LAT = 0..3`)**:
   - Utilizes internal `AREG`, `BREG`, `MREG`, and `PREG` registers according to cascade configuration to maximize timing margins.

## 5. Latency and throughput

Throughput is 1 operation per cycle. Latency is `LAT` cycles.
