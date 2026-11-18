# atg_tu_cube_edge

RTL: `rtl/gpu/tu/atg_tu_cube_edge.v`. Parent: `atg_tu_addr` / `atg_tu_foot` (via `atg_tu_cube_texel`). Children: `am_sub`. Implemented in: ws002-p005.

## 1. Purpose and place

`atg_tu_cube_edge` implements hardware cube map boundary (Face Edge) texel coordinate remapping for seamless bilinear cube map filtering (Vulkan 1.0 `VK_FILTER_CUBEMAP_SEAMLESS` / `cubeSeamless`).
When a bilinear footprint touches or crosses one of the 12 edges of the cube, the out-of-bounds texel coordinates ($u < 0$, $u \ge \text{size}$, $v < 0$, or $v \ge \text{size}$) are mapped to the adjacent face's coordinate system with proper boundary rotation and reflection, eliminating boundary seams during skybox or environment map sampling.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: Pure combinational module.

| Name | Dir | Width | Description |
| --- | --- | --- | --- |
| `face_in` | in | 3 | Current face index: `0:+X`, `1:-X`, `2:+Y`, `3:-Y`, `4:+Z`, `5:-Z`. |
| `u_in` | in | 16 (signed) | Texel coordinate along $u$ axis. |
| `v_in` | in | 16 (signed) | Texel coordinate along $v$ axis. |
| `size` | in | 16 | Cube face dimension in texels ($N$). |
| `face_out` | out | 3 | Remapped face index. |
| `u_out` | out | 16 | Remapped $u$ texel coordinate on target face. |
| `v_out` | out | 16 | Remapped $v$ texel coordinate on target face. |

## 4. Behaviour

### 4.1 Boundary Detection
- Left overflow: $u < 0$ (Edge 0)
- Right overflow: $u \ge N$ (Edge 1)
- Top overflow: $v < 0$ (Edge 2)
- Bottom overflow: $v \ge N$ (Edge 3)

### 4.2 12-Edge Adjacent Topology Table
For each of the 6 cube faces and 4 boundary edges:
1. Target face $g \in [0..5]$ is selected based on cube topological adjacency.
2. Coordinates along the shared edge are mapped using either direct coordinate copy ($a$), edge reversal ($N - 1 - a$), or boundary anchoring ($0$ or $N - 1$).
3. All coordinate subtractions ($N - 1$ and $N - 1 - a$) are implemented strictly with `am_sub` without raw arithmetic operators.

| Face | Edge 0 ($u < 0$) | Edge 1 ($u \ge N$) | Edge 2 ($v < 0$) | Edge 3 ($v \ge N$) |
| --- | --- | --- | --- | --- |
| **0 (+X)** | Face 4 (+Z), $(N-1, v)$ | Face 5 (-Z), $(0, v)$ | Face 2 (+Y), $(N-1, N-1-u)$ | Face 3 (-Y), $(N-1, u)$ |
| **1 (-X)** | Face 5 (-Z), $(N-1, v)$ | Face 4 (+Z), $(0, v)$ | Face 2 (+Y), $(0, u)$ | Face 3 (-Y), $(0, N-1-u)$ |
| **2 (+Y)** | Face 1 (-X), $(v, 0)$ | Face 0 (+X), $(N-1-v, 0)$ | Face 5 (-Z), $(N-1-u, 0)$ | Face 4 (+Z), $(u, 0)$ |
| **3 (-Y)** | Face 1 (-X), $(N-1-v, N-1)$ | Face 0 (+X), $(v, N-1)$ | Face 4 (+Z), $(u, N-1)$ | Face 5 (-Z), $(N-1-u, N-1)$ |
| **4 (+Z)** | Face 1 (-X), $(N-1, v)$ | Face 0 (+X), $(0, v)$ | Face 2 (+Y), $(u, N-1)$ | Face 3 (-Y), $(u, 0)$ |
| **5 (-Z)** | Face 0 (+X), $(N-1, v)$ | Face 1 (-X), $(0, v)$ | Face 2 (+Y), $(N-1-u, 0)$ | Face 3 (-Y), $(N-1-u, N-1)$ |

### 4.3 Corner Fallback
When both $u$ and $v$ are simultaneously out of bounds (a 3-face corner), the coordinate is clamped to the corner of the source face $(0\text{ or }N-1, 0\text{ or }N-1)$, maintaining consistency in accordance with Vulkan specification guidelines.
