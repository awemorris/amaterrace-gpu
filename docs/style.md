RTL and script style
====================

The rules for this repository's Verilog, testbenches and scripts.

Verilog
-------

- Verilog-2005, the subset that Icarus Verilog (`-g2005`), Verilator
  (`--lint-only -Wall`) and Vivado all accept.  No SystemVerilog in
  `rtl/` or `boards/`.
- `timescale 1ns / 1ps` and `default_nettype none` at the top of each
  file, `default_nettype wire` at the end.
- One module per file, the file named after the module.  Prefixes:
  `atg_` for the GPU's blocks (`atg_cp`, `atg_blt`, `atg_mc`, ...), `am_`
  for shared parts (`am_fifo`, `am_afifo`, `am_axi_regs`, ...).
- Each file starts with the license header and a comment that says what
  the module does, its interfaces and their rules (who waits for whom,
  what is in order, what happens on error and under quiesce).
- ANSI port lists, one port per line, `input wire` / `output wire` /
  `output reg`.  Parameters with defaults; a parameter derived from
  another (`LINE_SHIFT = log2(LINE_BYTES)`) is passed explicitly.
- Synchronous resets, active low (`rst_n`), on every register that holds
  control state.  Clock domain crossings only through `am_sync` (single
  slow bits) and `am_afifo` (data).
- `always @(posedge clk)` with non-blocking assignments for registers,
  `always @(*)` with blocking assignments for combinational logic,
  `assign` for simple wires.  No latches.
- Valid/ready handshakes: a source does not drop valid or change its
  payload before ready.  Responses without ready are named as such.
- Vendor primitives (PS7, BUFG, MMCME2, BSCANE2, ...) only in `boards/`
  and `rtl/bsp/xilinx7/`.
- Register offsets and fields come from `include/ghci_regs.vh`, never as
  bare numbers.
- Lint clean: `tools/lint.sh` reports no warning.  An unavoidable warning
  (an unused bit of a bus, a constant truncated on purpose) is silenced
  locally: unused bits are collected in a wire named `unused_ok` (Verilator
  ignores names with "unused"), a deliberate truncation is wrapped in
  `verilator lint_off` / `lint_on` for that line only.
- Indentation with tabs; lines up to about 100 columns.

Arithmetic
----------

User decision (2026-10-25): every multiplier, divider, adder, subtractor
and shifter is a shared module of `rtl/library/arith/`, instantiated where it is
needed, so that a design has only the arithmetic it really needs and each
kind maps to the FPGA's best cell (a multiplier to DSP slices, an adder to
a carry chain) where it can be checked once.

- Signal arithmetic -- `+`, `-` (also unary), `*`, `/`, `%`, and a shift
  (`<<`, `>>`, `>>>`) by an amount that is a signal -- is written only
  inside the modules of `rtl/library/arith/`.  Every other module instantiates
  them:

  | Module | What | Cells (7 series) |
  | --- | --- | --- |
  | `am_add` | `{co, s} = a + b + ci` | CARRY4 chain |
  | `am_sub` | `d = a - b - bi`, borrow out | CARRY4 chain |
  | `am_addsub` | `a + b` or `a - b` chosen by `sub` | CARRY4 chain and the XOR of b |
  | `am_mul` | `a * b`, signed or unsigned, 0-n registers | DSP48E1 (`SYNTH_KINTEX7` cascade, generic otherwise) |
  | `am_div` | unsigned `a / b` and `a % b`, one bit per cycle | LUTs and a CARRY4 chain (one subtractor) |
  | `am_shift` | `a << n`, `a >> n`, `a >>> n` | LUTs (log2(W) levels of multiplexers) |

- `*` is written only in `am_mul.v` (generic `ifndef SYNTH_KINTEX7`).  Under `SYNTH_KINTEX7`,
  `am_mul.v` instantiates `DSP48E1` primitives directly with `PCOUT -> PCIN` cascade.
- Adders and shifters remain mapped to fabric (`CARRY4` and LUTs).
- Floating-point operators are unified in `rtl/library/fp/` (`am_fp_*`).
- Operations of one module that are never needed in the same cycle share
  one instance, with their operands selected in front of it.
- Not covered (constants, wiring): parameter and localparam expressions and
  any expression that is a constant after elaboration (a width, an index of
  a generate or for loop, a function called only with constants); a shift
  by a constant amount, and `*`, `/` or `%` by a constant power of two;
  testbenches and `sim/`.  The comparisons (`<`, `==`, ...) are not
  arithmetic in this rule.
- `tools/arith-lint.py` counts the signal arithmetic outside `rtl/library/arith/`
  in the elaborated design (Verilator); it reports 0 when the rule holds.
  A file that must keep its arithmetic is listed in the script's exception
  table with the reason, and here.

High-Frequency ASIC Scaling (Target: 5nm 1.5 GHz)
------------------------------------------------

Goal:
Design all RTL modules with microarchitectural disciplines such that the codebase
naturally synthesizes and closes timing at 1.5 GHz on modern 5nm ASIC standard-cell
libraries (with base 2.0 GHz / boost 2.4 GHz headroom), while using Xilinx 7-series
FPGA (Kintex-7 -2 / KC705) as the primary emulation and verification target.

Background:
- In FPGA prototyping, a single 6-input LUT (LUT6) implements an arbitrary 6-input
  Boolean function, and dedicated hard macros (e.g. CARRY4, DSP48E1, wide multiplexers)
  provide fast dedicated silicon routes that mask deep combinational logic trees.
- In contrast, in modern advanced ASIC nodes (5nm class), interconnect wire RC delay
  dominates timing, accounting for 40% to 50%+ of the total clock period.
