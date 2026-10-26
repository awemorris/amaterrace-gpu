<!-- awesome-plan project=amaterrace-gpu record=automation-coverage -->

# Automation Coverage Map

| Rule / Requirement | Enforcing Tool | Command | Scope / Pinned Version | Status |
| :--- | :--- | :--- | :--- | :--- |
| Verilog lint clean | Verilator | `tools/lint.sh` or `make lint` | Verilator 5.032 | Automated |
| Signal arithmetic isolation | Python / Verilator | `tools/arith-lint.py` | Python 3 + Verilator | Automated (must be 0) |
| Unit testbenches | Icarus Verilog | `sim/run.sh` or `make sim` | Icarus Verilog 12+ (`-g2005`) | Automated |
| Quick regression | Icarus Verilog | `sim/run.sh -q` or `make sim-quick` | Icarus Verilog 12+ | Automated |
| System harness & scenes | Verilator | `sim/verilator/run.sh` or `make verilator` | Verilator + C++ harness | Automated |
| Multiplier DSP/Generic Equivalence | Icarus Verilog / xsim | `sim/tb/am_mul_dsp_tb.v` (p001 Step B) | Vivado unisim + glbl | Planned in p001 |
| KC705 FPGA Synthesis & Implementation | Vivado | `tools/vivado-build.sh kc705 atg_kc705_raster` | Vivado 2026.1 build 6511674 | Automated |
| Full regression | make | `make check` (`lint` + `sim` + `verilator`) | All | Automated |
