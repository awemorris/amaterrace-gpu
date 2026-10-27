# ==============================================================================
# Amaterrace GPU (ATG1) - High-Performance Configuration Preset
# Target: High-end Kintex-7 / Virtex-7 / Kintex UltraScale+
# ==============================================================================

TARGET_PRESET            = kc705

# 1. Shader Unit (SU)
CONFIG_SU_NPHYS          = 32
CONFIG_SU_NWARPS         = 8
CONFIG_SU_NREGS          = 64
CONFIG_SU_ENABLE_FP16    = 1
CONFIG_SU_ENABLE_SUBGROUP = 1
CONFIG_SU_ENABLE_SFU     = 1
CONFIG_SU_LDS_KB         = 4
CONFIG_SU_ENABLE_SA      = 1
CONFIG_SU_ENABLE_MESH    = 1

# 2. Rasterizer (RX)
CONFIG_RX_ENABLE_MSAA    = 1
CONFIG_RX_MSAA_SAMPLES   = 4
CONFIG_RX_ENABLE_EARLY_Z = 1
CONFIG_RX_COARSE_SCAN    = 1

# 3. Texture Unit (TU)
CONFIG_TU_ENABLE_BC      = 1
CONFIG_TU_ENABLE_ETC2    = 1
CONFIG_TU_ENABLE_ANISO   = 1
CONFIG_TU_ENABLE_SEAMLESS_CUBE = 1
CONFIG_TU_ENABLE_FP_FILTER = 1
CONFIG_TU_ENABLE_ARRAY   = 1
CONFIG_TU_ENABLE_TRILINEAR = 1
CONFIG_TU_ENABLE_3D_CUBE = 1
CONFIG_TU_L1_BANKS       = 4
CONFIG_TU_ENABLE_MSHR    = 1
CONFIG_TU_ENABLE_FFILT   = 1
CONFIG_TU_L1_CACHE_KB    = 16

# 4. Render Output Backend (ROP) & Formats
CONFIG_FMT_ENABLE_FP16   = 1
CONFIG_FMT_ENABLE_FP32   = 1
CONFIG_FMT_ENABLE_SRGB   = 1
CONFIG_FMT_ENABLE_RGB565 = 1
CONFIG_FMT_ENABLE_DEPTH24_S8 = 1
CONFIG_FMT_ENABLE_DEPTH32F = 1
CONFIG_FMT_ENABLE_DEPTH16 = 1
CONFIG_ROP_ENABLE_FBLEND = 1
CONFIG_ROP_ENABLE_PACK   = 1
CONFIG_ROP_DUAL_SOURCE   = 1
CONFIG_ROP_ENABLE_LOGICOP = 1
CONFIG_ROP_MRT_COUNT     = 8
CONFIG_ROP_FAST_CLEAR    = 1

# 5. Command Processor (CP) & Memory Hierarchy
# High-Performance Profile Address Configuration (Workstation / Server / Future ASIC):
#   GPU_VA_BITS  = 40 (1 TiB internal VA, large-scale unified virtual memory space)
#   HOST_PA_BITS = 48 (256 TiB PCIe PA, full 48-bit server physical memory space)
CONFIG_GPU_VA_BITS       = 40
CONFIG_HOST_PA_BITS      = 48
CONFIG_CP_AUTONOMOUS_MMU = 1
CONFIG_CP_USE_RV32_CORE  = 1
CONFIG_MC_ENABLE_PROT    = 1
CONFIG_MC_L2_CACHE_KB    = 128
CONFIG_MC_L2_WAYS        = 16
CONFIG_VF_CACHE_LINES    = 8
CONFIG_DC_ENABLE_CURSOR  = 1
