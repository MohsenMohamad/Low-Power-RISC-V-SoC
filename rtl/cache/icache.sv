// Instruction cache: 4 KB, 2-way set-associative, 16-byte lines, read-only,
// 1-bit LRU per set. AXI4-Lite master (read channels only).
//
// Valid bits live in flip-flops so invalidate-all completes in one cycle.
// Two cacheable regions (typically boot ROM and RAM); other addresses are
// fetched uncached. A refill bus error is returned as err on the response and
// the line is left invalid.
module icache #(
  parameter logic [31:0] CACHE0_BASE = 32'h0000_0000,
  parameter logic [31:0] CACHE0_MASK = 32'hFFFF_C000,   // 16 KB boot ROM
  parameter logic [31:0] CACHE1_BASE = 32'h8000_0000,
  parameter logic [31:0] CACHE1_MASK = 32'hFFFE_0000    // 128 KB RAM
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        req_i,
  output logic        gnt_o,
  input  logic [31:0] addr_i,
  output logic        rvalid_o,
  output logic [31:0] rdata_o,
  output logic        err_o,

  input  logic        inval_req_i,
  output logic        inval_done_o,

  // AXI4-Lite master (write channels tied off)
  /* verilator lint_off UNUSEDSIGNAL */  // write responses never occur; rresp[0] irrelevant
  output logic        m_awvalid,
  input  logic        m_awready,
  output logic [31:0] m_awaddr,
  output logic [2:0]  m_awprot,
  output logic        m_wvalid,
  input  logic        m_wready,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  input  logic        m_bvalid,
  output logic        m_bready,
  input  logic [1:0]  m_bresp,
  output logic        m_arvalid,
  input  logic        m_arready,
  output logic [31:0] m_araddr,
  output logic [2:0]  m_arprot,
  input  logic        m_rvalid,
  output logic        m_rready,
  input  logic [31:0] m_rdata,
  input  logic [1:0]  m_rresp,
  /* verilator lint_on UNUSEDSIGNAL */

  output logic        idle_o
);

  localparam int WAYS  = 2;
  localparam int SETS  = 128;
  localparam int IDX_W = 7;
  localparam int TAG_W = 21;

  typedef enum logic [2:0] {
    S_IDLE, S_LOOKUP, S_RF_AR, S_RF_R, S_REPLAY, S_UC_AR, S_UC_R
  } state_e;

  state_e state_q, state_d;

/* verilator lint_off UNUSEDSIGNAL */ // byte offset bits unused (word fetches)
  logic [31:0]     rq_addr_q;
