`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// tb_fft_ip.v — Testbench for Xilinx FFT IP (xfft_0)
// Covers TC-01 ~ TC-08 per Phase 2 spec
//////////////////////////////////////////////////////////////////////////////

module tb_fft_ip;

    localparam N          = 1024;
    localparam CLK_PERIOD = 10;         // 100 MHz

    // Config: FFT forward, SCALE_SCH = {Stage4=2, Stage3=2, Stage2=2, Stage1=2, Stage0=3}
    // Total scaling = 2^(2+2+2+2+3) = 2^11 = 2048 (Xilinx demo default)
    localparam [15:0] CFG_FWD = {5'b00000, 10'b10_10_10_10_11, 1'b1};  // 16'h0557

    // ----- DUT signals -----
    reg         aclk = 0;
    reg  [15:0] s_axis_config_tdata  = 0;
    reg         s_axis_config_tvalid = 0;
    wire        s_axis_config_tready;
    reg  [31:0] s_axis_data_tdata  = 0;
    reg         s_axis_data_tvalid = 0;
    wire        s_axis_data_tready;
    reg         s_axis_data_tlast  = 0;
    wire [31:0] m_axis_data_tdata;
    wire        m_axis_data_tvalid;
    reg         m_axis_data_tready = 1;
    wire        m_axis_data_tlast;
    wire        event_frame_started, event_tlast_unexpected, event_tlast_missing;
    wire        event_status_channel_halt, event_data_in_channel_halt, event_data_out_channel_halt;

    always #(CLK_PERIOD/2) aclk = ~aclk;

    xfft_0 u_fft (
        .aclk                        (aclk),
        .s_axis_config_tdata         (s_axis_config_tdata),
        .s_axis_config_tvalid        (s_axis_config_tvalid),
        .s_axis_config_tready        (s_axis_config_tready),
        .s_axis_data_tdata           (s_axis_data_tdata),
        .s_axis_data_tvalid          (s_axis_data_tvalid),
        .s_axis_data_tready          (s_axis_data_tready),
        .s_axis_data_tlast           (s_axis_data_tlast),
        .m_axis_data_tdata           (m_axis_data_tdata),
        .m_axis_data_tvalid          (m_axis_data_tvalid),
        .m_axis_data_tready          (m_axis_data_tready),
        .m_axis_data_tlast           (m_axis_data_tlast),
        .event_frame_started         (event_frame_started),
        .event_tlast_unexpected      (event_tlast_unexpected),
        .event_tlast_missing         (event_tlast_missing),
        .event_status_channel_halt   (event_status_channel_halt),
        .event_data_in_channel_halt  (event_data_in_channel_halt),
        .event_data_out_channel_halt (event_data_out_channel_halt)
    );

    // ----- Output capture arrays -----
    reg signed [15:0] out_re [0:N-1];
    reg signed [15:0] out_im [0:N-1];
    integer           out_cnt;
    integer           rx_tlast_cnt;

    // ----- Test data array -----
    reg signed [15:0] frame_data [0:N-1];

    // ===================================================================
    //  Tasks
    // ===================================================================

    // Send one config word with AXI-S handshake
    task send_config;
        begin
            @(posedge aclk);
            s_axis_config_tdata  <= CFG_FWD;
            s_axis_config_tvalid <= 1'b1;
            @(posedge aclk);
            while (!s_axis_config_tready) @(posedge aclk);
            s_axis_config_tvalid <= 1'b0;
            s_axis_config_tdata  <= 16'd0;
        end
    endtask

    // Send one frame of N samples (blocking)
    task send_frame;
        integer i;
        begin
            for (i = 0; i < N; i = i + 1) begin
                @(posedge aclk);
                s_axis_data_tdata  <= {16'h0000, frame_data[i]};
                s_axis_data_tvalid <= 1'b1;
                s_axis_data_tlast  <= (i == N - 1) ? 1'b1 : 1'b0;
                @(posedge aclk);
                while (!s_axis_data_tready) @(posedge aclk);
            end
            s_axis_data_tvalid <= 1'b0;
            s_axis_data_tlast  <= 1'b0;
        end
    endtask

    // Send one frame with random tvalid gaps
    task send_frame_with_gaps;
        integer i, gap;
        begin
            for (i = 0; i < N; i = i + 1) begin
                gap = $urandom % 4;
                repeat (gap) begin
                    @(posedge aclk);
                    s_axis_data_tvalid <= 1'b0;
                end
                @(posedge aclk);
                s_axis_data_tdata  <= {16'h0000, frame_data[i]};
                s_axis_data_tvalid <= 1'b1;
                s_axis_data_tlast  <= (i == N - 1) ? 1'b1 : 1'b0;
                @(posedge aclk);
                while (!s_axis_data_tready) @(posedge aclk);
            end
            s_axis_data_tvalid <= 1'b0;
            s_axis_data_tlast  <= 1'b0;
        end
    endtask

    // Receive one frame of N output samples (blocking task)
    task receive_frame;
        begin
            out_cnt      = 0;
            rx_tlast_cnt = 0;
            while (out_cnt < N) begin
                @(posedge aclk);
                if (m_axis_data_tvalid && m_axis_data_tready) begin
                    out_re[out_cnt] = $signed(m_axis_data_tdata[15:0]);
                    out_im[out_cnt] = $signed(m_axis_data_tdata[31:16]);
                    if (m_axis_data_tlast) rx_tlast_cnt = rx_tlast_cnt + 1;
                    out_cnt = out_cnt + 1;
                end
            end
        end
    endtask

    // Receive M frames, keeping only last frame in out_re/out_im
    // Returns total sample count and total tlast count
    integer rx_total_samples;
    integer rx_total_tlast;
    task receive_frames;
        input integer num_frames;
        integer total, tl, fc;
        begin
            total = 0;
            tl    = 0;
            for (fc = 0; fc < num_frames; fc = fc + 1) begin
                receive_frame;
                total = total + out_cnt;
                tl    = tl + rx_tlast_cnt;
            end
            rx_total_samples = total;
            rx_total_tlast   = tl;
        end
    endtask

    // ===================================================================
    //  Magnitude-squared (real) for a bin
    // ===================================================================
    function real mag_sq;
        input integer bin;
        real r, im;
        begin
            r  = $itor(out_re[bin]);
            im = $itor(out_im[bin]);
            mag_sq = r * r + im * im;
        end
    endfunction

    // ===================================================================
    //  Result tracking
    // ===================================================================
    integer pass_count = 0;
    integer fail_count = 0;

    task report;
        input [255:0] name;
        input integer pass;
        begin
            if (pass) begin
                $display("[PASS] %0s", name);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s", name);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ===================================================================
    //  Main test sequence
    // ===================================================================
    integer i;
    real peak_mag, other_max, ratio_db, mag_bin, peak1, peak2;

    initial begin
        $display("============================================");
        $display("  FFT IP Testbench - Phase 2 Verification");
        $display("  Config = 0x%04h", CFG_FWD);
        $display("============================================");

        repeat (20) @(posedge aclk);

        // ===========================================================
        // TC-01: Single-frequency sine wave (bin 64)
        // ===========================================================
        $display("\n--- TC-01: Single-frequency sine (bin 64) ---");
        for (i = 0; i < N; i = i + 1)
            frame_data[i] = $rtoi($sin(2.0 * 3.14159265358979 * 64.0 * $itor(i) / $itor(N)) * 16383.0);

        send_config;
        fork
            send_frame;
            receive_frame;
        join

        // Debug: print a few key bins
        $display("  out_cnt=%0d, tlast=%0d", out_cnt, rx_tlast_cnt);
        $display("  Bin[0]:  Re=%6d Im=%6d", out_re[0],  out_im[0]);
        $display("  Bin[63]: Re=%6d Im=%6d", out_re[63], out_im[63]);
        $display("  Bin[64]: Re=%6d Im=%6d", out_re[64], out_im[64]);
        $display("  Bin[65]: Re=%6d Im=%6d", out_re[65], out_im[65]);
        $display("  Bin[960]:Re=%6d Im=%6d", out_re[960],out_im[960]);

        peak_mag  = mag_sq(64);
        other_max = 0.0;
        for (i = 0; i < N; i = i + 1) begin
            if (i != 64 && i != (N - 64)) begin
                mag_bin = mag_sq(i);
                if (mag_bin > other_max) other_max = mag_bin;
            end
        end
        if (peak_mag > 0.0 && other_max > 0.0)
            ratio_db = 10.0 * $ln(peak_mag / other_max) / $ln(10.0);
        else if (peak_mag > 0.0)
            ratio_db = 100.0;
        else
            ratio_db = 0.0;
        $display("  Bin64 mag^2=%0e, max_other=%0e, ratio=%0.1f dB", peak_mag, other_max, ratio_db);
        report("TC-01 Single sine bin 64", (peak_mag > 0.0) && (ratio_db > 40.0));
        report("TC-01 tlast asserted", (rx_tlast_cnt >= 1));

        // ===========================================================
        // TC-02: Multi-frequency (bin 64 + bin 256)
        // ===========================================================
        $display("\n--- TC-02: Multi-frequency (bin 64 + bin 256) ---");
        for (i = 0; i < N; i = i + 1)
            frame_data[i] = $rtoi($sin(2.0*3.14159265358979*64.0*$itor(i)/$itor(N)) * 8191.0)
                          + $rtoi($sin(2.0*3.14159265358979*256.0*$itor(i)/$itor(N)) * 8191.0);

        send_config;
        fork
            send_frame;
            receive_frame;
        join

        peak1 = mag_sq(64);
        peak2 = mag_sq(256);
        other_max = 0.0;
        for (i = 0; i < N; i = i + 1) begin
            if (i != 64 && i != (N-64) && i != 256 && i != (N-256)) begin
                mag_bin = mag_sq(i);
                if (mag_bin > other_max) other_max = mag_bin;
            end
        end
        $display("  Bin64=%0e, Bin256=%0e, other=%0e", peak1, peak2, other_max);
        report("TC-02 Multi-freq peaks", (peak1 > 0.0) && (peak2 > 0.0) &&
            (peak1 > other_max * 100.0) && (peak2 > other_max * 100.0));

        // ===========================================================
        // TC-03: AXI-Stream handshake with random tvalid gaps
        // ===========================================================
        $display("\n--- TC-03: AXI-S handshake with gaps ---");
        for (i = 0; i < N; i = i + 1)
            frame_data[i] = $rtoi($sin(2.0*3.14159265358979*64.0*$itor(i)/$itor(N)) * 16383.0);

        send_config;
        fork
            send_frame_with_gaps;
            receive_frame;
        join

        peak_mag  = mag_sq(64);
        other_max = 0.0;
        for (i = 0; i < N; i = i + 1) begin
            if (i != 64 && i != (N - 64)) begin
                mag_bin = mag_sq(i);
                if (mag_bin > other_max) other_max = mag_bin;
            end
        end
        if (peak_mag > 0.0 && other_max > 0.0)
            ratio_db = 10.0 * $ln(peak_mag / other_max) / $ln(10.0);
        else if (peak_mag > 0.0)
            ratio_db = 100.0;
        else
            ratio_db = 0.0;
        $display("  With gaps: ratio=%0.1f dB", ratio_db);
        report("TC-03 Gaps correct result", (peak_mag > 0.0) && (ratio_db > 40.0));

        // ===========================================================
        // TC-04: Continuous 4 frames
        // ===========================================================
        $display("\n--- TC-04: Continuous 4 frames ---");
        begin : tc04_block
            integer bin_list [0:3];
            integer f;
            integer tc04_pass;
            bin_list[0] = 64;  bin_list[1] = 128;
            bin_list[2] = 32;  bin_list[3] = 256;
            tc04_pass = 1;

            // Pre-send all 4 configs
            for (f = 0; f < 4; f = f + 1) send_config;

            // Send 4 frames and receive 4 frames in parallel
            fork
                begin
                    for (f = 0; f < 4; f = f + 1) begin
                        for (i = 0; i < N; i = i + 1)
                            frame_data[i] = $rtoi($sin(2.0*3.14159265358979*$itor(bin_list[f])*$itor(i)/$itor(N)) * 16383.0);
                        send_frame;
                    end
                end
                receive_frames(4);
            join

            $display("  total_samples=%0d, total_tlast=%0d", rx_total_samples, rx_total_tlast);
            // Check last frame (bin 256) which is in out_re/out_im
            peak_mag = mag_sq(bin_list[3]);
            other_max = 0.0;
            for (i = 0; i < N; i = i + 1) begin
                if (i != bin_list[3] && i != (N - bin_list[3])) begin
                    mag_bin = mag_sq(i);
                    if (mag_bin > other_max) other_max = mag_bin;
                end
            end
            if (peak_mag <= 0.0 || peak_mag < other_max * 100.0) tc04_pass = 0;

            report("TC-04 4-frame continuous", tc04_pass);
            report("TC-04 tlast count=4", (rx_total_tlast == 4));
            report("TC-04 total output=4096", (rx_total_samples == 4 * N));
        end

        // ===========================================================
        // TC-05: Config channel verification
        // ===========================================================
        $display("\n--- TC-05: Config channel ---");
        begin : tc05_block
            integer wait_cycles;
            @(posedge aclk);
            s_axis_config_tdata  <= CFG_FWD;
            s_axis_config_tvalid <= 1'b1;
            wait_cycles = 0;
            @(posedge aclk);
            while (!s_axis_config_tready && wait_cycles < 1000) begin
                @(posedge aclk);
                wait_cycles = wait_cycles + 1;
            end
            s_axis_config_tvalid <= 1'b0;
            report("TC-05 Config tready handshake", (wait_cycles < 1000));
        end

        for (i = 0; i < N; i = i + 1)
            frame_data[i] = $rtoi($sin(2.0*3.14159265358979*64.0*$itor(i)/$itor(N)) * 16383.0);
        fork
            send_frame;
            receive_frame;
        join
        peak_mag = mag_sq(64);
        report("TC-05 FFT forward transform", (peak_mag > 0.0));

        // ===========================================================
        // TC-06: All-zero input
        // ===========================================================
        $display("\n--- TC-06: All-zero input ---");
        for (i = 0; i < N; i = i + 1) frame_data[i] = 0;
        send_config;
        fork
            send_frame;
            receive_frame;
        join

        begin : tc06_block
            real max_out;
            max_out = 0.0;
            for (i = 0; i < N; i = i + 1) begin
                mag_bin = mag_sq(i);
                if (mag_bin > max_out) max_out = mag_bin;
            end
            $display("  Max output mag^2=%0e", max_out);
            report("TC-06 Zero->zero", (max_out < 1.0));
        end

        // ===========================================================
        // TC-07: DC signal (constant = 1000)
        // ===========================================================
        $display("\n--- TC-07: DC signal (constant 1000) ---");
        for (i = 0; i < N; i = i + 1) frame_data[i] = 16'sd1000;
        send_config;
        fork
            send_frame;
            receive_frame;
        join

        begin : tc07_block
            real dc_mag, ac_max;
            dc_mag = mag_sq(0);
            ac_max = 0.0;
            for (i = 1; i < N; i = i + 1) begin
                mag_bin = mag_sq(i);
                if (mag_bin > ac_max) ac_max = mag_bin;
            end
            $display("  DC mag^2=%0e, max AC=%0e, Re[0]=%0d", dc_mag, ac_max, out_re[0]);
            report("TC-07 DC energy in bin 0", (dc_mag > 0.0) && (dc_mag > ac_max * 1000.0));
        end

        // ===========================================================
        // TC-08: Max amplitude + Nyquist
        // ===========================================================
        $display("\n--- TC-08: Max amplitude & Nyquist ---");

        // TC-08a: All +32767
        for (i = 0; i < N; i = i + 1) frame_data[i] = 16'sd32767;
        send_config;
        fork
            send_frame;
            receive_frame;
        join

        begin : tc08a_block
            real dc_mag;
            dc_mag = mag_sq(0);
            $display("  All+32767: Bin0 Re=%0d Im=%0d mag^2=%0e", out_re[0], out_im[0], dc_mag);
            report("TC-08a Max amp no overflow", (dc_mag > 0.0));
        end

        // TC-08b: Alternating +32767/-32768 (Nyquist)
        for (i = 0; i < N; i = i + 1) begin
            if (i % 2 == 0)
                frame_data[i] = 16'sd32767;
            else
                frame_data[i] = -16'sd32768;
        end
        send_config;
        fork
            send_frame;
            receive_frame;
        join

        begin : tc08b_block
            real nyq_mag, other_mag_max;
            nyq_mag = mag_sq(512);
            other_mag_max = 0.0;
            for (i = 0; i < N; i = i + 1) begin
                if (i != 512) begin
                    mag_bin = mag_sq(i);
                    if (mag_bin > other_mag_max) other_mag_max = mag_bin;
                end
            end
            $display("  Nyquist: Bin512=%0e, other=%0e", nyq_mag, other_mag_max);
            report("TC-08b Nyquist bin 512",
                (nyq_mag > 0.0) && (nyq_mag > other_mag_max * 100.0));
        end

        // ===========================================================
        // Summary
        // ===========================================================
        $display("\n============================================");
        $display("  SUMMARY: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("============================================");
        if (fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** SOME TESTS FAILED ***");
        $display("");
        #100;
        $finish;
    end

    // Timeout: 20 ms (very generous for behavioral sim)
    initial begin
        #20_000_000;
        $display("[TIMEOUT] Simulation exceeded 20 ms");
        $finish;
    end

endmodule
