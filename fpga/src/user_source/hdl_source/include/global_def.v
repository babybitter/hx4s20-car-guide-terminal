


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// EM638325 requires 4096 refresh commands per 64ms, independent of ROW_WIDTH.
// Preserve parentheses at every macro expansion site. The old unparenthesized
// nested divisions evaluated to zero and disabled periodic refresh requests.
// S44 sys_pll C1/C2 = 1GHz / 20, exactly 20ns per hardware cycle.
`define SDR_CLK_PERIOD 20
// init_cnt counts inclusively from zero through this terminal value.
// floor(64ms / 20ns / 4096)=781 cycles; subtract one for terminal count.
// Legacy macro only: actual periodic service belongs to sdram_refresh_guard.
`define SELF_REFRESH_INTERVAL ((64000000 / `SDR_CLK_PERIOD / 4096) - 1)

