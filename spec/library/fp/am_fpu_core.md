# am_fpu_core

RTL: `rtl/library/fp/am_fpu_core.v`. Unified single-lane floating-point / integer FPU core.

## 1. Purpose and Place

`am_fpu_core` is the integrated single-lane execution datapath for all single-precision (fp32) floating-point arithmetic, conversions, comparisons, and RISC-V M integer multiplications.

By placing an operand multiplexer in front of a single 33×33 signed multiplier (`am_mul`, mapped to 4 cascaded `DSP48E1` slices on Xilinx 7-series / Kintex-7), `am_fpu_core` shares the DSP resources between:
- Floating-point multiply and fused multiply-add family: $a \times b + c$ (`FMADD`), $a \times b - c$ (`FMSUB`), $-a \times b + c$ (`FNMSUB`), $-a \times b - c$ (`FNMADD`)
- Floating-point standard arithmetic: $a \times b$ (`FMUL`), $a \times 1.0 + b$ (`FADD`), $a \times 1.0 - b$ (`FSUB`), $x - \text{floor}(x)$ (`FRACT`)
- Integer multiplication: 32×32 signed/unsigned product (`MUL`), high-half signed/unsigned (`MULH`, `MULHSU`, `MULHU`)

This eliminates redundant DSP slice allocations across separate FADD, FMUL, and IMUL pipelines.

## 2. Supported Operations (`op[4:0]`)

| Opcode | Mnemonic | Operation | Description |
| :---: | :--- | :--- | :--- |
| `5'd0` | `FADD` | $a + b$ | Implemented as FMA: $a \times 1.0 + b$ |
| `5'd1` | `FSUB` | $a - b$ | Implemented as FMA: $a \times 1.0 - b$ |
| `5'd2` | `FMUL` | $a \times b$ | Multiplied without addend (`noc = 1`) |
| `5'd3` | `FMADD` | $a \times b + c$ | Fused Multiply-Add with single rounding |
| `5'd4` | `FMSUB` | $a \times b - c$ | Fused Multiply-Subtract |
| `5'd5` | `FNMSUB` | $-a \times b + c$ | Negated FMA ($c - a \times b$) |
| `5'd6` | `FNMADD` | $-a \times b - c$ | Negated FMA ($-(a \times b + c)$) |
| `5'd7` | `FSGNJ` | `sgnj(a, b)` | Bitwise sign injection: `{b[31], a[30:0]}` |
| `5'd8` | `FMIN` | $\min(a, b)$ | IEEE 754-2019 minimum (NaN handling, $-0 < +0$) |
| `5'd9` | `FMAX` | $\max(a, b)$ | IEEE 754-2019 maximum (NaN handling, $-0 < +0$) |
| `5'd10` | `FCVTWS` | `(int32_t)a` | Float to signed 32-bit integer |
| `5'd11` | `FCVTWUS` | `(uint32_t)a` | Float to unsigned 32-bit integer |
| `5'd12` | `FCVTSW` | `(float)a` | Signed 32-bit integer to float under `rm` |
| `5'd13` | `FCVTSWU` | `(float)(uint32_t)a` | Unsigned 32-bit integer to float under `rm` |
| `5'd14` | `FEQ` | $a == b$ | Boolean result (`32'hFFFFFFFF` or `32'd0`) |
| `5'd15` | `FLT` | $a < b$ | Boolean result |
| `5'd16` | `FLE` | $a \le b$ | Boolean result |
| `5'd17` | `FNE` | $a \ne b$ | Boolean result (unordered evaluates true) |
| `5'd18` | `FROUND` | `round(a)` | Round float to integer float value under `rm` |
| `5'd19` | `FRACT` | $a - \text{floor}(a)$ | Fractional part under RNE |
| `5'd20` | `MUL` | $(a \times b)[31:0]$ | 32-bit integer product |
| `5'd21` | `MULH` | $(a \times b)[63:32]$ | High 32 bits, signed $\times$ signed |
| `5'd22` | `MULHSU` | $(a \times b)[63:32]$ | High 32 bits, signed $\times$ unsigned |
| `5'd23` | `MULHU` | $(a \times b)[63:32]$ | High 32 bits, unsigned $\times$ unsigned |

## 3. Parameters

- `LAT` (integer, default 0): Pipeline latency from inputs to `res`. Default 0 preserves combinational lane execution for backward compatibility with `atg_su_fpu`.

## 4. Ports

- `clk`: Clock.
- `rst_n`: Asynchronous active-low reset.
- `en`: Clock enable.
- `op` [4:0]: Operation selector (see table above).
- `rm` [2:0]: IEEE 754 rounding mode (0: RNE, 1: RTZ, 2: RDN, 3: RUP, 4: RMM, 5: RNO odd, 6: RNO zero sign, 7: RNE).
- `sat`: Saturate float result to $[0.0, 1.0]$ when high (no effect on integer results or compares).
- `a` [31:0]: Operand A.
- `b` [31:0]: Operand B.
- `c` [31:0]: Operand C.
- `res` [31:0]: 32-bit result.

## 5. DSP48E1 Utilization & Arithmetic Rules

- Multiplier: single `am_mul #(.AW(33), .BW(33), .SIGNED(1))` instance = exactly 4 `DSP48E1` slices on Kintex-7.
- Signal arithmetic operators (`+`, `-`, `*`, etc.): strictly 0 outside `rtl/library/arith/`.
- All adders and sub-word logic use `am_add`, `am_sub`, `am_addsub`, and `am_shift`.
