// tb_magnitude_calc.v — Unit testbench for magnitude_calc
// TC-01 ~ TC-05 per Phase 3 spec

`timescale 1ns / 1ps

module tb_magnitude_calc;

    // ----------------------------------------------------------------
    // Clock & reset
    // ----------------------------------------------------------------
    reg clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    reg rst_n;

    // ----------------------------------------------------------------
    // DUT signals
    // ----------------------------------------------------------------
    reg  [31:0] s_tdata;
    reg         s_tvalid;
    reg         s_tlast;
    wire        s_tready;

    wire [15:0] m_tdata;
    wire        m_tvalid;
    wire        m_tlast;
    reg         m_tready;

    magnitude_calc #(
        .DATA_WIDTH(32),
        .OUT_WIDTH (16)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (s_tdata),
        .s_axis_tvalid (s_tvalid),
        .s_axis_tlast  (s_tlast),
        .s_axis_tready (s_tready),
        .m_axis_tdata  (m_tdata),
        .m_axis_tvalid (m_tvalid),
        .m_axis_tlast  (m_tlast),
        .m_axis_tready (m_tready)
    );

    // ----------------------------------------------------------------
    // Capture output (NBA per feedback rule)
    // ----------------------------------------------------------------
    integer out_total = 0;
    integer tlast_cnt = 0;

    reg [15:0] cap_data;
    reg        cap_last;
    reg        cap_valid;

    always @(posedge clk) begin
        cap_valid <= m_tvalid & m_tready;
        cap_data  <= m_tdata;
        cap_last  <= m_tlast;
        if (m_tvalid & m_tready) begin
            out_total <= out_total + 1;
            if (m_tlast)
                tlast_cnt <= tlast_cnt + 1;
        end
    end

    // ----------------------------------------------------------------
    // Tasks — sender uses blocking per feedback rule
    // ----------------------------------------------------------------
    task send_one(input [15:0] re, input [15:0] im, input last);
    begin
        s_tdata  = {im, re};
        s_tvalid = 1;
        s_tlast  = last;
        @(posedge clk);
        while (!s_tready) @(posedge clk);
        s_tvalid = 0;
        s_tlast  = 0;
    end
    endtask

    // Send without de-asserting between beats (for back-to-back)
    task send_stream(input [15:0] re, input [15:0] im, input last);
    begin
        s_tdata  = {im, re};
        s_tvalid = 1;
        s_tlast  = last;
        @(posedge clk);
        while (!s_tready) @(posedge clk);
        // keep tvalid high — caller will de-assert after last beat
    end
    endtask

    // ----------------------------------------------------------------
    // Error tracking
    // ----------------------------------------------------------------
    integer err_cnt = 0;

    task check(input [15:0] expected, input [15:0] got, input [159:0] label);
    begin
        if (got !== expected) begin
            $display("  FAIL %0s: expected %0d, got %0d", label, expected, got);
            err_cnt = err_cnt + 1;
        end
    end
    endtask

    // ----------------------------------------------------------------
    // LFSR-based pseudo-random for backpressure (deterministic, no $urandom)
    // ----------------------------------------------------------------
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge clk) begin
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end

    // ----------------------------------------------------------------
    // Main test
    // ----------------------------------------------------------------
    integer i, j;
    reg [15:0] re_val, im_val;
    integer saved_total;
    integer expected_total;

    initial begin
        rst_n    = 0;
        s_tdata  = 0;
        s_tvalid = 0;
        s_tlast  = 0;
        m_tready = 1;
        #50;
        rst_n = 1;
        #20;

        // ============================================================
        // TC-01: Known magnitude verification
        // ============================================================
        $display("[TC-01] Known magnitude values");
        m_tready = 1;

        send_one(16'sd100,   16'sd0,     0);  @(posedge clk); check(16'd100,   cap_data, "Re=100,Im=0");
        send_one(16'sd0,     16'sd100,   0);  @(posedge clk); check(16'd100,   cap_data, "Re=0,Im=100");
        send_one(16'sd100,   16'sd100,   0);  @(posedge clk); check(16'd200,   cap_data, "Re=100,Im=100");
        send_one(-16'sd100,  16'sd50,    0);  @(posedge clk); check(16'd150,   cap_data, "Re=-100,Im=50");
        send_one(16'h8000,   16'sd0,     0);  @(posedge clk); check(16'd32768, cap_data, "Re=-32768,Im=0");
        send_one(16'sd0,     16'h8000,   0);  @(posedge clk); check(16'd32768, cap_data, "Re=0,Im=-32768");
        send_one(16'sd0,     16'sd0,     0);  @(posedge clk); check(16'd0,     cap_data, "Re=0,Im=0");
        send_one(16'sd32767, 16'sd32767, 0);  @(posedge clk); check(16'd65534, cap_data, "Re=32767,Im=32767");
        send_one(16'h8000,   16'h8000,   1);  @(posedge clk); check(16'd65535, cap_data, "Re=-32768,Im=-32768 SAT");

        $display("  TC-01 done, errors so far: %0d", err_cnt);

        #20;

        // ============================================================
        // TC-02: Backpressure — 1024 samples, random tready
        // ============================================================
        $display("[TC-02] Backpressure test (1024 samples)");
        @(posedge clk);  // let NBA settle
        saved_total = out_total;
        fork
            // Backpressure generator (drive on negedge for clean sampling)
            begin
                for (j = 0; j < 4096; j = j + 1) begin
                    @(negedge clk);
                    m_tready = lfsr[0];
                end
                @(negedge clk);
                m_tready = 1;  // release
            end
            // Sender
            begin
                for (i = 0; i < 1024; i = i + 1) begin
                    re_val = i[15:0];
                    im_val = (1024 - i);
                    send_stream(re_val, im_val, (i == 1023));
                end
                s_tvalid = 0;
                s_tlast  = 0;
            end
        join

        // Drain remaining
        m_tready = 1;
        #200;

        expected_total = saved_total + 1024;
        if (out_total < expected_total) begin
            // Wait more for stragglers
            repeat (2048) @(posedge clk);
        end
        if (out_total !== expected_total) begin
            $display("  FAIL TC-02: expected %0d outputs, got %0d", expected_total, out_total);
            err_cnt = err_cnt + 1;
        end else begin
            $display("  TC-02 PASS: 1024 samples received under backpressure");
        end

        #20;

        // ============================================================
        // TC-03: tlast propagation — 2 frames x 1024
        // ============================================================
        $display("[TC-03] tlast propagation (2 frames)");
        m_tready = 1;
        saved_total = tlast_cnt;

        // Frame 1
        for (i = 0; i < 1024; i = i + 1) begin
            send_stream(i[15:0], 16'd0, (i == 1023));
        end
        // Frame 2
        for (i = 0; i < 1024; i = i + 1) begin
            send_stream(i[15:0], 16'd1, (i == 1023));
        end
        s_tvalid = 0;
        s_tlast  = 0;

        #100;
        if (tlast_cnt !== saved_total + 2) begin
            $display("  FAIL TC-03: expected %0d tlast, got %0d", saved_total + 2, tlast_cnt);
            err_cnt = err_cnt + 1;
        end else begin
            $display("  TC-03 PASS: 2 tlast received");
        end

        #20;

        // ============================================================
        // TC-04: Fast toggling backpressure — every 1~2 cycles
        // ============================================================
        $display("[TC-04] Fast backpressure toggle (1024 samples)");
        @(posedge clk);  // let NBA settle
        saved_total = out_total;

        fork
            // Fast toggle: 1-cycle on, 1-cycle off (worst case, drive on negedge)
            begin
                for (j = 0; j < 8192; j = j + 1) begin
                    @(negedge clk);
                    m_tready = ~m_tready;
                end
                @(negedge clk);
                m_tready = 1;
            end
            // Sender
            begin
                for (i = 0; i < 1024; i = i + 1) begin
                    re_val = 16'sd500;
                    im_val = 16'sd300;
                    send_stream(re_val, im_val, (i == 1023));
                end
                s_tvalid = 0;
                s_tlast  = 0;
            end
        join

        m_tready = 1;
        repeat (2048) @(posedge clk);

        expected_total = saved_total + 1024;
        if (out_total !== expected_total) begin
            $display("  FAIL TC-04: expected %0d outputs, got %0d", expected_total, out_total);
            err_cnt = err_cnt + 1;
        end else begin
            $display("  TC-04 PASS: 1024 samples under fast toggle");
        end

        #20;

        // ============================================================
        // TC-05: Back-to-back frames (no gap between tlast and next tvalid)
        // ============================================================
        $display("[TC-05] Back-to-back frames");
        m_tready = 1;
        saved_total = tlast_cnt;

        // Frame A (8 samples for brevity)
        for (i = 0; i < 8; i = i + 1)
            send_stream(16'sd10, 16'sd20, (i == 7));
        // Frame B immediately follows — no gap, no de-assert
        for (i = 0; i < 8; i = i + 1)
            send_stream(16'sd30, 16'sd40, (i == 7));
        s_tvalid = 0;
        s_tlast  = 0;

        #100;
        if (tlast_cnt !== saved_total + 2) begin
            $display("  FAIL TC-05: expected %0d tlast, got %0d", saved_total + 2, tlast_cnt);
            err_cnt = err_cnt + 1;
        end else begin
            $display("  TC-05 PASS: back-to-back frames OK");
        end

        // ============================================================
        // Summary
        // ============================================================
        #50;
        $display("========================================");
        if (err_cnt == 0)
            $display("ALL TESTS PASSED  (TC-01 ~ TC-05)");
        else
            $display("FAILED: %0d errors", err_cnt);
        $display("========================================");
        $finish;
    end

endmodule
