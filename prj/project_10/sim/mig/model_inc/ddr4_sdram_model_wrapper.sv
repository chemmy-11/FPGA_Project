// ============================================================================
// ddr4_sdram_model_wrapper.sv -- MACRO-ONLY shim (include-order fix for A0)
// The vendor's interface.sv does:  `include "ddr4_sdram_model_wrapper.sv"
// and the vendor wrapper includes interface.sv back -> mutual recursion if the
// vendor wrapper is used as-is.  This shim supplies ONLY the two configuration
// macros, so the real model files can be compiled in explicit dependency order.
// Board part: MT40A512M16HA-083E = 8 Gb x16 (DDR4-2400, tCK 833 ps)
// ============================================================================
`define DDR4_8G_X16
`define DDR4_938_Timing
