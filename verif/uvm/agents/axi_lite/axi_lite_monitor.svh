// axi_lite_monitor.svh - passive AXI4-Lite monitor
//
// Samples every channel through mon_cb, pairs AW/W/B (writes) and AR/R
// (reads) in order (AXI4-Lite has no IDs, responses are in order per
// direction) and publishes each completed transaction on `ap` with the
// handshake timestamps used by the scoreboard.
class axi_lite_monitor extends uvm_monitor;
  `uvm_component_utils(axi_lite_monitor)

  axi_lite_cfg        cfg;
  virtual axi_lite_if vif;

  uvm_analysis_port #(axi_lite_item) ap;

  typedef struct {
    bit [31:0]   addr;
    bit [2:0]    prot;
    realtime     t;
    int unsigned wait_cyc;
  } addr_beat_t;

  typedef struct {
    bit [31:0]   data;
    bit [3:0]    strb;
    realtime     t;
    int unsigned wait_cyc;
  } data_beat_t;

  protected addr_beat_t aw_q[$], ar_q[$];
  protected data_beat_t w_q[$];
  protected int unsigned aw_wait, w_wait, ar_wait, b_wait, r_wait;
  protected int unsigned wr_idle, rd_idle;
  int unsigned n_wr, n_rd;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null) `uvm_fatal("CFG", "axi_lite_monitor: cfg not set")
    vif = cfg.vif;
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);
      if (vif.aresetn !== 1'b1) begin
        aw_q.delete(); w_q.delete(); ar_q.delete();
        aw_wait = 0; w_wait = 0; ar_wait = 0; b_wait = 0; r_wait = 0;
        wr_idle = 0; rd_idle = 0;
        continue;
      end
      sample_cycle();
    end
  endtask

  protected function void sample_cycle();
    realtime now = $realtime;
    bit wr_busy, rd_busy;

    // ---------------- request channels ----------------
    if (vif.mon_cb.awvalid === 1'b1) begin
      if (vif.mon_cb.awready === 1'b1) begin
        addr_beat_t b;
        b.addr = vif.mon_cb.awaddr; b.prot = vif.mon_cb.awprot; b.t = now; b.wait_cyc = aw_wait;
        aw_q.push_back(b);
        aw_wait = 0;
      end else aw_wait++;
    end
    if (vif.mon_cb.wvalid === 1'b1) begin
      if (vif.mon_cb.wready === 1'b1) begin
        data_beat_t d;
        d.data = vif.mon_cb.wdata; d.strb = vif.mon_cb.wstrb; d.t = now; d.wait_cyc = w_wait;
        w_q.push_back(d);
        w_wait = 0;
      end else w_wait++;
    end
    if (vif.mon_cb.arvalid === 1'b1) begin
      if (vif.mon_cb.arready === 1'b1) begin
        addr_beat_t b;
        b.addr = vif.mon_cb.araddr; b.prot = vif.mon_cb.arprot; b.t = now; b.wait_cyc = ar_wait;
        ar_q.push_back(b);
        ar_wait = 0;
      end else ar_wait++;
    end

    // ---------------- write response ----------------
    if (vif.mon_cb.bvalid === 1'b1) begin
      if (vif.mon_cb.bready === 1'b1) begin
        if (aw_q.size() == 0 || w_q.size() == 0) begin
          `uvm_error("MON", "write response without matching AW/W handshake")
        end else begin
          axi_lite_item t = axi_lite_item::type_id::create("wr_tr");
          addr_beat_t a = aw_q.pop_front();
          data_beat_t d = w_q.pop_front();
          t.kind      = AXI_WRITE;
          t.addr      = a.addr;
          t.prot      = a.prot;
          t.data      = d.data;
          t.strb      = d.strb;
          t.resp      = axi_lite_resp_e'(vif.mon_cb.bresp);
          t.t_req     = (a.t < d.t) ? a.t : d.t;
          t.t_exec    = (a.t > d.t) ? a.t : d.t;
          t.t_resp    = now;
          t.req_wait  = a.wait_cyc + d.wait_cyc;
          t.resp_wait = b_wait;
          t.gap       = wr_idle;
          wr_idle     = 0;
          n_wr++;
          `uvm_info("MON", t.convert2string(), UVM_HIGH)
          ap.write(t);
        end
        b_wait = 0;
      end else b_wait++;
    end

    // ---------------- read response ----------------
    if (vif.mon_cb.rvalid === 1'b1) begin
      if (vif.mon_cb.rready === 1'b1) begin
        if (ar_q.size() == 0) begin
          `uvm_error("MON", "read response without matching AR handshake")
        end else begin
          axi_lite_item t = axi_lite_item::type_id::create("rd_tr");
          addr_beat_t a = ar_q.pop_front();
          t.kind      = AXI_READ;
          t.addr      = a.addr;
          t.prot      = a.prot;
          t.data      = vif.mon_cb.rdata;
          t.strb      = 4'hF;
          t.resp      = axi_lite_resp_e'(vif.mon_cb.rresp);
          t.t_req     = a.t;
          t.t_exec    = a.t;
          t.t_resp    = now;
          t.req_wait  = a.wait_cyc;
          t.resp_wait = r_wait;
          t.gap       = rd_idle;
          rd_idle     = 0;
          n_rd++;
          `uvm_info("MON", t.convert2string(), UVM_HIGH)
          ap.write(t);
        end
        r_wait = 0;
      end else r_wait++;
    end

    // Idle-cycle counters used for back-to-back coverage
    wr_busy = (vif.mon_cb.awvalid === 1'b1) || (vif.mon_cb.wvalid === 1'b1) ||
              (vif.mon_cb.bvalid === 1'b1) || aw_q.size() != 0 || w_q.size() != 0;
    rd_busy = (vif.mon_cb.arvalid === 1'b1) || (vif.mon_cb.rvalid === 1'b1) || ar_q.size() != 0;
    if (!wr_busy) wr_idle++;
    if (!rd_busy) rd_idle++;
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("MON", $sformatf("observed %0d writes, %0d reads", n_wr, n_rd), UVM_LOW)
  endfunction

endclass