- At 1.5 GHz (period T = 667 ps), after deducting clock uncertainty, jitter, setup/hold
  margins, and clock-tree skew (~150-180 ps) plus wire RC delay (~200-250 ps), the net
  usable standard-cell delay budget is only ~250-310 ps.
- In a 5nm standard-cell library, a FO4 (fanout-of-4) inverter delay is approximately
  10-12 ps, meaning each clock stage can afford at most 20-25 FO4 delays (roughly 15-20
  logic stages of NAND/NOR/AOI gates).
- Consequently, simply restricting FPGA synthesis to "<= 5 LUT levels" is insufficient:
  FPGA carry chains and high-fanout nets can silently hide logic that expands to 30-40+
  standard cells and severe wire congestion in an ASIC flow.

Design Rules:

1. Primitive & Logic Level Budget
   - Pure random logic paths must not exceed 4 LUT6 levels (target <= 3 LUT6 levels).
   - Arithmetic addition/subtraction: A 32-bit adder (`am_add`/`am_sub`) must have at
     most 1 LUT6 stage before it (operand selection/muxing) and at most 1 LUT6 stage
     after it before being registered. 64-bit additions must be split across 2 pipeline
     cycles.
   - Multipliers: Multiplier instances (`am_mul` / DSP) must have latency `LAT >= 2`,
     with at most 1 LUT stage after the multiplier output before a register stage.

2. Fanout Limitation & Tree Buffering
   - High fanout degrades transition time and wire RC exponentially in deep submicron ASIC.
   - Any register driving wide datapaths or distributed control must adhere to a target
     fanout limit of <= 16 (hard limit 24).
   - Global control nets (`valid`, `ready`, `stall`, `flush`, decoded opcodes) spanning
     multiple SIMD lanes or ALUs must use explicit pipeline tree buffering or register
     replication (or synthesis directive `(* max_fanout = 16 *)`).

3. Flop-to-Flop Inter-Module Boundary
   - Zero combinational feedthrough paths between submodules.
   - Every inter-module interface (requests, grants, data buses, handshakes) must be
     registered at either the transmitting module (output register) or receiving
     module (input register). Combinational logic must never cross module hierarchy
     boundaries.

4. Clean Single-Cycle Memory Pipeline
   - Embedded memories (SRAM macros, register files, LDS, cache tag/data arrays) must
     have clean 1-cycle latency boundaries.
   - Zero combinational logic on the memory address input: address registers must drive
     memory inputs directly.
   - Zero combinational logic on memory data output before the first pipeline register.
     Any format conversion, byte extraction, or multiplexing must execute in the
     subsequent pipeline stage.

5. Backpressure Decoupling (Skid Buffer Isolation)
   - Handshake interfaces (`valid` / `ready`) must never allow backward `ready` signals
     to ripple combinationally across multiple pipeline stages.
   - Whenever an elastic pipeline stage, FIFO, or processing block exerts backpressure
     (`ready = 0`), an `am_skid` buffer must be used to decouple downstream `ready`
     from upstream `valid` generation.

FPGA Surrogate Verification Metric:
On Kintex-7 speedgrade -2 (`xc7k325tffg900-2`), achieving out-of-context (OOC) timing
closure at 250 MHz (period 4.000 ns, WNS >= 0.000 ns) while strictly adhering to these
five structural rules serves as the verified gate to ensure 1.5 GHz timing closure at 5nm ASIC.

Board clocking
--------------

- Never make a clock by dividing in logic (a counter, a toggling flip-flop
  or anything else on fabric routing).  A clock of another rate comes from
  a PLL/MMCM output divider: those outputs ride the dedicated clock
  network (user, 2026-10-26).
- An IP block's clock inputs follow the vendor reference's input path.
  The KC705's MIG takes SYSCLK straight from the clock-capable pin's
  IBUFDS into its PLL, as the MIG's own input buffer does in the
  reference.  With a BUFG in front of the MIG's PLL the calibration
  depended on the build: the board's build failed every time, a build
  with the MIG's debug ports passed; with the direct path both builds
  (Debug on and off) calibrated 50 times out of 50 (ws288 p024).  The same IBUFDS may also drive a BUFG
  for the fabric's clock managers, and the MIG's IDELAYCTRL reference
  (clk_ref_i, which the MIG's own MMCM makes into 400 MHz) comes from
  that BUFG.  The PCIe bridge takes its reference from IBUFDS_GTE2.

Board builds
------------

- A board bitstream records the Vivado version and build (2026.1, SW
  Build 6511674 for the KC705 now), the strategy (Default unless the
  record says otherwise) and the commit it was built from.
- A board fault that goes away when debug cores or ports are added is a
  warning sign, not a fix: the netlist changed, so placement and routing
  changed.  Find the cause in the build without them.

Testbenches
-----------

- `sim/tb/NAME_tb.v` with top module `NAME_tb`; run by `sim/run.sh`.  A
  testbench prints `PASS NAME` at the end when it found no error and
  `FAIL ...` for each error; it has a timeout.
- Testbenches may use behavioural Verilog-2005 (tasks, `$random`,
  hierarchical references).  Shared models live in `sim/models/`, shared
  tasks in `sim/tb/*.vh`.
- Random tests take a seed and check against a reference model, not
  against values copied from a run.

Scripts
-------

- POSIX `sh` unless a tool needs bash (Vivado's `settings64.sh`).
- A comment at the top: what it does, usage, outputs, time limits.
- Outputs go to `build/` (ignored by git).  Vivado projects, IP output
  products and bitstreams are never committed.
- Every long run has a timeout.