/* verilator lint_on UNUSEDSIGNAL */
  logic [SETS-1:0] valid_q [WAYS];
  logic [SETS-1:0] lru_q;
  logic            victim_q;
  logic [1:0]      cnt_q;
  logic            rf_err_q;

  logic             tag_en [WAYS];
  logic             tag_we [WAYS];
  logic [IDX_W-1:0] tag_addr;
  logic [TAG_W-1:0] tag_rdata [WAYS];
  logic             dat_en [WAYS];
  logic             dat_we [WAYS];
  logic [IDX_W+1:0] dat_addr;
  logic [31:0]      dat_rdata [WAYS];

  logic [IDX_W-1:0] rq_idx;
  logic [TAG_W-1:0] rq_tag;
  assign rq_idx = rq_addr_q[10:4];
  assign rq_tag = rq_addr_q[31:11];

  for (genvar w = 0; w < WAYS; w++) begin : g_way
    tech_sram_sp #(.DEPTH(SETS), .WIDTH(TAG_W)) u_tag (
      .clk, .en(tag_en[w]), .we(tag_we[w]), .addr(tag_addr),
      .wdata(rq_tag), .wmask({TAG_W{1'b1}}), .rdata(tag_rdata[w])
    );
    tech_sram_sp #(.DEPTH(SETS*4), .WIDTH(32)) u_data (
      .clk, .en(dat_en[w]), .we(dat_we[w]), .addr(dat_addr),
      .wdata(m_rdata), .wmask('1), .rdata(dat_rdata[w])
    );
  end

  function automatic logic is_cacheable(input logic [31:0] a);
    return ((a & CACHE0_MASK) == CACHE0_BASE) || ((a & CACHE1_MASK) == CACHE1_BASE);
  endfunction

  logic [WAYS-1:0] hit_vec;
  logic hit, hit_way, victim_sel, accept;
  for (genvar w = 0; w < WAYS; w++) begin : g_hit
    assign hit_vec[w] = valid_q[w][rq_idx] && (tag_rdata[w] == rq_tag);
  end
  assign hit     = |hit_vec;
  assign hit_way = hit_vec[1];
  assign victim_sel = !valid_q[0][rq_idx] ? 1'b0 :
                      !valid_q[1][rq_idx] ? 1'b1 : lru_q[rq_idx];

  assign gnt_o  = !inval_req_i && ((state_q == S_IDLE) || (state_q == S_LOOKUP && hit));
  assign accept = req_i && gnt_o;
  assign idle_o = (state_q == S_IDLE);

  // Tie off write channels
  assign m_awvalid = 1'b0;
  assign m_awaddr  = '0;
  assign m_awprot  = 3'b101;
  assign m_wvalid  = 1'b0;
  assign m_wdata   = '0;
  assign m_wstrb   = '0;
  assign m_bready  = 1'b1;
  assign m_arprot  = 3'b101;   // privileged, non-secure, instruction

  always_comb begin
    state_d = state_q;
    for (int w = 0; w < WAYS; w++) begin
      tag_en[w] = 1'b0; tag_we[w] = 1'b0;
      dat_en[w] = 1'b0; dat_we[w] = 1'b0;
    end
    tag_addr = rq_idx;
    dat_addr = rq_addr_q[10:2];
    rvalid_o = 1'b0;
    rdata_o  = dat_rdata[hit_way];
    err_o    = 1'b0;
    inval_done_o = 1'b0;
    m_arvalid = 1'b0;
    m_araddr  = '0;
    m_rready  = 1'b0;

    unique case (state_q)
      S_IDLE: begin
        if (inval_req_i) inval_done_o = 1'b1;
      end
      S_LOOKUP: begin
        if (hit) begin
          rvalid_o = 1'b1;
          state_d  = S_IDLE;
        end else begin
          state_d = S_RF_AR;
        end
      end
      S_RF_AR: begin
        m_arvalid = 1'b1;
        m_araddr  = {rq_tag, rq_idx, cnt_q, 2'b00};
        if (m_arready) state_d = S_RF_R;
      end
      S_RF_R: begin
        m_rready = 1'b1;
        if (m_rvalid) begin
          dat_en[victim_q] = 1'b1;
          dat_we[victim_q] = 1'b1;
          dat_addr         = {rq_idx, cnt_q};
          if (cnt_q != 2'd3) begin
            state_d = S_RF_AR;
          end else if (rf_err_q || m_rresp[1]) begin
            rvalid_o = 1'b1;
            err_o    = 1'b1;
            state_d  = S_IDLE;
          end else begin
            tag_en[victim_q] = 1'b1;
            tag_we[victim_q] = 1'b1;
            state_d = S_REPLAY;
          end
        end
      end
      S_REPLAY: begin
        for (int w = 0; w < WAYS; w++) begin
          tag_en[w] = 1'b1;
          dat_en[w] = 1'b1;
        end
        state_d = S_LOOKUP;
      end
      S_UC_AR: begin
        m_arvalid = 1'b1;
        m_araddr  = {rq_addr_q[31:2], 2'b00};
        if (m_arready) state_d = S_UC_R;
      end
      S_UC_R: begin
        m_rready = 1'b1;
        if (m_rvalid) begin
          rvalid_o = 1'b1;
          rdata_o  = m_rdata;
          err_o    = m_rresp[1];
          state_d  = S_IDLE;
        end
      end
      default: state_d = S_IDLE;
    endcase

    if (accept) begin
      if (is_cacheable(addr_i)) begin
        for (int w = 0; w < WAYS; w++) begin
          tag_en[w] = 1'b1;
          dat_en[w] = 1'b1;
        end
        tag_addr = addr_i[10:4];
        dat_addr = addr_i[10:2];
        state_d  = S_LOOKUP;
      end else begin
        state_d = S_UC_AR;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q   <= S_IDLE;
      for (int w = 0; w < WAYS; w++) valid_q[w] <= '0;
      lru_q     <= '0;
      victim_q  <= 1'b0;
      cnt_q     <= '0;
      rf_err_q  <= 1'b0;
      rq_addr_q <= '0;
    end else begin
      state_q <= state_d;
      if (accept) rq_addr_q <= addr_i;

      if (state_q == S_IDLE && inval_req_i) begin
        for (int w = 0; w < WAYS; w++) valid_q[w] <= '0;
      end

      unique case (state_q)
        S_LOOKUP: begin
          if (hit) begin
            lru_q[rq_idx] <= !hit_way;
          end else begin
            victim_q                    <= victim_sel;
            valid_q[victim_sel][rq_idx] <= 1'b0;
            cnt_q                       <= '0;
            rf_err_q                    <= 1'b0;
          end
        end
        S_RF_R: begin
          if (m_rvalid) begin
            cnt_q <= cnt_q + 2'd1;
            if (m_rresp[1]) rf_err_q <= 1'b1;
            if (cnt_q == 2'd3 && !(rf_err_q || m_rresp[1])) begin
              valid_q[victim_q][rq_idx] <= 1'b1;
              lru_q[rq_idx]             <= !victim_q;
            end
          end
        end
        default: ;
      endcase
    end
  end

endmodule
