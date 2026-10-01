// ============================================================================
// a0_ddr4_model_wrapper.sv -- DDR4 memory model selection for A0
// Board part = MT40A512M16HA-083E  ->  8 Gb x16 (DDR4-2400, tCK 833 ps)
// The official wrapper (ddr4_sdram_model_wrapper.sv) hard-codes DDR4_16G_X8;
// we need the x16 density macro so the model decodes OUR geometry.
// ============================================================================
`define DDR4_8G_X16
`define DDR4_938_Timing
`include "arch_package.sv"
`include "proj_package.sv"
`include "interface.sv"
`include "ddr4_model.sv"
