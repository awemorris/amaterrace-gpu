# atg_tu_aniso

RTL: `rtl/gpu/tu/atg_tu_aniso.v`. Parent: `atg_tu`. Children: `am_mul`, `am_add`, `am_sub`. Implemented in: ws002-p004.

## 1. Purpose and place

`atg_tu_aniso` implements hardware anisotropic texture filtering using an Elliptical Weighted Average (EWA) approximation along the major footprint axis.
When a textured surface is viewed at an oblique angle, the projection of a pixel footprint onto texture space forms an ellipse with high eccentricity. Standard isotropic mipmapping selects the maximum footprint dimension, resulting in severe over-blurring.
`atg_tu_aniso` analyzes the partial derivative vectors $(\partial u/\partial x, \partial v/\partial x)$ and $(\partial u/\partial y, \partial v/\partial y)$, computes the anisotropy ratio (up to 16:1), and generates a sequence of $N \in [1..16]$ bilinear sample coordinates along the major axis. Each sample is weighted by a pre-normalized Gaussian weight ($w_i$), accumulated, and normalized to produce the final filtered texel without requiring runtime division.

## 2. Parameters

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `MAX_SAMPLES` | integer | 16 | Maximum number of anisotropic bilinear samples (up to 16). |

## 3. Ports

Clock/reset domain: `clk` (gclk), synchronous active-low reset `rst_n`.

| Name | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Request Interface** | | | |
| `req_valid` | in | 1 | Valid derivative request pulse. |
| `req_ready` | out | 1 | Unit is idle and ready to accept a new request. |
| `dudx` | in | 32 | Partial derivative $\partial u/\partial x$ in signed Q16.16. |
| `dudy` | in | 32 | Partial derivative $\partial u/\partial y$ in signed Q16.16. |
| `dvdx` | in | 32 | Partial derivative $\partial v/\partial x$ in signed Q16.16. |
| `dvdy` | in | 32 | Partial derivative $\partial v/\partial y$ in signed Q16.16. |
| `max_aniso` | in | 4 | Anisotropy limit setting. `4'd0` = 16x; `4'd1`..`4'd15` = 1x..15x. |
| **Sample Generation Interface** | | | |
| `samp_valid` | out | 1 | Valid sample coordinates generated. |
| `samp_ready` | in | 1 | Downstream bilinear sampler ready for sample. |
| `samp_u` | out | 32 | Sample U coordinate offset in signed Q16.16. |
| `samp_v` | out | 32 | Sample V coordinate offset in signed Q16.16. |
| `samp_weight` | out | 17 | Sample Gaussian weight $w_i \in [0..65536]$ (Q16). |
| **Filtered Texel Accumulation Interface** | | | |
| `filt_valid` | in | 1 | Valid bilinear filtered texel returned from sampler. |
| `filt_texel` | in | 32 | Packed 32-bit RGBA8 texel data `{A, B, G, R}`. |
| `res_valid` | out | 1 | Final anisotropic accumulated texel valid. |
| `res_texel` | out | 32 | Final packed 32-bit RGBA8 texel result. |

## 4. Architectural Details

### 4.1 Major Axis and Eccentricity Estimation
1. Vector lengths squared:
   $$L_x^2 = \left(\frac{\partial u}{\partial x}\right)^2 + \left(\frac{\partial v}{\partial x}\right)^2$$
   $$L_y^2 = \left(\frac{\partial u}{\partial y}\right)^2 + \left(\frac{\partial v}{\partial y}\right)^2$$
2. The longer vector is selected as the major axis:
   - If $L_x^2 \ge L_y^2$: Major axis = $(\partial u/\partial x, \partial v/\partial x)$, $L_{maj}^2 = L_x^2$, $L_{min}^2 = L_y^2$.
   - If $L_x^2 < L_y^2$: Major axis = $(\partial u/\partial y, \partial v/\partial y)$, $L_{maj}^2 = L_y^2$, $L_{min}^2 = L_x^2$.
3. Ratio calculation:
   The ratio $\rho = \sqrt{L_{maj}^2 / L_{min}^2}$ satisfies:
   $$2 \log_2(\rho) = \log_2(L_{maj}^2) - \log_2(L_{min}^2)$$
   The function `tu_l2` computes fixed-point $\log_2$ with 8 fraction bits. The difference is halved via arithmetic shift.
   Comparing $\log_2(\rho)$ against fixed thresholds ($\log_2(1.5), \log_2(2.5), \dots, \log_2(15.5)$) determines the integer sample count $N \in [1..16]$ without square-root or division hardware.
   $N$ is then clamped to the programmed `max_aniso` threshold.

### 4.2 Sample Offset Calculation
Along the major axis $(D_u, D_v)$, sample points are placed uniformly with parameter $t_i \in [-0.5, 0.5]$:
$$t_i = \left(\frac{i + 0.5}{N} - 0.5\right) = \frac{2i + 1 - N}{2N}$$
The sample offsets are computed using dedicated `am_mul` instances:
$$\Delta u_i = D_u \cdot t_i, \quad \Delta v_i = D_v \cdot t_i$$

### 4.3 Pre-Normalized Gaussian Weights
Gaussian weights $w_i = \exp(-2 t_i^2)$ are evaluated for each discrete $N \in [1..16]$ and scaled such that:
$$\sum_{i=0}^{N-1} w_i = 65536 = 2^{16}$$
This exact normalization ensures:
- Full energy conservation: a uniform texture input produces identical output without gain or loss.
- Hardware efficiency: division is completely eliminated. Texel channels are accumulated as 24-bit fixed point $(w_i \cdot C / 65536)$ and truncated/rounded cleanly with zero fabric overhead.

### 4.4 RTL Arithmetic Compliance
In strict compliance with Amaterrace GPU guidelines:
- All additions and subtractions use `am_add` / `am_sub`.
- All multiplications use `am_mul`.
- Zero raw arithmetic operators (`+`, `-`, `*`, `/`, `%`) exist in `atg_tu_aniso.v`.
