// Class-based constrained-random environment for the I-cache and D-cache.
//
//   cache_txn   : constrained-random core request (region, op, size, timing)
//   axil_slave  : AXI4-Lite memory with random READY / latency and error
//                 injection (DECERR window, poisoned lines for reads/writes)
//   cache_agent : drives the core-side port, owns the reference memory model
//                 (architectural view), checks every response in order and
//                 checks backing memory against the model after maintenance
package cache_tb_pkg;

  localparam bit [31:0] CACHE_BASE = 32'h8000_0000;   // cacheable RAM
  localparam bit [31:0] MMIO_BASE  = 32'h4000_0000;   // uncached, backed by memory
  localparam bit [31:0] ERR_BASE   = 32'h3000_0000;   // DECERR window (4 KB)
  localparam int        POISON_TAG = 40;               // lines at tags >= 40 are poisoned

  typedef enum bit [2:0] { R_HOT, R_RANDOM, R_SEQ, R_UNCACHED, R_ERR, R_POISON } region_e;

  // Deterministic initial memory contents shared by slave and reference model.
  function automatic bit [31:0] init_word(bit [31:0] a);
    return (a * 32'h9E37_79B1) ^ 32'hA5A5_5A5A;
  endfunction

  // ---------------------------------------------------------------------------
  class cache_txn;
    rand region_e     region;
    rand bit          we;
    rand bit [1:0]    size;        // 0 byte, 1 half, 2 word
    rand bit [5:0]    tag;         // line tag (2 KB apart -> same set)
    rand bit [6:0]    set;
    rand bit [1:0]    word;
    rand bit [1:0]    boff;
    rand bit [31:0]   wdata;
    rand bit [3:0]    gap;           // idle cycles before the request
    rand bit          retract;     // withdraw once if not granted (models a redirect)
    rand bit [9:0]    mmio_word;

    bit        allow_store = 1;
    bit        hot_only    = 0;     // eviction-storm mode: hot sets only
    bit [6:0]  hot_set0 = 7'd5, hot_set1 = 7'd77;
    bit [31:0] seq_addr;

    // Results of finalize()
    bit [31:0] addr;
    bit [3:0]  be;
    bit        expect_err;

    // Weighted choices are expressed through uniform selectors rather than
    // 'dist' (much cheaper for the simulator's SMT-based solver).
    rand bit [6:0] rsel, gsel, tsel;
    constraint c_sel    { rsel < 100; gsel < 100; tsel < 100; }
    constraint c_region { rsel <  40                -> region == R_HOT;
                          rsel inside {[40:69]}     -> region == R_RANDOM;
                          rsel inside {[70:81]}     -> region == R_SEQ;
                          rsel inside {[82:89]}     -> region == R_UNCACHED;
                          rsel inside {[90:95]}     -> region == R_ERR;
                          rsel >= 96                -> region == R_POISON; }
    constraint c_mode   { hot_only -> region == R_HOT; }
    constraint c_we     { !allow_store -> we == 0; }
    constraint c_size   { size inside {[0:2]};
                          size == 2 -> boff == 0;
                          size == 1 -> boff[0] == 0; }
    constraint c_tag    { region == R_POISON -> tag inside {[POISON_TAG:POISON_TAG + 1]};
                          region != R_POISON -> tag < POISON_TAG;
                          region == R_HOT    -> tag < 8; }
    constraint c_hot    { region == R_HOT -> set inside {hot_set0, hot_set1}; }
    constraint c_gap    { gsel <  70            -> gap == 0;
                          gsel inside {[70:94]} -> gap inside {[1:3]};
                          gsel >= 95            -> gap inside {[4:12]}; }
    constraint c_retr   { retract == (tsel < 6); }

    function void finalize(bit icache);
      bit [31:0] a;
      unique case (region)
        R_SEQ:      a = seq_addr;
        R_UNCACHED: a = MMIO_BASE + {20'b0, mmio_word, 2'b00};
        R_ERR:      a = ERR_BASE + {20'b0, mmio_word, 2'b00};
        default:    a = CACHE_BASE + {15'b0, tag, set, word, 2'b00};
      endcase
      if (icache) begin
        we = 0; size = 2; boff = 0;
      end
      addr = {a[31:2], 2'b00};
      unique case (size)
        2'd0:    be = 4'b0001 << boff;
        2'd1:    be = 4'b0011 << boff;
        default: be = 4'b1111;
      endcase
      if (!we) be = 4'b1111;
      expect_err = (region == R_ERR) || (region == R_POISON);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  class axil_slave;
    virtual axil_if vif;
    bit [31:0] mem [bit [31:0]];          // word-addressed backing store
    bit        rd_poison [bit [31:0]];    // line address -> SLVERR on read
    bit        wr_poison [bit [31:0]];    // line address -> SLVERR on write
    int        ready_pct = 100;
    int        max_lat   = 0;

    typedef struct { bit [31:0] data; bit [1:0] resp; int ready_at; } rsp_t;
    rsp_t      rq[$], bq[$];
    bit [31:0] awq[$];
    bit [35:0] wq[$];
    int        cyc;
    int        n_rd, n_wr, n_rd_err, n_wr_err;
    bit        drv_arready, drv_awready, drv_wready, drv_rvalid, drv_bvalid;

    function new(virtual axil_if v);
      vif = v;
    endfunction

    function bit [31:0] peek(bit [31:0] a);
      a = {a[31:2], 2'b00};
      return mem.exists(a) ? mem[a] : init_word(a);
    endfunction

    function void poke(bit [31:0] a, bit [31:0] d);
      mem[{a[31:2], 2'b00}] = d;
    endfunction

    function bit is_err_region(bit [31:0] a);
      return a[31:12] == ERR_BASE[31:12];
    endfunction

    function bit chance();
      return ready_pct >= 100 || ($urandom_range(99) < ready_pct);
    endfunction

    task run();
      vif.awready = 0; vif.wready = 0; vif.bvalid = 0; vif.bresp = 0;
      vif.arready = 0; vif.rvalid = 0; vif.rdata = 0; vif.rresp = 0;
      forever begin
        @(negedge vif.clk);
        drv_arready = rq.size() < 2 && chance();
        drv_awready = awq.size() < 2 && chance();
        drv_wready  = wq.size() < 2 && chance();
        drv_rvalid  = rq.size() > 0 && rq[0].ready_at <= cyc;
        drv_bvalid  = bq.size() > 0 && bq[0].ready_at <= cyc;
        vif.arready = drv_arready;
        vif.awready = drv_awready;
        vif.wready  = drv_wready;
        vif.rvalid  = drv_rvalid;
        vif.rdata   = drv_rvalid ? rq[0].data : 32'h0;
        vif.rresp   = drv_rvalid ? rq[0].resp : 2'b00;
        vif.bvalid  = drv_bvalid;
        vif.bresp   = drv_bvalid ? bq[0].resp : 2'b00;
        #1;
        // Handshakes that complete at the next rising edge
        if (drv_rvalid && vif.rready) void'(rq.pop_front());
        if (drv_bvalid && vif.bready) void'(bq.pop_front());
        if (vif.arvalid && drv_arready) begin
          rsp_t r;
          bit [31:0] a = {vif.araddr[31:2], 2'b00};
          r.ready_at = cyc + 1 + (max_lat ? $urandom_range(max_lat) : 0);
          r.data = peek(a);
          r.resp = 2'b00;
          if (is_err_region(a))                      begin r.resp = 2'b11; n_rd_err++; end
          else if (rd_poison.exists({a[31:4], 4'h0})) begin r.resp = 2'b10; n_rd_err++; end
          rq.push_back(r);
          n_rd++;
        end
        if (vif.awvalid && drv_awready) awq.push_back(vif.awaddr);
        if (vif.wvalid && drv_wready)   wq.push_back({vif.wstrb, vif.wdata});
        while (awq.size() > 0 && wq.size() > 0) begin
          rsp_t b;
          bit [31:0] a = {awq[0][31:2], 2'b00};
          bit [35:0] w = wq[0];
          void'(awq.pop_front());
          void'(wq.pop_front());
          b.ready_at = cyc + 1 + (max_lat ? $urandom_range(max_lat) : 0);
          b.data = 0;
          b.resp = 2'b00;
          if (is_err_region(a)) begin
            b.resp = 2'b11; n_wr_err++;
          end else if (wr_poison.exists({a[31:4], 4'h0})) begin
            b.resp = 2'b10; n_wr_err++;          // write dropped
          end else begin
            bit [31:0] d = peek(a);
            for (int i = 0; i < 4; i++) if (w[32 + i]) d[8*i +: 8] = w[8*i +: 8];
            mem[a] = d;
          end
          bq.push_back(b);
          n_wr++;
        end
        cyc++;
      end
    endtask
  endclass

  // ---------------------------------------------------------------------------
  class cache_agent;
    virtual cache_if vif;
    axil_slave slv;
    bit        icache;
    string     name;

    // Reference model: architectural memory contents seen by the core.
    bit [31:0] refm [bit [31:0]];
    bit        lost [bit [31:0]];     // words whose memory copy was dropped (write-back error)
    bit [31:0] stale [bit [31:0]];    // I$: old value still acceptable until invalidation

    cache_txn  tx;
    bit [31:0] seq_next = CACHE_BASE + 32'h100;
    int        n_req, n_checks, n_err_rsp, n_mismatch, n_maint, n_mem_checks, n_retract, n_stale_hits;

    function new(string nm, virtual cache_if v, axil_slave s, bit ic);
      name = nm; vif = v; slv = s; icache = ic;
      tx = new();
      tx.allow_store = !ic;
      // poison two cacheable lines for reads (refills fail)
      for (int t = POISON_TAG; t <= POISON_TAG + 1; t++)
        for (int st = 0; st < 128; st++)
          slv.rd_poison[CACHE_BASE + (t << 11) + (st << 4)] = 1;
    endfunction

    function bit [31:0] model(bit [31:0] a);
      return refm.exists(a) ? refm[a] : slv.peek(a);
    endfunction

    function void fail(string msg);
      n_mismatch++;
      $error("[%s] %s", name, msg);
    endfunction

    // Check a response against the model, then apply a successful store.
    function void check(cache_txn t, bit [31:0] rdata, bit err);
      n_checks++;
      if (err != t.expect_err) begin
        fail($sformatf("err mismatch addr=%h we=%0d got=%0d exp=%0d", t.addr, t.we, err, t.expect_err));
        return;
      end
      if (err) begin n_err_rsp++; return; end
      if (t.we) begin
        bit [31:0] d = model(t.addr);
        for (int i = 0; i < 4; i++) if (t.be[i]) d[8*i +: 8] = t.wdata[8*i +: 8];
        refm[t.addr] = d;
      end else if (!lost.exists(t.addr)) begin
        bit [31:0] exp = model(t.addr);
        if (rdata != exp) begin
          if (icache && stale.exists(t.addr) && rdata == stale[t.addr]) n_stale_hits++;
          else fail($sformatf("load data mismatch addr=%h got=%h exp=%h", t.addr, rdata, exp));
        end
      end
    endfunction

    // After clean/flush: backing memory must hold every modelled word.
    function void check_memory();
      foreach (refm[a]) begin
        if (lost.exists(a)) continue;
        n_mem_checks++;
        if (slv.peek(a) != refm[a])
          fail($sformatf("memory not coherent after maintenance addr=%h mem=%h model=%h",
                         a, slv.peek(a), refm[a]));
      end
    endfunction

    task idle(int n);
      repeat (n) @(negedge vif.clk);
    endtask

    // One maintenance operation (D$: clean / flush, I$: invalidate).
    task maint(bit inval);
      @(negedge vif.clk);
      vif.req = 0;
      vif.maint_req = 1;
      vif.maint_inval = inval;
      forever begin
        #1;
        if (vif.maint_done) break;
        @(negedge vif.clk);
      end
      @(negedge vif.clk);
      vif.maint_req = 0;
      n_maint++;
      if (!icache) check_memory();
      else stale.delete();
    endtask

    // Issue n random requests. Only one request is outstanding at a time
    // (the core never has more), but a new one may be accepted in the same
    // cycle the previous response returns.
    task traffic(int n, int maint_pct);
      cache_txn pend;
      bit       have_pend;
      int       issued = 0;
      bit       cur_valid = 0;
      int       wait_gap = 0;
      bit       retracted = 0;
      bit       maint_wanted = 0;
      have_pend = 0;
      while (issued < n || have_pend || cur_valid || maint_wanted) begin
        @(negedge vif.clk);
        // maintenance: decided at request-selection time, performed once the
        // outstanding response (if any) has returned
        if (maint_wanted && !have_pend) begin
          maint($urandom_range(1));
          maint_wanted = 0;
          continue;
        end
        // choose next request
        if (!cur_valid && !maint_wanted && issued < n && wait_gap == 0) begin
          if (maint_pct > 0 && $urandom_range(999) < maint_pct) begin
            maint_wanted = 1;
            vif.req = 0;
            #1;
            if (vif.rvalid) begin
              if (!have_pend) fail("response without request");
              else check(pend, vif.rdata, vif.err);
              have_pend = 0;
            end
            continue;
          end
          tx.seq_addr = seq_next;
          if (!tx.randomize()) $fatal(1, "randomize failed");
          tx.finalize(icache);
          if (tx.region == R_SEQ) seq_next = (seq_next + 4 >= CACHE_BASE + 32'h4000) ? CACHE_BASE : seq_next + 4;
          wait_gap = tx.gap;
          cur_valid = (wait_gap == 0);
          retracted = 0;
        end else if (!cur_valid && wait_gap > 0) begin
          wait_gap--;
          cur_valid = (wait_gap == 0);
        end
        vif.req   = cur_valid;
        vif.addr  = tx.addr;
        vif.we    = tx.we;
        vif.be    = tx.be;
        vif.wdata = tx.wdata;
        #1;
        if (vif.rvalid) begin
          if (!have_pend) fail("response without request");
          else check(pend, vif.rdata, vif.err);
          have_pend = 0;
        end
        if (cur_valid && vif.gnt) begin
          pend = new tx;            // shallow copy of the accepted request
          have_pend = 1;
          cur_valid = 0;
          issued++;
          n_req++;
        end else if (cur_valid && tx.retract && !retracted) begin
          // withdraw the un-granted request for a cycle, then re-present
          @(negedge vif.clk);
          vif.req = 0;
          retracted = 1;
          n_retract++;
          #1;
          if (vif.rvalid) begin
            if (!have_pend) fail("response without request");
            else check(pend, vif.rdata, vif.err);
            have_pend = 0;
          end
        end
      end
      @(negedge vif.clk);
      vif.req = 0;
    endtask

    function void report();
      $display("[%s] requests=%0d checks=%0d error_responses=%0d retractions=%0d maint_ops=%0d mem_word_checks=%0d stale_ok=%0d mismatches=%0d",
               name, n_req, n_checks, n_err_rsp, n_retract, n_maint, n_mem_checks, n_stale_hits, n_mismatch);
      $display("[%s] axi: reads=%0d writes=%0d read_errors=%0d write_errors=%0d",
               name, slv.n_rd, slv.n_wr, slv.n_rd_err, slv.n_wr_err);
    endfunction
  endclass

endpackage
