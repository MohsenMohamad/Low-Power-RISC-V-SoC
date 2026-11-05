// Testbench for the PicoRV32 bring-up SoC.
//
// Plusargs:
//   +rom_hex=<f> +ram_hex=<f>   memory preload (word-wide $readmemh)
//   +test=<n>                   test id passed to firmware (default: all)
//   +monitor                    ask firmware to start the UART monitor
//   +uart_in=<f>                bytes fed to UART RX, one line per prompt
//   +prompt=<s>                 prompt that releases the next line ("mon> ")
//   +wake_prompt=<s>            second such prompt ("zzz> ": the firmware
//                               sleeps until UART input); the next line is
//                               held back +wake_delay=<n> clk_aon cycles
//                               (default 60000) so the CPU is asleep first
//   +uart_log=<f>               copy of everything received from UART TX
//   +timeout=<n>                abort after n clk_aon cycles (default 50M)
//
// Simulation control device on the SoC external port (0x4F00_0000):
//   0x00 EXIT  W: end simulation, 0 = pass, otherwise fail code
//   0x04 ARG   R: [31] testbench present [30] monitor mode [15:0] test id
//   0x08 PUTC  W: print character directly (debug)
//   0x0C TIME  R: clk_aon cycle counter (low 32 bits)
module tb_top;
    timeunit 1ns; timeprecision 1ps;
    // Testbench-only constructs (clock generators, string building in the
    // UART decoder, power-on reset) are not synthesizable by design.
    /* verilator lint_off BLKSEQ */
    /* verilator lint_off SYNCASYNCNET */

    localparam int UART_DIV = 8;

    logic clk_aon = 1'b0, clk_ref = 1'b0, por_n = 1'b0;
    always #15.5 clk_aon = ~clk_aon;     // ~32.3 MHz always-on clock
    always #5.0  clk_ref = ~clk_ref;     // 100 MHz DVFS reference

    logic        uart_rxd, uart_txd;
    logic        ext_req, ext_we;
    logic [15:0] ext_addr;
    logic [31:0] ext_wdata, ext_rdata;
    logic        cpu_trap, cpu_pwr, cpu_iso, ram_ret;

    pico_soc #(.UART_DIV(16'(UART_DIV))) dut (
        .clk_aon(clk_aon), .clk_ref(clk_ref), .por_n(por_n),
        .uart_rxd(uart_rxd), .uart_txd(uart_txd),
        .ext_req(ext_req), .ext_we(ext_we), .ext_addr(ext_addr),
        .ext_wdata(ext_wdata), .ext_rdata(ext_rdata),
        .cpu_trap(cpu_trap), .cpu_pwr(cpu_pwr), .cpu_iso(cpu_iso), .ram_ret(ram_ret));

    // ---------------- configuration ----------------
    longint unsigned cycles = 0;
    longint unsigned timeout = 64'd50_000_000;
    logic [31:0] arg;
    integer log_fd = 0;
    string  prompt = "mon> ";
    string  wake_prompt = "zzz> ";
    int unsigned wake_delay = 60000;

    initial begin
        string s;
        int unsigned t;
        arg = 32'h8000_FFFF;
        if ($value$plusargs("test=%d", t)) arg[15:0] = t[15:0];
        if ($test$plusargs("monitor")) arg[30] = 1'b1;
        if ($value$plusargs("timeout=%d", timeout)) ;
        if ($value$plusargs("prompt=%s", s)) prompt = s;
        if ($value$plusargs("wake_prompt=%s", s)) wake_prompt = s;
        if ($value$plusargs("wake_delay=%d", t)) wake_delay = t;
        if ($value$plusargs("uart_log=%s", s)) log_fd = $fopen(s, "w");
        #200 por_n = 1'b1;
    end

    always_ff @(posedge clk_aon) begin
        cycles <= cycles + 1;
        if (cycles == timeout) begin
            $display("\n[TB] TIMEOUT after %0d clk_aon cycles", cycles);
            finish_sim(32'hDEAD_0001);
        end
    end

    task automatic finish_sim(input logic [31:0] code);
        if (code == 0) $display("[TB] SIM RESULT: PASS (cycles=%0d)", cycles);
        else           $display("[TB] SIM RESULT: FAIL code=0x%08x (cycles=%0d)", code, cycles);
        if (log_fd != 0) $fclose(log_fd);
        $finish;
    endtask

    // ---------------- debug: PMU state trace, clock probe ----------------
    logic pmu_trace = 1'b0;
    initial pmu_trace = $test$plusargs("pmu_trace");
    logic [4:0] pmu_st_q = '0;
    always_ff @(posedge clk_aon) begin
        pmu_st_q <= 5'(dut.u_pmu.st);
        if (pmu_trace && 5'(dut.u_pmu.st) != pmu_st_q)
            $display("[TB] %0t PMU state %0d -> %0d (wfi=%b irq=%b%b%b mode=%0d)", $time, pmu_st_q,
                     5'(dut.u_pmu.st), dut.u_pmu.wfi_s, dut.irq_meip, dut.irq_msip, dut.irq_mtip, dut.u_pmu.mode);
    end
    always @(posedge dut.clk_cpu) begin
        if (pmu_trace && dut.u_pmu.mode != 0 && dut.u_pd_cpu.u_core.instr_waitirq)
            $display("[TB] %0t waitirq: irq_pending=%08x mask=%08x do_waitirq=%b irq=%08x", $time,
                     dut.u_pd_cpu.u_core.irq_pending, dut.u_pd_cpu.u_core.irq_mask,
                     dut.u_pd_cpu.u_core.do_waitirq, dut.u_pd_cpu.irq);
    end
    longint unsigned cpu_edges = 0;
    always @(posedge dut.clk_cpu) cpu_edges <= cpu_edges + 1;
    initial begin
        if ($test$plusargs("clk_probe")) begin
            longint unsigned c0, a0;
            forever begin
                c0 = cpu_edges; a0 = cycles;
                #1000000;
                $display("[TB] clk probe: %0d cpu edges / %0d aon edges, mtime=%0d",
                         cpu_edges - c0, cycles - a0, dut.u_timer.mtime);
            end
        end
    end

    // ---------------- simulation control device ----------------
    always_ff @(posedge clk_aon) begin
        if (ext_req && ext_we) begin
            unique case (ext_addr[7:0])
                8'h00: finish_sim(ext_wdata);
                8'h08: $write("%c", ext_wdata[7:0]);
                default: ;
            endcase
        end
        if (ext_req && !ext_we) begin
            unique case (ext_addr[7:0])
                8'h04:   ext_rdata <= arg;
                8'h0C:   ext_rdata <= cycles[31:0];
                default: ext_rdata <= 32'd0;
            endcase
        end
    end

    always_ff @(posedge clk_aon) begin
        if (por_n && cpu_trap) begin
            $display("\n[TB] CPU entered TRAP state (unrecoverable exception)");
            finish_sim(32'hDEAD_0002);
        end
    end

    function automatic bit ends_with(string s, string suffix);
        if (suffix.len() == 0 || s.len() < suffix.len()) return 1'b0;
        return s.substr(s.len() - suffix.len(), s.len() - 1) == suffix;
    endfunction

    // ---------------- UART TX decoder ----------------
    typedef enum logic [1:0] {T_IDLE, T_START, T_DATA, T_STOP} tst_t;
    tst_t        tst = T_IDLE;
    int unsigned tcnt = 0, tbit = 0;
    logic [7:0]  tsh;
    string       tail = "";
    logic        prompt_seen = 1'b0;
    logic        line_sent;
    int unsigned rx_hold = 0;

    always_ff @(posedge clk_aon) begin
        if (line_sent) prompt_seen <= 1'b0;
        if (rx_hold != 0) rx_hold <= rx_hold - 1;
        unique case (tst)
            T_IDLE:  if (!uart_txd) begin tst <= T_START; tcnt <= 0; end
            T_START: if (tcnt == UART_DIV/2 - 1) begin tcnt <= 0; tbit <= 0; tst <= uart_txd ? T_IDLE : T_DATA; end
                     else tcnt <= tcnt + 1;
            T_DATA:  if (tcnt == UART_DIV - 1) begin
                         tcnt <= 0; tsh <= {uart_txd, tsh[7:1]};
                         if (tbit == 7) tst <= T_STOP; else tbit <= tbit + 1;
                     end else tcnt <= tcnt + 1;
            T_STOP:  if (tcnt == UART_DIV - 1) begin
                         tcnt <= 0; tst <= T_IDLE;
                         if (!uart_txd) $display("\n[TB] UART framing error");
                         $write("%c", tsh);
                         if (log_fd != 0) $fwrite(log_fd, "%c", tsh);
                         tail = {tail, string'(tsh)};
                         if (tail.len() > 32) tail = tail.substr(tail.len() - 32, tail.len() - 1);
                         if (ends_with(tail, prompt)) prompt_seen <= 1'b1;
                         if (ends_with(tail, wake_prompt)) begin
                             prompt_seen <= 1'b1;
                             rx_hold     <= wake_delay;
                         end
                     end else tcnt <= tcnt + 1;
            default: tst <= T_IDLE;
        endcase
    end

    // ---------------- UART RX driver ----------------
    byte unsigned rx_buf[$];
    initial begin
        string f;
        int fd, c;
        if ($value$plusargs("uart_in=%s", f)) begin
            fd = $fopen(f, "rb");
            if (fd == 0) begin $display("[TB] cannot open %s", f); $finish; end
            while ((c = $fgetc(fd)) != -1) rx_buf.push_back(byte'(c));
            $fclose(fd);
        end
    end

    typedef enum logic [1:0] {R_WAIT, R_BYTE, R_GAP} rst_t;
    rst_t        rst_q = R_WAIT;
    logic [9:0]  rsh;
    int unsigned rcnt = 0, rbit = 0;
    logic        in_line = 1'b0;
    assign uart_rxd = (rst_q == R_BYTE) ? rsh[0] : 1'b1;

    always_ff @(posedge clk_aon) begin
        line_sent <= 1'b0;
        unique case (rst_q)
            R_WAIT: if (rx_buf.size() != 0 && (in_line || (prompt_seen && rx_hold == 0))) begin
                        byte unsigned b;
                        b = rx_buf.pop_front();
                        rsh <= {1'b1, b, 1'b0};
                        rcnt <= 0; rbit <= 0;
                        in_line <= (b != 8'h0A);
                        if (b == 8'h0A) line_sent <= 1'b1;
                        rst_q <= R_BYTE;
                    end
            R_BYTE: if (rcnt == UART_DIV - 1) begin
                        rcnt <= 0; rsh <= {1'b1, rsh[9:1]};
                        if (rbit == 9) rst_q <= R_GAP; else rbit <= rbit + 1;
                    end else rcnt <= rcnt + 1;
            R_GAP:  if (rcnt == 4 * UART_DIV) begin rcnt <= 0; rst_q <= R_WAIT; end
                    else rcnt <= rcnt + 1;
            default: rst_q <= R_WAIT;
        endcase
    end
    /* verilator lint_on SYNCASYNCNET */
    /* verilator lint_on BLKSEQ */
endmodule
