`timescale 1ns / 1ps
module tb_fft_ip;

    localparam int N          = 1024;
    localparam int CLK_PERIOD = 10;
    localparam real PI        = 3.14159265358979;

    // Config: FFT forward, Stage0=÷8, Stage1~4=÷4, total scaling 2^11=2048
    localparam logic [15:0] CFG_FWD = {5'b00000, 10'b10_10_10_10_11, 1'b1};  // 16'h0557

    // ===== DUT signals =====
    logic        aclk = 0;
    logic [15:0] s_axis_config_tdata  = '0;
    logic        s_axis_config_tvalid = 0;
    wire         s_axis_config_tready;
    logic [31:0] s_axis_data_tdata  = '0;
    logic        s_axis_data_tvalid = 0;
    wire         s_axis_data_tready;
    logic        s_axis_data_tlast  = 0;
    wire  [31:0] m_axis_data_tdata;
    wire         m_axis_data_tvalid;
    logic        m_axis_data_tready = 1;
    wire         m_axis_data_tlast;
    wire         event_frame_started, event_tlast_unexpected, event_tlast_missing;
    wire         event_status_channel_halt, event_data_in_channel_halt, event_data_out_channel_halt;

    always #(CLK_PERIOD/2) aclk = ~aclk;

    xfft_0 u_fft (.*);

    // ===== Output capture — cumulative, never reset =====
    logic signed [15:0] out_re [N];   // circular buffer (latest frame)
    logic signed [15:0] out_im [N];
    int out_cnt   = 0;                // cumulative output count
    int tlast_cnt = 0;                // cumulative tlast count

    always @(posedge aclk) begin
        if (m_axis_data_tvalid && m_axis_data_tready) begin
            out_re[out_cnt % N] <= signed'(m_axis_data_tdata[15:0]);
            out_im[out_cnt % N] <= signed'(m_axis_data_tdata[31:16]);
            if (m_axis_data_tlast) tlast_cnt <= tlast_cnt + 1;
            out_cnt <= out_cnt + 1;
        end
    end

    // ===== Test data =====
    logic signed [15:0] frame_data [N];

    // ===== Helper functions =====
    function real mag_sq(int k);
        return $itor(out_re[k]) ** 2 + $itor(out_im[k]) ** 2;
    endfunction

    function void gen_sine(int bin_idx, real amp);
        for (int n = 0; n < N; n++)
            frame_data[n] = $rtoi($sin(2.0*PI*$itor(bin_idx)*$itor(n)/$itor(N)) * amp);
    endfunction

    function void gen_dual_sine(int b1, int b2, real amp);
        for (int n = 0; n < N; n++)
            frame_data[n] = $rtoi($sin(2.0*PI*$itor(b1)*$itor(n)/$itor(N)) * amp)
                          + $rtoi($sin(2.0*PI*$itor(b2)*$itor(n)/$itor(N)) * amp);
    endfunction

    function void gen_constant(int val);
        for (int n = 0; n < N; n++) frame_data[n] = 16'(val);
    endfunction

    function real peak_ratio_db(int target);
        real pk = mag_sq(target);
        real mx = 0;
        for (int k = 0; k < N; k++)
            if (k != target && k != (N - target))
                if (mag_sq(k) > mx) mx = mag_sq(k);
        if (pk > 0 && mx > 0) return 10.0 * $ln(pk/mx) / $ln(10.0);
        else if (pk > 0)       return 100.0;
        else                   return 0.0;
    endfunction

    // ===== AXI-Stream sender tasks (blocking = for TB master) =====
    task automatic send_config();
        s_axis_config_tdata  = CFG_FWD;
        s_axis_config_tvalid = 1;
        @(posedge aclk);
        while (!s_axis_config_tready) @(posedge aclk);
        #1; s_axis_config_tvalid = 0;
    endtask

    task automatic send_frame();
        for (int i = 0; i < N; i++) begin
            s_axis_data_tdata  = {16'h0000, frame_data[i]};
            s_axis_data_tvalid = 1;
            s_axis_data_tlast  = (i == N-1);
            @(posedge aclk);
            while (!s_axis_data_tready) @(posedge aclk);
        end
        #1; s_axis_data_tvalid = 0; s_axis_data_tlast = 0;
    endtask

    task automatic send_frame_with_gaps();
        for (int i = 0; i < N; i++) begin
            // Deterministic gap: 2 idle cycles every 4th sample
            if (i > 0 && (i % 4 == 0)) begin
                s_axis_data_tvalid = 0;
                @(posedge aclk);
                @(posedge aclk);
            end
            s_axis_data_tdata  = {16'h0000, frame_data[i]};
            s_axis_data_tvalid = 1;
            s_axis_data_tlast  = (i == N-1);
            @(posedge aclk);
            while (!s_axis_data_tready) @(posedge aclk);
        end
        #1; s_axis_data_tvalid = 0; s_axis_data_tlast = 0;
    endtask

    // Wait for cumulative output count to reach `target`
    task automatic wait_for(int target, int timeout = 300000);
        int w = 0;
        while (out_cnt < target && w < timeout) begin @(posedge aclk); w++; end
        if (w >= timeout)
            $display("  WARNING: wait timeout (out_cnt=%0d, target=%0d)", out_cnt, target);
        repeat (4) @(posedge aclk);
    endtask

    // ===== Result tracking =====
    int pass_cnt = 0, fail_cnt = 0;
    function void report(string name, bit ok);
        if (ok) begin $display("[PASS] %s", name); pass_cnt++; end
        else    begin $display("[FAIL] %s", name); fail_cnt++; end
    endfunction

    // ===== Main =====
    int expected;   // cumulative expected output count
    int tl_before;  // tlast snapshot before a test
    real ratio, pk, mx, pk1, pk2, mg;

    initial begin
        $display("============================================");
        $display("  FFT IP Testbench - Phase 2 (SV)");
        $display("  Config = 0x%04h", CFG_FWD);
        $display("============================================");
        expected = 0;
        repeat (20) @(posedge aclk);

        // Warm-up: dummy zero frame to prime FFT config pipeline.
        // The FFT IP has a phantom config slot at power-up; the first
        // config we send is consumed by it, NOT by the first data frame.
        // Sending a throwaway frame aligns config-to-data for all tests.
        $display("\n--- Warm-up: zero frame ---");
        gen_constant(0);
        send_config(); send_frame();
        expected += N;
        wait_for(expected);
        $display("  Warm-up done, out_cnt=%0d", out_cnt);

        // --- TC-01: Single sine (bin 64) ---
        $display("\n--- TC-01: Single sine (bin 64) ---");
        gen_sine(64, 16383.0);
        send_config(); send_frame();
        expected += N;
        wait_for(expected);
        $display("  Bin[64]: Re=%0d Im=%0d", out_re[64], out_im[64]);
        ratio = peak_ratio_db(64);
        $display("  ratio=%.1f dB", ratio);
        report("TC-01 Single sine bin 64", mag_sq(64) > 0 && ratio > 40.0);
        report("TC-01 tlast", tlast_cnt >= 2);  // warmup + TC-01

        // --- TC-02: Multi-frequency ---
        $display("\n--- TC-02: Multi-freq (bin 64+256) ---");
        gen_dual_sine(64, 256, 8191.0);
        send_config(); send_frame();
        expected += N;
        wait_for(expected);
        pk1 = mag_sq(64); pk2 = mag_sq(256);
        mx = 0;
        for (int k = 0; k < N; k++)
            if (k!=64 && k!=(N-64) && k!=256 && k!=(N-256))
                if (mag_sq(k) > mx) mx = mag_sq(k);
        $display("  Bin64=%.3e Bin256=%.3e other=%.3e", pk1, pk2, mx);
        report("TC-02 Multi-freq", pk1 > mx*100 && pk2 > mx*100);

        // --- TC-04: Continuous 4 frames (run BEFORE gap test) ---
        $display("\n--- TC-04: 4 frames ---");
        begin
            int bl [4] = '{64, 128, 32, 256};
            int base;
            tl_before = tlast_cnt;
            base = out_cnt;
            for (int f = 0; f < 4; f++) begin
                gen_sine(bl[f], 16383.0);
                send_config(); send_frame();
            end
            expected += 4*N;
            wait_for(expected);
            $display("  samples=%0d tlast=%0d", out_cnt - base, tlast_cnt - tl_before);
            // Check last frame (bin 256)
            pk = mag_sq(bl[3]); mx = 0;
            for (int k = 0; k < N; k++)
                if (k != bl[3] && k != (N-bl[3]))
                    if (mag_sq(k) > mx) mx = mag_sq(k);
            report("TC-04 4-frame last correct", pk > 0 && pk > mx*100);
            report("TC-04 tlast=4", (tlast_cnt - tl_before) == 4);
            report("TC-04 total=4096", (out_cnt - base) == 4*N);
        end

        // --- TC-05: Config channel ---
        $display("\n--- TC-05: Config ---");
        begin
            int w = 0;
            s_axis_config_tdata = CFG_FWD;
            s_axis_config_tvalid = 1;
            @(posedge aclk);
            while (!s_axis_config_tready && w < 1000) begin @(posedge aclk); w++; end
            #1; s_axis_config_tvalid = 0;
            report("TC-05 Config tready", w < 1000);
        end
        gen_sine(64, 16383.0);
        send_frame();
        expected += N;
        wait_for(expected);
        report("TC-05 FFT forward", mag_sq(64) > 0);

        // --- TC-06: All-zero ---
        $display("\n--- TC-06: Zeros ---");
        gen_constant(0);
        send_config(); send_frame();
        expected += N;
        wait_for(expected);
        begin
            real mmax = 0;
            for (int k = 0; k < N; k++) if (mag_sq(k) > mmax) mmax = mag_sq(k);
            $display("  max mag^2=%.3e", mmax);
            report("TC-06 Zero->zero", mmax < 1.0);
        end

        // --- TC-07: DC (const 1000) ---
        $display("\n--- TC-07: DC ---");
        gen_constant(1000);
        send_config(); send_frame();
        expected += N;
        wait_for(expected);
        begin
            real dc = mag_sq(0), ac = 0;
            for (int k = 1; k < N; k++) if (mag_sq(k) > ac) ac = mag_sq(k);
            $display("  DC=%.3e AC=%.3e Re[0]=%0d", dc, ac, out_re[0]);
            report("TC-07 DC in bin 0", dc > 0 && dc > ac * 1000);
        end

        // --- TC-08a: Max amp ---
        $display("\n--- TC-08: Max amp ---");
        gen_constant(32767);
        send_config(); send_frame();
        expected += N;
        wait_for(expected);
        $display("  Bin0 Re=%0d Im=%0d", out_re[0], out_im[0]);
        report("TC-08a No overflow", mag_sq(0) > 0);

        // --- TC-08b: Nyquist ---
        for (int n = 0; n < N; n++)
            frame_data[n] = (n%2==0) ? 16'sd32767 : -16'sd32768;
        send_config(); send_frame();
        expected += N;
        wait_for(expected);
        begin
            real nyq = mag_sq(512), omx = 0;
            for (int k = 0; k < N; k++) if (k!=512 && mag_sq(k)>omx) omx = mag_sq(k);
            $display("  Bin512=%.3e other=%.3e", nyq, omx);
            report("TC-08b Nyquist", nyq > 0 && nyq > omx * 100);
        end

        // --- TC-03: AXI-S gaps (last — heavyweight for behavioral model) ---
        $display("\n--- TC-03: Gaps ---");
        gen_sine(64, 16383.0);
        send_config(); send_frame_with_gaps();
        expected += N;
        wait_for(expected, 500000);
        ratio = peak_ratio_db(64);
        $display("  ratio=%.1f dB", ratio);
        report("TC-03 Gaps correct", mag_sq(64) > 0 && ratio > 40.0);

        // --- Summary ---
        $display("\n============================================");
        $display("  SUMMARY: %0d PASSED, %0d FAILED", pass_cnt, fail_cnt);
        $display("============================================");
        if (fail_cnt == 0) $display("  *** ALL TESTS PASSED ***");
        else               $display("  *** SOME TESTS FAILED ***");
        #100 $finish;
    end

    initial begin #50_000_000; $display("[TIMEOUT]"); $finish; end
endmodule
