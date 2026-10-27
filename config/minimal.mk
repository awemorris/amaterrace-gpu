# ==============================================================================
# Amaterrace GPU (ATG1) - Minimal Configuration Preset
# Target: Low-resource FPGA budget / minimal footprint
# ==============================================================================

TARGET_PRESET            = kc705

# 1. Shader Unit (SU)
CONFIG_SU_NPHYS          = 4
CONFIG_SU_NWARPS         = 2
CONFIG_SU_NREGS          = 32
CONFIG_SU_ENABLE_FP16    = 0
CONFIG_SU_ENABLE_SUBGROUP = 0
CONFIG_SU_ENABLE_SFU     = 0
CONFIG_SU_LDS_KB         = 1
CONFIG_SU_ENABLE_SA      = 0
CONFIG_SU_ENABLE_MESH    = 0

# 2. Rasterizer (RX)
CONFIG_RX_ENABLE_MSAA    = 0
CONFIG_RX_MSAA_SAMPLES   = 1
CONFIG_RX_ENABLE_EARLY_Z = 0
CONFIG_RX_COARSE_SCAN    = 0

# 3. Texture Unit (TU)
CONFIG_TU_ENABLE_BC      = 0
CONFIG_TU_ENABLE_TRILINEAR = 0
CONFIG_TU_ENABLE_3D_CUBE = 0
CONFIG_TU_L1_BANKS       = 1
CONFIG_TU_ENABLE_MSHR    = 0

# 4. Render Output Backend (ROP)
CONFIG_ROP_DUAL_SOURCE   = 0
CONFIG_ROP_ENABLE_LOGICOP = 0
CONFIG_ROP_MRT_COUNT     = 1
CONFIG_ROP_FAST_CLEAR    = 0

# 5. Command Processor (CP) & Memory Hierarchy
CONFIG_CP_AUTONOMOUS_MMU = 0
CONFIG_CP_USE_RV32_CORE  = 0
CONFIG_MC_L2_CACHE_KB    = 0
CONFIG_DC_ENABLE_CURSOR  = 0
