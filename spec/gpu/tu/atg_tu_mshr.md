# atg_tu_mshr

RTL: `rtl/gpu/tu/atg_tu_mshr.v`.  Parent: `atg_tu_cache`.  Implemented in: ws001-p021.

## 1. Purpose and place

Miss Status Holding Register (MSHR) for the Texture Unit L1 cache (`atg_tu_cache`).
Eliminates single-outstanding blocking stalls on texture cache misses by tracking up to 4 concurrent in-flight cache line fetches to memory (AMB / L2 LLC).
Provides:
1. **Primary Miss Allocation**: Allocates a free MSHR entry when a new cache miss occurs and triggers a memory fetch.
2. **Secondary Miss / Merge**: Compares miss line addresses against all active in-flight entries. When a match is found, merges the new requester quad into the existing entry without issuing duplicate memory traffic.
3. **Hit-Under-Miss Execution**: Allows cache hits to proceed concurrently while unrelated misses are in flight.
4. **Refill Notification**: When memory response data arrives, releases the corresponding MSHR entry, writes data to cache BRAM, and wakes up all waiting quads.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NENTRIES` | `4` | Number of MSHR entries (concurrent in-flight misses). |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `64` | Cache line size in bytes (32 or 64). |
| `LINE_SHIFT` | `6` | log2(LINE_BYTES). |
| `QUAD_ID_W` | `6` | Width of quad tracking identifier (up to 64 quads). |

## 3. Ports

Clock/reset domain: `clk` (gclk). Synchronous active-low reset `rst_n`.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | Clock and synchronous active-low reset. |
| **Query interface** | | | |
| `check_valid` | in | 1 | Query if a line is currently in-flight. |
| `check_line_addr` | in | `ADDR_W-LINE_SHIFT` | Line address to check. |
| `check_hit` | out | 1 | 1 if line is currently being fetched in an MSHR entry. |
| `check_mshr_idx` | out | 2 | Index of matching MSHR entry. |
| **Allocation interface** | | | |
| `alloc_valid` | in | 1 | Request allocation of a miss. |
| `alloc_ready` | out | 1 | MSHR can accept (has a free entry or merges with existing entry). |
| `alloc_line_addr` | in | `ADDR_W-LINE_SHIFT` | Cache line address of the miss. |
| `alloc_quad_id` | in | `QUAD_ID_W` | Identifier of the quad suffering the miss. |
| `alloc_mshr_idx` | out | 2 | MSHR entry index allocated or merged into. |
| `alloc_merged` | out | 1 | 1 if this miss merged into an existing in-flight entry (secondary miss). |
| **Memory refill response interface** | | | |
| `refill_valid` | in | 1 | Memory refill response arrived. |
| `refill_mshr_idx` | in | 2 | MSHR entry index from memory response tag. |
| `refill_data` | in | `LINE_BYTES*8` | Cache line data from memory. |
| `refill_error` | in | 1 | Bus / aperture error on memory response. |
| **Cache update & completion notification** | | | |
| `mshr_ready_valid` | out | 1 | One-cycle pulse when an entry finishes refill. |
| `mshr_ready_quad_id` | out | `QUAD_ID_W` | Primary quad ID that triggered the entry. |
| `mshr_ready_mask` | out | `1<<QUAD_ID_W` | Bitmask of all quads waiting on this line (primary + merged). |
| `mshr_ready_data` | out | `LINE_BYTES*8` | Refilled cache line data for BRAM write. |
| `mshr_ready_line` | out | `ADDR_W-LINE_SHIFT` | Line address of the refilled entry. |
| `mshr_ready_error` | out | 1 | Refill error status. |
| `mshr_ready_idx` | out | 2 | Index of the refilled entry (0..3). |
| **Status** | | | |
| `active_count` | out | 3 | Number of active entries currently in-flight (0..4). |
| `empty` | out | 1 | 1 when no entries are in-flight (`active_count == 0`). |
| `full` | out | 1 | 1 when all entries are occupied (`active_count == 4`). |

## 4. Behaviour

- **CAM Search for Merging**: On `alloc_valid`, all active entries compare their stored `entry_line` with `alloc_line_addr`. If any match, `alloc_merged = 1` and `alloc_ready = 1`, and the quad ID is set in the entry's quad bitmask without consuming a new entry.
- **Primary Allocation**: When `alloc_valid` is asserted without a line match, the lowest free entry index is selected. The entry is initialized with `entry_line`, `entry_qid`, and a 1-hot bit in `entry_qmask`.
- **Refill**: On `refill_valid`, the matching entry is cleared and `mshr_ready_*` signals are asserted with the refilled data, address, and the complete mask of waiting quads. If a refill and an allocation happen in the same cycle, the refilling entry is immediately reusable.
- **Arithmetic Guardrails**: Free entry selection, active count decoding, and quad mask shifting use pure Boolean multiplexers, priority encoders, and `am_shift` from `rtl/library/arith/` (zero raw arithmetic operators).

## 5. What the TB checks

`sim/tb/atg_tu_mshr_tb.v`:
- Initial state verification (empty, active_count 0).
- Primary miss allocation filling all 4 entries (0..3).
- Full backpressure check (`alloc_ready` goes to 0 for non-matching lines).
- Secondary miss merge check while full (`alloc_ready = 1`, `alloc_merged = 1`).
- Out-of-order and parallel refills.
- Hit-Under-Miss scenario with 80-cycle simulated memory latency.
- Same-cycle refill and allocation entry reuse.
