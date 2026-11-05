// Data cache: 4 KB, 2-way set-associative, 16-byte lines, write-back,
// write-allocate, 1-bit LRU per set. AXI4-Lite master (single-beat transfers).
//
// Core side uses the request/response protocol described in core_fetch.sv.
// A cacheable load hit returns data the cycle after acceptance and can accept
// the next request in that same cycle. A store hit writes the line in the
// lookup cycle and accepts the next request one cycle later.
//
// Maintenance (maint_req level until maint_done pulse; only issued while no
// core request is outstanding):
//   maint_inval=0 : clean   - write back every dirty line, keep lines valid
//   maint_inval=1 : flush   - write back dirty lines and invalidate everything
// Write-back errors (BRESP != OKAY) are imprecise; they set wb_err_o.
//   * A line written back by clean/flush is marked clean (and, for flush,
//     invalid) only after all four write responses arrived without error. A
//     line with a failed write-back stays valid and dirty, so cache_clean_o
//     stays low and the next maintenance operation retries it.
//   * A failed eviction write-back (data lost) is remembered in evict_err_q and
//     reported by the next maintenance operation even though that operation
//     starts by clearing wb_err_o.
//   * wb_err_o at maint_done = error in this operation OR an eviction error
//     since the previous maintenance operation.
// cache_clean_o (registered) = no valid dirty line and no eviction write-back
// in progress, i.e. memory holds every value written to the cache.
module dcache #(
  parameter logic [31:0] CACHE_BASE = 32'h8000_0000,
  parameter logic [31:0] CACHE_MASK = 32'hFFFE_0000   // cacheable: (a & MASK) == BASE
) (
  input  logic        clk,
  input  logic        rst_n,

  // Core side
  input  logic        req_i,
  output logic        gnt_o,
  input  logic [31:0] addr_i,
  input  logic        we_i,
  input  logic [3:0]  be_i,
  input  logic [31:0] wdata_i,
  output logic        rvalid_o,
  output logic [31:0] rdata_o,
  output logic        err_o,

  input  logic        maint_req_i,
  input  logic        maint_inval_i,
  output logic        maint_done_o,
  output logic        wb_err_o,
  output logic        cache_clean_o,   // no dirty lines (registered)

  // AXI4-Lite master
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
/* verilator lint_off UNUSEDSIGNAL */ // only bit 1 (SLVERR/DECERR) matters
  input  logic [1:0]  m_bresp,
/* verilator lint_on UNUSEDSIGNAL */
  output logic        m_arvalid,
  input  logic        m_arready,
  output logic [31:0] m_araddr,
  output logic [2:0]  m_arprot,
  input  logic        m_rvalid,
  output logic        m_rready,
  input  logic [31:0] m_rdata,
/* verilator lint_off UNUSEDSIGNAL */ // only bit 1 (SLVERR/DECERR) matters
  input  logic [1:0]  m_rresp,
/* verilator lint_on UNUSEDSIGNAL */

  // Status for coverage / power management
  output logic        idle_o
);

  localparam int WAYS  = 2;
  localparam int SETS  = 128;
  localparam int IDX_W = 7;
  localparam int TAG_W = 21;

  typedef enum logic [4:0] {
    S_IDLE, S_LOOKUP,
    S_WB_RD, S_WB_W, S_WB_B,
    S_RF_AR, S_RF_R, S_REPLAY,
    S_UC_AR, S_UC_R, S_UC_AW, S_UC_B,
    S_FL_SCAN, S_FL_TAG, S_FL_DONE
  } state_e;

  state_e state_q, state_d;

  // Request register
  logic [31:0] rq_addr_q;
  logic        rq_we_q;
  logic [3:0]  rq_be_q;
  logic [31:0] rq_wdata_q;

  // Line state
  logic [SETS-1:0] valid_q [WAYS];
  logic [SETS-1:0] dirty_q [WAYS];
  logic [SETS-1:0] lru_q;            // way to replace next

  // Miss / maintenance context
  logic             victim_q;
  logic [TAG_W-1:0] victim_tag_q;
  logic [IDX_W-1:0] line_idx_q;
  logic [1:0]       cnt_q;
  logic             wb_for_flush_q;
  logic             aw_done_q, w_done_q;
  logic             rf_err_q;
  logic             wb_err_q;
  logic             evict_err_q;      // eviction write-back failed since last maintenance
  logic             line_err_q;       // a beat of the current write-back failed
  logic             clean_q;
  logic             fl_inval_q;

  // SRAM ports
  logic             tag_en   [WAYS];
  logic             tag_we   [WAYS];
  logic [IDX_W-1:0] tag_addr;
  logic [TAG_W-1:0] tag_wdata;
  logic [TAG_W-1:0] tag_rdata [WAYS];
  logic             dat_en   [WAYS];
  logic             dat_we   [WAYS];
  logic [IDX_W+1:0] dat_addr;
  logic [31:0]      dat_wdata;
  logic [31:0]      dat_wmask;
  logic [31:0]      dat_rdata [WAYS];

  for (genvar w = 0; w < WAYS; w++) begin : g_way
    tech_sram_sp #(.DEPTH(SETS), .WIDTH(TAG_W)) u_tag (
      .clk, .en(tag_en[w]), .we(tag_we[w]), .addr(tag_addr),
      .wdata(tag_wdata), .wmask({TAG_W{1'b1}}), .rdata(tag_rdata[w])
    );
    tech_sram_sp #(.DEPTH(SETS*4), .WIDTH(32)) u_data (
      .clk, .en(dat_en[w]), .we(dat_we[w]), .addr(dat_addr),
      .wdata(dat_wdata), .wmask(dat_wmask), .rdata(dat_rdata[w])
    );
  end

  // ---------------------------------------------------------------------------
  // Address fields
  // ---------------------------------------------------------------------------
  function automatic logic is_cacheable(input logic [31:0] a);
    return (a & CACHE_MASK) == CACHE_BASE;
  endfunction

  logic [IDX_W-1:0] rq_idx;
  logic [TAG_W-1:0] rq_tag;
  logic [1:0]       rq_word;
  assign rq_idx  = rq_addr_q[10:4];
  assign rq_tag  = rq_addr_q[31:11];
  assign rq_word = rq_addr_q[3:2];

  // Lookup
  logic [WAYS-1:0] hit_vec;
  logic            hit, hit_way;
  for (genvar w = 0; w < WAYS; w++) begin : g_hit
    assign hit_vec[w] = valid_q[w][rq_idx] && (tag_rdata[w] == rq_tag);
  end
  assign hit     = |hit_vec;
  assign hit_way = hit_vec[1];

  logic victim_sel;
  assign victim_sel = !valid_q[0][rq_idx] ? 1'b0 :
                      !valid_q[1][rq_idx] ? 1'b1 : lru_q[rq_idx];

  // Flush scan position (reuses line_idx_q as set and victim_q as way)
  logic fl_line_dirty, fl_last;
  assign fl_last = (line_idx_q == IDX_W'(SETS - 1)) && victim_q;
  assign fl_line_dirty = valid_q[victim_q][line_idx_q] && dirty_q[victim_q][line_idx_q];

  logic accept;
  logic lookup_load_hit;
  assign lookup_load_hit = (state_q == S_LOOKUP) && hit && !rq_we_q;

  assign gnt_o  = !maint_req_i && ((state_q == S_IDLE) || lookup_load_hit);
  assign accept = req_i && gnt_o;

  assign wb_err_o      = wb_err_q;
  assign cache_clean_o = clean_q;
  assign idle_o   = (state_q == S_IDLE);

  // ---------------------------------------------------------------------------
  // Combinational control
  // ---------------------------------------------------------------------------
  always_comb begin
    state_d = state_q;

    for (int w = 0; w < WAYS; w++) begin
      tag_en[w] = 1'b0; tag_we[w] = 1'b0;
      dat_en[w] = 1'b0; dat_we[w] = 1'b0;
    end
    tag_addr  = rq_idx;
    tag_wdata = rq_tag;
    dat_addr  = {rq_idx, rq_word};
    dat_wdata = rq_wdata_q;
    dat_wmask = {{8{rq_be_q[3]}}, {8{rq_be_q[2]}}, {8{rq_be_q[1]}}, {8{rq_be_q[0]}}};

    rvalid_o = 1'b0;
    rdata_o  = dat_rdata[hit_way];
    err_o    = 1'b0;
    maint_done_o = 1'b0;

    m_awvalid = 1'b0; m_awaddr = '0; m_awprot = 3'b001;
    m_wvalid  = 1'b0; m_wdata  = '0; m_wstrb  = 4'hF;
    m_bready  = 1'b0;
    m_arvalid = 1'b0; m_araddr = '0; m_arprot = 3'b001;
    m_rready  = 1'b0;

    unique case (state_q)
      S_IDLE: begin
        if (maint_req_i) state_d = S_FL_SCAN;
      end

      S_LOOKUP: begin
        if (hit) begin
          rvalid_o = 1'b1;
          if (rq_we_q) begin
            dat_en[hit_way] = 1'b1;
            dat_we[hit_way] = 1'b1;
          end
          state_d = S_IDLE;
        end else begin
          state_d = (valid_q[victim_sel][rq_idx] && dirty_q[victim_sel][rq_idx]) ? S_WB_RD : S_RF_AR;
        end
      end

      // ---------------- write-back of one line (4 beats) ----------------------
      S_WB_RD: begin
        dat_en[victim_q] = 1'b1;
        dat_addr         = {line_idx_q, cnt_q};
        state_d          = S_WB_W;
      end
      S_WB_W: begin
        m_awvalid = !aw_done_q;
        m_awaddr  = {victim_tag_q, line_idx_q, cnt_q, 2'b00};
        m_wvalid  = !w_done_q;
        m_wdata   = dat_rdata[victim_q];
        if ((aw_done_q || m_awready) && (w_done_q || m_wready)) state_d = S_WB_B;
      end
      S_WB_B: begin
        m_bready = 1'b1;
        if (m_bvalid) begin
          if (cnt_q != 2'd3)       state_d = S_WB_RD;
          else if (wb_for_flush_q) state_d = fl_last ? S_FL_DONE : S_FL_SCAN;
          else                     state_d = S_RF_AR;
        end
      end

      // ---------------- refill (4 beats) --------------------------------------
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
          dat_wdata        = m_rdata;
          dat_wmask        = '1;
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

      // ---------------- uncached --------------------------------------------
      S_UC_AR: begin
        m_arvalid = 1'b1;
        m_araddr  = rq_addr_q;
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
      S_UC_AW: begin
        m_awvalid = !aw_done_q;
        m_awaddr  = rq_addr_q;
        m_wvalid  = !w_done_q;
        m_wdata   = rq_wdata_q;
        m_wstrb   = rq_be_q;
        if ((aw_done_q || m_awready) && (w_done_q || m_wready)) state_d = S_UC_B;
      end
      S_UC_B: begin
        m_bready = 1'b1;
        if (m_bvalid) begin
          rvalid_o = 1'b1;
          err_o    = m_bresp[1];
          state_d  = S_IDLE;
        end
      end

      // ---------------- maintenance -----------------------------------------
      S_FL_SCAN: begin
        if (fl_line_dirty) begin
          tag_en[victim_q] = 1'b1;
          tag_addr         = line_idx_q;
          state_d          = S_FL_TAG;
        end else if (fl_last) begin
          state_d = S_FL_DONE;
        end
      end
      S_FL_TAG: begin
        state_d = S_WB_RD;
      end
      S_FL_DONE: begin
        maint_done_o = 1'b1;
        state_d      = S_IDLE;
      end

      default: state_d = S_IDLE;
    endcase

    // New request accepted (IDLE, or LOOKUP with a load hit)
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
        state_d = we_i ? S_UC_AW : S_UC_AR;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Sequential
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q        <= S_IDLE;
      for (int w = 0; w < WAYS; w++) begin
        valid_q[w] <= '0;
        dirty_q[w] <= '0;
      end
      lru_q          <= '0;
      victim_q       <= 1'b0;
      victim_tag_q   <= '0;
      line_idx_q     <= '0;
      cnt_q          <= '0;
      wb_for_flush_q <= 1'b0;
      aw_done_q      <= 1'b0;
      w_done_q       <= 1'b0;
      rf_err_q       <= 1'b0;
      wb_err_q       <= 1'b0;
      evict_err_q    <= 1'b0;
      line_err_q     <= 1'b0;
      clean_q        <= 1'b1;
      fl_inval_q     <= 1'b0;
      rq_addr_q      <= '0;
      rq_we_q        <= 1'b0;
      rq_be_q        <= '0;
      rq_wdata_q     <= '0;
    end else begin
      state_q <= state_d;

      if (accept) begin
        rq_addr_q  <= addr_i;
        rq_we_q    <= we_i;
        rq_be_q    <= be_i;
        rq_wdata_q <= wdata_i;
      end

      unique case (state_q)
        S_IDLE: begin
          if (maint_req_i) begin
            line_idx_q <= '0;
            victim_q   <= 1'b0;
            fl_inval_q <= maint_inval_i;
            wb_err_q   <= evict_err_q;   // lost eviction data is reported by this op
          end
        end

        S_LOOKUP: begin
          if (hit) begin
            lru_q[rq_idx] <= !hit_way;
            if (rq_we_q) dirty_q[hit_way][rq_idx] <= 1'b1;
          end else begin
            // Miss: the victim line is invalidated now; its data and tag stay in
            // the SRAMs long enough to be written back.
            victim_q                    <= victim_sel;
            victim_tag_q                <= tag_rdata[victim_sel];
            line_idx_q                  <= rq_idx;
            valid_q[victim_sel][rq_idx] <= 1'b0;
            dirty_q[victim_sel][rq_idx] <= 1'b0;
            wb_for_flush_q              <= 1'b0;
            line_err_q                  <= 1'b0;
            cnt_q                       <= '0;
            rf_err_q                    <= 1'b0;
            aw_done_q                   <= 1'b0;
            w_done_q                    <= 1'b0;
          end
        end

        S_WB_W: begin
          if (m_awvalid && m_awready) aw_done_q <= 1'b1;
          if (m_wvalid && m_wready)   w_done_q  <= 1'b1;
        end
        S_WB_B: begin
          if (m_bvalid) begin
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
            if (m_bresp[1]) begin
              wb_err_q   <= 1'b1;
              line_err_q <= 1'b1;
              if (!wb_for_flush_q) evict_err_q <= 1'b1;
            end
            cnt_q <= cnt_q + 2'd1;
            // Clean only after the last write response, and only if no beat
            // of this line failed; otherwise the line stays valid and dirty.
            if (cnt_q == 2'd3 && wb_for_flush_q && !line_err_q && !m_bresp[1]) begin
              dirty_q[victim_q][line_idx_q] <= 1'b0;
              if (fl_inval_q) valid_q[victim_q][line_idx_q] <= 1'b0;
            end
          end
        end

        S_RF_R: begin
          if (m_rvalid) begin
            cnt_q <= cnt_q + 2'd1;
            if (m_rresp[1]) rf_err_q <= 1'b1;
            if (cnt_q == 2'd3 && !(rf_err_q || m_rresp[1])) begin
              valid_q[victim_q][rq_idx] <= 1'b1;
              dirty_q[victim_q][rq_idx] <= 1'b0;
              lru_q[rq_idx]             <= !victim_q;
            end
          end
        end

        S_UC_AW: begin
          if (m_awvalid && m_awready) aw_done_q <= 1'b1;
          if (m_wvalid && m_wready)   w_done_q  <= 1'b1;
        end
        S_UC_B: begin
          if (m_bvalid) begin
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
          end
        end

        S_FL_SCAN: begin
          if (fl_line_dirty) begin
            wb_for_flush_q <= 1'b1;
            line_err_q     <= 1'b0;
            cnt_q          <= '0;
            aw_done_q      <= 1'b0;
            w_done_q       <= 1'b0;
          end else begin
            if (fl_inval_q) valid_q[victim_q][line_idx_q] <= 1'b0;
            victim_q <= !victim_q;
            if (victim_q) line_idx_q <= line_idx_q + 1'b1;
          end
        end
        S_FL_TAG: begin
          victim_tag_q <= tag_rdata[victim_q];
        end

        default: ;
      endcase

      if (state_q == S_FL_DONE) evict_err_q <= 1'b0;   // reported by this op

      clean_q <= !(|(dirty_q[0] & valid_q[0])) && !(|(dirty_q[1] & valid_q[1])) &&
                 !(state_q inside {S_WB_RD, S_WB_W, S_WB_B, S_FL_TAG}) &&
                 !(state_d inside {S_WB_RD, S_WB_W, S_WB_B, S_FL_TAG});

      // After a flush write-back the scan resumes at the next way/set
      if (state_q == S_WB_B && m_bvalid && cnt_q == 2'd3 && wb_for_flush_q) begin
        victim_q <= !victim_q;
        if (victim_q) line_idx_q <= line_idx_q + 1'b1;
      end
    end
  end

endmodule
