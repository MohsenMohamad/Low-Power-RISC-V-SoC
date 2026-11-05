// axi_lite_driver.svh - AXI4-Lite master driver
//
// One transaction at a time (AXI4-Lite slaves commonly accept one outstanding
// access). Back-to-back items are driven without idle cycles when all delays
// are zero. For writes AW and W are driven by independent threads so that
// AW-before-W, W-before-AW and simultaneous orders are all exercised.
// The response (resp, read data) is written back into the request item.
class axi_lite_driver extends uvm_driver #(axi_lite_item);
  `uvm_component_utils(axi_lite_driver)

  axi_lite_cfg        cfg;
  virtual axi_lite_if vif;

  // Time of the most recent drv_cb clocking event. A synchronous drive issued
  // in that time step takes effect at that edge; issued later (e.g. when a
  // sequence produces an item between edges) it would only take effect at
  // the next edge, so the driver first re-aligns to the clock.
  protected realtime last_edge = -1;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null) `uvm_fatal("CFG", "axi_lite_driver: cfg not set")
    vif = cfg.vif;
  endfunction

  task run_phase(uvm_phase phase);
    axi_lite_item req;
    vif.master_reset();
    fork
      forever begin
        @(vif.drv_cb);
        last_edge = $realtime;
      end
    join_none
    forever begin
      // Hold idle while in reset
      while (vif.aresetn !== 1'b1) begin
        vif.master_reset();
        @(posedge vif.aclk);
      end
      seq_item_port.get_next_item(req);
      if ($realtime != last_edge) @(vif.drv_cb);
      `uvm_info("DRV", {"start ", req.convert2string()}, UVM_HIGH)
      fork begin
        fork
          begin
            if (req.kind == AXI_WRITE) drive_write(req);
            else                       drive_read(req);
          end
          begin
            @(negedge vif.aresetn);
            `uvm_warning("DRV", "reset asserted during a transaction; aborted")
            req.resp = AXI_SLVERR;
          end
        join_any
        disable fork;
      end join
      `uvm_info("DRV", {"done  ", req.convert2string()}, UVM_HIGH)
      seq_item_port.item_done();
    end
  endtask

  // ---------------------------------------------------------------------------
  protected task automatic drive_aw(axi_lite_item t);
    int unsigned n = 0;
    repeat (t.aw_delay) @(vif.drv_cb);
    vif.drv_cb.awaddr  <= t.addr;
    vif.drv_cb.awprot  <= t.prot;
    vif.drv_cb.awvalid <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (++n > cfg.handshake_timeout) `uvm_fatal("DRV", "AWREADY timeout")
    end while (vif.drv_cb.awready !== 1'b1);
    vif.drv_cb.awvalid <= 1'b0;
    if (cfg.rand_idle_payload) vif.drv_cb.awaddr <= $urandom;
  endtask

  protected task automatic drive_w(axi_lite_item t);
    int unsigned n = 0;
    repeat (t.w_delay) @(vif.drv_cb);
    vif.drv_cb.wdata  <= t.data;
    vif.drv_cb.wstrb  <= t.strb;
    vif.drv_cb.wvalid <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (++n > cfg.handshake_timeout) `uvm_fatal("DRV", "WREADY timeout")
    end while (vif.drv_cb.wready !== 1'b1);
    vif.drv_cb.wvalid <= 1'b0;
    if (cfg.rand_idle_payload) begin
      vif.drv_cb.wdata <= $urandom;
      vif.drv_cb.wstrb <= 4'($urandom);
    end
  endtask

  protected task automatic drive_write(axi_lite_item t);
    int unsigned n = 0;
    fork
      drive_aw(t);
      drive_w(t);
    join
    repeat (t.bready_delay) @(vif.drv_cb);
    vif.drv_cb.bready <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (++n > cfg.handshake_timeout) `uvm_fatal("DRV", "BVALID timeout")
    end while (vif.drv_cb.bvalid !== 1'b1);
    t.resp = axi_lite_resp_e'(vif.drv_cb.bresp);
    vif.drv_cb.bready <= 1'b0;
  endtask

  protected task automatic drive_read(axi_lite_item t);
    int unsigned n = 0;
    repeat (t.ar_delay) @(vif.drv_cb);
    vif.drv_cb.araddr  <= t.addr;
    vif.drv_cb.arprot  <= t.prot;
    vif.drv_cb.arvalid <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (++n > cfg.handshake_timeout) `uvm_fatal("DRV", "ARREADY timeout")
    end while (vif.drv_cb.arready !== 1'b1);
    vif.drv_cb.arvalid <= 1'b0;
    if (cfg.rand_idle_payload) vif.drv_cb.araddr <= $urandom;
    // RREADY may be raised before RVALID arrives
    repeat (t.rready_delay) @(vif.drv_cb);
    vif.drv_cb.rready <= 1'b1;
    n = 0;
    do begin
      @(vif.drv_cb);
      if (++n > cfg.handshake_timeout) `uvm_fatal("DRV", "RVALID timeout")
    end while (vif.drv_cb.rvalid !== 1'b1);
    t.data = vif.drv_cb.rdata;
    t.resp = axi_lite_resp_e'(vif.drv_cb.rresp);
    vif.drv_cb.rready <= 1'b0;
  endtask

endclass
