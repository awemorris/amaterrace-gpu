# atg_vf_vc

RTL: `rtl/gpu/vf/atg_vf_vc.v`. Parent: `atg_vf`. Implemented in: Phase 033.

## 1. Purpose and place

The Post-Transform Vertex Cache (PT-VC) eliminates redundant vertex shader executions for shared vertices in indexed meshes (e.g. triangles sharing vertices).
It maintains a 32-entry fully-associative cache of transformed vertex clip positions and varying attributes.
When an incoming index matches a cached entry, the vertex shader invocation is bypassed and the cached vertex attributes are directly routed, achieving 0-cycle shading latency for reused vertices.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NENTRIES` | 32 | Number of cache entries (fully associative). |
| `VDATA_W` | 512 | Shaded vertex data width (clip position + varyings). |
| `SLOT_W` | 5 | Slot index width (log2(`NENTRIES`)). |

## 3. Ports

Clock/reset domain: `clk`. Synchronous reset `rst_n` (active low).

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `rst_n` | in | 1 | Synchronous active-low reset. |
| `flush` | in | 1 | Synchronous cache invalidate (e.g. draw call kick). |
| **Lookup Port** | | | |
| `lookup_valid` | in | 1 | Index lookup query valid. |
| `lookup_index` | in | 32 | Vertex index to search in CAM. |
| `hit` | out | 1 | High when `lookup_index` exists in a valid cache entry. |
| `hit_vdata` | out | VDATA_W | Transformed vertex data associated with the hit entry. |
| `hit_slot` | out | SLOT_W | Matching cache slot index. |
| **Commit Port** | | | |
| `commit_valid` | in | 1 | Shader completion commit valid. |
| `commit_index` | in | 32 | Shaded vertex index to register. |
| `commit_vdata` | in | VDATA_W | Shaded vertex attribute payload. |

## 4. Behaviour

- **CAM Lookup**: 32 entries are checked in parallel combinationally against `lookup_index`. If a valid entry matches, `hit` asserts immediately (0-cycle combinational response) along with `hit_vdata` and `hit_slot`.
- **Commit**: When the shader completes a vertex, `commit_valid` writes the index and payload into the cache. If the index is already present, its entry is updated. Otherwise, an unused entry is allocated, or the FIFO victim pointer entry is replaced.
- **Flush**: Asserting `flush` invalidates all entries and resets the victim pointer to 0.

## 5. Latency and Throughput

- **Lookup latency**: 0 cycles (combinational CAM).
- **Throughput**: 1 lookup per cycle sustained.
- **Vertex reuse benefit**: 50% to 75% reduction in vertex shader workload on typical indexed triangle meshes.

## 6. Status

Implemented in Phase 033 (2026-10-27). Verified with `sim/tb/atg_vf_vc_tb.v`.
