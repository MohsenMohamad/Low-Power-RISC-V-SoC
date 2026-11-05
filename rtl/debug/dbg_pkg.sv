// Debug subsystem package: shared constants (see doc/DEBUG_SPEC.md).
package dbg_pkg;
  localparam logic [15:0] ID_MAGIC   = 16'hDB60;
  localparam logic [7:0]  ID_VERSION = 8'h01;

  localparam logic [7:0] BLK_TRACE  = 8'd1;
  localparam logic [7:0] BLK_EVCNT  = 8'd2;
  localparam logic [7:0] BLK_ERRLOG = 8'd3;
  localparam logic [7:0] BLK_WDT    = 8'd4;

  // Power-state encoding (pwr_state_i).
  localparam logic [1:0] PS_RUN    = 2'd0;
  localparam logic [1:0] PS_IDLE   = 2'd1;
  localparam logic [1:0] PS_SLEEP  = 2'd2;
  localparam logic [1:0] PS_DSLEEP = 2'd3;

  // Trace entry types.
  localparam logic [1:0] TE_RETIRE = 2'd0;
  localparam logic [1:0] TE_TRAP   = 2'd1;
  localparam logic [1:0] TE_PWR    = 2'd2;

  // Trigger selects.
  localparam logic [1:0] TRIG_NONE = 2'd0;
  localparam logic [1:0] TRIG_PC   = 2'd1;
  localparam logic [1:0] TRIG_EXC  = 2'd2;
  localparam logic [1:0] TRIG_PWR  = 2'd3;

  localparam logic [31:0] WDT_KICK_KEY = 32'h5A5AA5A5;

  function automatic logic [31:0] id_word(input logic [7:0] blk);
    return {ID_MAGIC, blk, ID_VERSION};
  endfunction

  function automatic logic [31:0] bin2gray(input logic [31:0] b);
    return b ^ (b >> 1);
  endfunction
endpackage
