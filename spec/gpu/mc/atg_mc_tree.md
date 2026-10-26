# atg_mc_tree

RTL: `rtl/gpu/mc/atg_mc_tree.v`. Parent: `atg_mc`. Implemented in: WS288 p023 milestone 4; refreshed to Flat Crossbar & QoS in ws001-p028.

## 1. Purpose and place

The MC's client crossbar: connects all client AMB ports (`am_amb_to_rt` leaves) to the MC root (`atg_mc`) via a 2-stage QoS-prioritized flat crossbar, replacing the previous multi-hop binary tree.

Latency:
- Request path: 1 cycle (via registered skid buffer `am_skid`).
- Response path: 1 cycle (via registered demux slice).
- Total roundtrip arbitration latency: **2 cycles** (down from 8 cycles in the binary tree).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NCLIENT`, `HIGH_MASK` | 2, 0 | As `atg_mc`. `HIGH_MASK` marks priority-1 clients. |
| `HAS_ROOT`, `ROOT_CLIENT` | 0, 0 | Client one hop from the root (e.g. DC). |
| `ROOT_SPLIT` | 0 | With `HAS_ROOT`: `ROOT_CLIENT` has its own channel (`s_*`) directly to the root. |
| `ROOT_KEEP` | 0 | With `ROOT_SPLIT`: `flush` leaves `ROOT_CLIENT` alone. |
| `TREE_L` | 1 | $\lceil \log_2(\text{NCLIENT} - \text{HAS\_ROOT}) \rceil$. |
| `RW` | 1 | Route bits: $\max(1, \text{TREE\_L} + \text{HAS\_ROOT})$. |
| `ADDR_W`, `LINE_BYTES`, `LINE_SHIFT`, `VRAM_AW`, `VRAM_BASE` | | As `atg_mc`. |

## 3. Ports

Clock/reset domain: `clk`, `rst_n` (active low synchronous).

- Client ports: `c_req_*`, `c_rsp_*` (packed, client 0 in low bits).
- Root request/response: `r_req_*`, `r_rsp_*`.
- Dedicated root client channel: `s_req_*`, `s_rsp_*`.
- Status: `rsp_idle` (high when no response flit is in transit).

## 4. QoS and Arbitration Behaviour

1. **Priority Level 1 (Strict Priority)**:
   - Clients marked in `HIGH_MASK` (such as the Display Controller) are granted immediately whenever they have a valid request.
2. **Priority Level 0 (Fair Round Robin)**:
   - 3D/compute clients (SU, TU, ROP, BLT, VF) are arbitrated fairly with a deficit round-robin pointer to prevent starvation.
3. **Packet Atomicity**:
   - Multi-flit write packets (`last == 0` header followed by data flit) maintain arbiter lock until `last` handshakes.
4. **Register Slices**:
   - Input/output paths are decoupled using `am_skid` buffers, guaranteeing 200 MHz timing closure.
