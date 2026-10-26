<!-- awesome-plan project=amaterrace-gpu record=concise-standard-verilog -->

# Concise Verilog and Script Standards

Authoritative full standard: [docs/style.md](../../../docs/style.md).

## Verilog Mandatory Rules

1. **Standard & Scope**: Verilog-2005 only (`-g2005`). No SystemVerilog in `rtl/` or `boards/`.
2. **File Headers**:
   ```verilog
   `timescale 1ns / 1ps
   `default_nettype none
   ...
   `default_nettype wire
   ```
3. **Module Layout**: One module per file. File name = module name. `atg_` prefix for GPU blocks, `am_` prefix for shared parts. Prefer <= 400 lines.
4. **Port Lists**: ANSI style, one port per line (`input wire`, `output wire`, `output reg`).
5. **Registers & Reset**: Synchronous active-low reset (`rst_n`) on all control state registers.
   `always @(posedge clk)` with non-blocking `<=` for registers.
   `always @(*)` with blocking `=` for combinational logic.
   `assign` for wires. No latches.
6. **Clock Domain Crossing**: Single slow bits via `am_sync`, data streams via `am_afifo`, AXI buses via `am_axi_cdc`.
7. **Signal Arithmetic Restriction**:
   - `+`, `-`, `*`, `/`, `%`, and signal shifts (`<<`, `>>`, `>>>`) are strictly forbidden outside `rtl/library/arith/` (or `rtl/common/`).
   - Use `am_add`, `am_sub`, `am_addsub`, `am_shift`, `am_mul`, `am_div`.
   - Verified by `tools/arith-lint.py` (must report 0).
8. **Board Clocking**: Never divide clocks with fabric logic. Clocks must come from PLL/MMCM outputs on dedicated clock networks.
9. **Lint Clean**: `tools/lint.sh` must report 0 warnings.
10. **Git Commit Message**: Always commit with `-m WIP` (user rule, 2026-10-26). Detailed logs are kept in `plan/`.
