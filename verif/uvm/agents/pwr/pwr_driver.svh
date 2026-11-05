// pwr_driver.svh - reactive model of the power switch, the CPU and the wake
// sources around a switchable domain.
//
// A single per-cycle loop owns every driven pin:
//   * power switch : power_good follows the switch enable with a random
//                    latency (cfg.pgood_on_*/pgood_off_*)
//   * CPU          : raises WFI on request once the domain is running, drops
//                    it when the domain clock restarts or the domain is reset
//   * wake IRQs    : PWR_WAKE bits are held until the CPU runs again and are
//                    then cleared after a random service time
//   * domain outs  : random garbage while the domain is not running
// Sequence items only post requests into this model.
class pwr_driver extends uvm_driver #(pwr_item);
  `uvm_component_utils(pwr_driver)

  pwr_cfg        cfg;
  virtual pwr_if vif;

  // model state
  protected bit             pg_val, pg_tgt;
  protected int unsigned    pg_cnt;
  protected bit             wfi_val, wfi_req;
  protected int             wfi_drop_cnt;
  protected bit             clk_en_q;
  protected bit [IRQ_W-1:0] irq_level, irq_auto;
  protected int             irq_clr_cnt;
  protected bit [ISO_W-1:0] dom_val;
  protected event           wfi_taken;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null) `uvm_fatal("CFG", "pwr_driver: cfg not set")
    vif = cfg.vif;
  endfunction

  task run_phase(uvm_phase phase);
    vif.drive_reset();
    fork
      model_loop();
      item_loop();
    join
  endtask

  // ---------------------------------------------------------------------------
  protected function void reset_model();
    pg_val = 0; pg_tgt = 0; pg_cnt = 0;
    wfi_val = 0; wfi_req = 0; wfi_drop_cnt = -1; clk_en_q = 0;
    irq_level = '0; irq_auto = '0; irq_clr_cnt = -1;
    dom_val = '0;
  endfunction

  protected task model_loop();
    reset_model();
    forever begin
      @(vif.drv_cb);
      if (vif.rst_n !== 1'b1) begin
        reset_model();
        vif.drv_cb.pwr_good <= 1'b0;
        vif.drv_cb.wfi      <= 1'b0;
        vif.drv_cb.wake_irq <= '0;
        vif.drv_cb.dom_out  <= '0;
        continue;
      end
      step_model();
    end
  endtask

  protected function void step_model();
    bit pwr_en    = (vif.drv_cb.pwr_en    === 1'b1);
    bit clk_en    = (vif.drv_cb.clk_en    === 1'b1);
    bit iso_en    = (vif.drv_cb.iso_en    !== 1'b0);
    bit dom_rst_n = (vif.drv_cb.dom_rst_n === 1'b1);
    bit running;

    // ---------------- power switch ----------------
    if (pwr_en != pg_tgt) begin
      pg_tgt = pwr_en;
      pg_cnt = pwr_en ? $urandom_range(cfg.pgood_on_max,  cfg.pgood_on_min)
                      : $urandom_range(cfg.pgood_off_max, cfg.pgood_off_min);
    end
    if (pg_val != pg_tgt) begin
      if (pg_cnt == 0) pg_val = pg_tgt;
      else             pg_cnt--;
    end

    running = clk_en && !iso_en && dom_rst_n && pg_val;

    // ---------------- CPU: WFI ----------------
    if (!dom_rst_n || !pg_val) begin
      wfi_val = 0;
      wfi_drop_cnt = -1;
    end else begin
      if (wfi_val && clk_en && !clk_en_q) wfi_drop_cnt = cfg.wfi_exit_delay;
      if (wfi_drop_cnt == 0) begin wfi_val = 0; wfi_drop_cnt = -1; end
      else if (wfi_drop_cnt > 0) wfi_drop_cnt--;
      if (wfi_req && running && !wfi_val) begin
        wfi_val = 1;
        wfi_req = 0;
        -> wfi_taken;
      end
    end
    clk_en_q = clk_en;

    // ---------------- wake IRQs ----------------
    if (irq_auto != 0) begin
      if (running && !wfi_val) begin
        if (irq_clr_cnt < 0) irq_clr_cnt = $urandom_range(cfg.irq_clear_max, cfg.irq_clear_min);
        else if (irq_clr_cnt == 0) begin irq_auto = '0; irq_clr_cnt = -1; end
        else irq_clr_cnt--;
      end else irq_clr_cnt = -1;
    end

    // ---------------- domain outputs ----------------
    if (cfg.rand_dom_out && (!running || ($urandom_range(7) == 0)))
      dom_val = ISO_W'({$urandom, $urandom});

    vif.drv_cb.pwr_good <= pg_val;
    vif.drv_cb.wfi      <= wfi_val;
    vif.drv_cb.wake_irq <= irq_level | irq_auto;
    vif.drv_cb.dom_out  <= dom_val;
  endfunction

  // ---------------------------------------------------------------------------
  protected task item_loop();
    pwr_item req;
    forever begin
      seq_item_port.get_next_item(req);
      `uvm_info("PWRDRV", req.convert2string(), UVM_HIGH)
      if (req.op != PWR_WAIT) repeat (req.cycles) @(vif.drv_cb);
      case (req.op)
        PWR_WFI: begin
          wfi_req = 1;
          fork : f_wfi
            @(wfi_taken);
            begin repeat (100000) @(vif.drv_cb); req.timed_out = 1; wfi_req = 0; end
          join_any
          disable f_wfi;
          if (req.timed_out) `uvm_error("PWRDRV", "WFI request: domain never reached running state")
        end
        PWR_WAKE:    irq_auto  |= req.irq;
        PWR_IRQ_SET: irq_level |= req.irq;
        PWR_IRQ_CLR: irq_level &= ~req.irq;
        PWR_DOM_OUT: dom_val    = req.dom_out;
        PWR_WAIT:    repeat (req.cycles) @(vif.drv_cb);
        default: ;
      endcase
      seq_item_port.item_done();
    end
  endtask

endclass
