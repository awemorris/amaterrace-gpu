# ==============================================================================
# Amaterrace GPU (ATG1) - Balanced Configuration Preset (Default KC705)
# Target: Kintex-7 325T Standard Footprint
# ==============================================================================

TARGET_PRESET            = kc705

# 1. Shader Unit (SU)
CONFIG_SU_NPHYS          = 8
CONFIG_SU_NWARPS         = 4
CONFIG_SU_NREGS          = 32
CONFIG_SU_ENABLE_FP16    = 1
CONFIG_SU_ENABLE_SUBGROUP = 1
CONFIG_SU_ENABLE_SFU     = 1
CONFIG_SU_LDS_KB         = 4
CONFIG_SU_ENABLE_SA      = 0
CONFIG_SU_ENABLE_MESH    = 0

# 2. Rasterizer (RX)
CONFIG_RX_ENABLE_MSAA    = 1
CONFIG_RX_MSAA_SAMPLES   = 4
CONFIG_RX_ENABLE_EARLY_Z = 1
CONFIG_RX_COARSE_SCAN    = 1

# 3. Texture Unit (TU)
CONFIG_TU_ENABLE_BC      = 1
CONFIG_TU_ENABLE_TRILINEAR = 1
CONFIG_TU_ENABLE_3D_CUBE = 1
CONFIG_TU_L1_BANKS       = 4
CONFIG_TU_ENABLE_MSHR    = 1

# 4. Render Output Backend (ROP)
CONFIG_ROP_DUAL_SOURCE   = 1
CONFIG_ROP_ENABLE_LOGICOP = 1
CONFIG_ROP_MRT_COUNT     = 4
CONFIG_ROP_FAST_CLEAR    = 1

# 5. Command Processor (CP) & Memory Hierarchy
CONFIG_CP_AUTONOMOUS_MMU = 1
CONFIG_CP_USE_RV32_CORE  = 0
CONFIG_MC_L2_CACHE_KB    = 64
CONFIG_DC_ENABLE_CURSOR  = 1
