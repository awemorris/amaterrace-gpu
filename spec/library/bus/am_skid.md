# am_skid

RTL: `rtl/library/bus/am_skid.v`.

## 1. Purpose and place

A full registered skid buffer (2-entry register slice) that provides 100% throughput (zero bubble) while completely breaking all combinational paths in both the forward (`valid`, `data`) and reverse (`ready`) directions.

In long-distance or high-fanout inter-block buses within the GPU, standard ready/valid handshakes often form critical timing paths or combinational loops when daisy-chained. A 1-entry register slice can break forward timing paths, but stalling downstream forces it to lower `ready` combinationally to prevent data loss. `am_skid` provides 2 entries of storage (main output register and skid register). Both `in_ready` and `out_valid`/`out_data` are registered outputs, decoupling timing between upstream and downstream stages without sacrificing single-cycle throughput.

Parent: Inter-block buses (e.g., DC/display pipeline, AMB/AXI channels). Children: None.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `W` | 32 | Alias for payload data width | ≥ 1 |
| `WIDTH` | `W` | Primary parameter for payload data width in bits | ≥ 1 |

## 3. Ports

| Name | Dir | Width | Domain | Meaning, handshake, timing |
| --- | --- | --- | --- | --- |
| `clk` | in | 1 | — | Clock |
| `rst_n` | in | 1 | `clk` | Synchronous active-low reset |
| `in_valid` | in | 1 | `clk` | Upstream data valid |
| `in_ready` | out | 1 | `clk` | Registered ready to upstream: high when skid register is empty |
| `in_data` | in | `WIDTH` | `clk` | Upstream data word |
| `out_valid` | out | 1 | `clk` | Registered valid to downstream: high when main register holds data |
| `out_ready` | in | 1 | `clk` | Downstream ready signal |
| `out_data` | out | `WIDTH` | `clk` | Registered data word to downstream |

All inputs (`in_valid`, `in_data`, `out_ready`) drive only flip-flop data/enable inputs. All outputs (`in_ready`, `out_valid`, `out_data`) are driven directly by flip-flops. No combinational paths exist between any input and any output port.

## 4. Behaviour and Operation

The buffer contains two data registers:
- **Main Register (`out_data`, `out_valid`)**: Directly drives the output port.
- **Skid Register (`skid_data`, `skid_valid`)**: Holds the spare entry when downstream stalls while upstream sends data.

### Handshake Rules:
- Upstream transfer occurs when `in_valid && in_ready`.
- Downstream transfer occurs when `out_valid && out_ready`.

### Operational Modes:
1. **Empty State (`!out_valid && !skid_valid`)**:
   - `in_ready = 1`, `out_valid = 0`.
   - When upstream presents `in_valid = 1`, data is loaded directly into `out_data` on next clock edge; `out_valid <= 1`.
2. **Steady Streaming (100% Throughput, `out_valid && !skid_valid`)**:
   - Both `in_ready = 1` and `out_ready = 1`.
   - Every cycle, incoming data replaces `out_data` directly. Data flows with 1 cycle latency and 1 transfer per clock cycle (zero bubbles).
3. **Downstream Back-pressure (Skid Capture)**:
   - When `out_valid = 1`, `out_ready = 0`, but upstream sends data (`in_valid && in_ready`):
   - The incoming data cannot overwrite `out_data` (since downstream did not consume it).
   - The data is captured into `skid_data`, `skid_valid <= 1`.
   - Simultaneously, `in_ready <= 0` is registered for the next cycle, stopping upstream from sending further data.
4. **Drain from Skid**:
   - When downstream asserts `out_ready = 1` while `skid_valid = 1`:
   - `skid_data` moves to `out_data`, `out_valid <= 1`.
   - `skid_valid <= 0`.
   - `in_ready <= 1` is re-asserted for the following cycle.

## 5. Timing Diagram

### Back-Pressure and Recovery Sequence

```text
Cycle        :  0   |  1   |  2   |  3   |  4   |  5   |  6
clk          : _/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_
in_valid     : _____/=================================______
in_data      : _____X==D0==X==D1==X==D2=======X==D3===X______
in_ready     : ===========================\___________/=====
                      ^transfer D0 ^transfer D1 (skidded)

out_valid    : ____________/================================
out_data     : ____________X==D0==============X==D1===X==D2=
out_ready    : ___________________________/=================
                                           ^transfer D0^transfer D1
skid_valid   : ___________________/===========\_____________
skid_data    : ___________________X===D1======X_____________
```

- Cycle 1: Upstream transfers `D0`. `in_ready=1`, `out_valid=0`.
- Cycle 2: `D0` appears at `out_data`, `out_valid=1`. Downstream `out_ready=0`. Upstream presents `D1`. Since `in_ready=1`, `D1` is accepted.
- Cycle 3: Because `out_ready=0`, `D0` is held at `out_data`. `D1` is captured in `skid_data`, and `in_ready` drops to 0. Upstream stalls on `D2`.
- Cycle 4: Downstream asserts `out_ready=1`, consuming `D0`.
- Cycle 5: `D1` from skid register moves to `out_data`. `skid_valid` becomes 0, and `in_ready` rises to 1. `D1` is consumed by downstream. Upstream `D2` is accepted.
- Cycle 6: `D2` moves to `out_data`.

## 6. Latency and Throughput

- **Latency**: 1 clock cycle under streaming conditions (`in_valid` to `out_valid`).
- **Throughput**: 1 transfer per clock cycle (100% bandwidth, 0 bubble).
- **Timing Isolation**: $T_{comb} = 0$ between upstream and downstream interfaces.

## 7. Status

- Implemented in `rtl/library/bus/am_skid.v`.
- Unit testbench: `sim/tb/am_skid_tb.v`.
