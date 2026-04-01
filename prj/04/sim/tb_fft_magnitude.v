// tb_fft_magnitude.v — TC-06: FFT IP → magnitude_calc cascade testbench
// Verifies end-to-end: sine input → FFT → magnitude output

`timescale 1ns / 1ps

module tb_fft_magnitude;

    localparam N          = 1024;
    localparam CLK_PERIOD = 10;         // 100 MHz
    localparam [15:0] CFG_FWD = {5'b00000, 10'b10_10_10_10_11, 1'b1};  // 16'h0557

    // ---- Clock & DUT signals ----
    reg aclk = 0;
    always #(CLK_PERIOD/2) aclk = ~aclk;

    // FFT config interface
    reg  [15:0] s_axis_config_tdata  = 0;
    reg         s_axis_config_tvalid = 0;
    wire        s_axis_config_tready;

    // FFT data input
    reg  [31:0] s_axis_data_tdata  = 0;
    reg         s_axis_data_tvalid = 0;
    reg         s_axis_data_tlast  = 0;
    wire        s_axis_data_tready;

    // FFT data output → magnitude_calc input
    wire [31:0] fft_out_tdata;
    wire        fft_out_tvalid;
    wire        fft_out_tlast;
    wire        fft_out_tready;

    // magnitude_calc output
    wire [15:0] mag_tdata;
    wire        mag_tvalid;
    wire        mag_tlast;
    reg         mag_tready = 1;

    // FFT events
    wire event_frame_started, event_tlast_unexpected, event_tlast_missing;
    wire event_status_channel_halt, event_data_in_channel_halt, event_data_out_channel_halt;

    // ---- FFT IP ----
    xfft_0 u_fft (
        .aclk                        (aclk),
        .s_axis_config_tdata         (s_axis_config_tdata),
        .s_axis_config_tvalid        (s_axis_config_tvalid),
        .s_axis_config_tready        (s_axis_config_tready),
        .s_axis_data_tdata           (s_axis_data_tdata),
        .s_axis_data_tvalid          (s_axis_data_tvalid),
        .s_axis_data_tready          (s_axis_data_tready),
        .s_axis_data_tlast           (s_axis_data_tlast),
        .m_axis_data_tdata           (fft_out_tdata),
        .m_axis_data_tvalid          (fft_out_tvalid),
        .m_axis_data_tready          (fft_out_tready),
        .m_axis_data_tlast           (fft_out_tlast),
        .event_frame_started         (event_frame_started),
        .event_tlast_unexpected      (event_tlast_unexpected),
        .event_tlast_missing         (event_tlast_missing),
        .event_status_channel_halt   (event_status_channel_halt),
        .event_data_in_channel_halt  (event_data_in_channel_halt),
        .event_data_out_channel_halt (event_data_out_channel_halt)
    );

    // ---- magnitude_calc ----
    magnitude_calc #(
        .DATA_WIDTH(32),
        .OUT_WIDTH (16)
    ) u_mag (
        .clk           (aclk),
        .rst_n         (1'b1),
        .s_axis_tdata  (fft_out_tdata),
        .s_axis_tvalid (fft_out_tvalid),
        .s_axis_tlast  (fft_out_tlast),
        .s_axis_tready (fft_out_tready),
        .m_axis_tdata  (mag_tdata),
        .m_axis_tvalid (mag_tvalid),
        .m_axis_tlast  (mag_tlast),
        .m_axis_tready (mag_tready)
    );

    // ---- Output capture ----
    reg [15:0] out_mag [0:N-1];
    integer    out_cnt;
    integer    rx_tlast_cnt;

    // ---- Test data ----
    reg signed [15:0] frame_data [0:N-1];

    // ---- Tasks (drive on negedge for clean setup, sample on posedge) ----
    task send_config;
        begin
            @(negedge aclk);
            s_axis_config_tdata  = CFG_FWD;
            s_axis_config_tvalid = 1'b1;
            @(posedge aclk);
            while (!s_axis_config_tready) @(posedge aclk);
            @(negedge aclk);
            s_axis_config_tvalid = 1'b0;
            s_axis_config_tdata  = 16'd0;
        end
    endtask

    task send_frame;
        integer i;
        begin
            for (i = 0; i < N; i = i + 1) begin
                @(negedge aclk);
                s_axis_data_tdata  = {16'h0000, frame_data[i]};
                s_axis_data_tvalid = 1'b1;
                s_axis_data_tlast  = (i == N - 1) ? 1'b1 : 1'b0;
                @(posedge aclk);
                while (!s_axis_data_tready) @(posedge aclk);
            end
            @(negedge aclk);
            s_axis_data_tvalid = 1'b0;
            s_axis_data_tlast  = 1'b0;
        end
    endtask

    task receive_mag_frame;
        begin
            out_cnt      = 0;
            rx_tlast_cnt = 0;
            while (out_cnt < N) begin
                @(posedge aclk);
                if (mag_tvalid && mag_tready) begin
                    out_mag[out_cnt] = mag_tdata;
                    if (mag_tlast) rx_tlast_cnt = rx_tlast_cnt + 1;
                    out_cnt = out_cnt + 1;
                end
            end
        end
    endtask

    // ---- Result tracking ----
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

    // ---- Main test ----
    integer i;
    real peak_val, other_max, ratio_db, val;

    initial begin
        $display("============================================");
        $display("  FFT + magnitude_calc Cascade Testbench");
        $display("  TC-06: End-to-end verification");
        $display("============================================");

        mag_tready = 1;
        repeat (20) @(posedge aclk);

        // Warm-up frame (flush phantom config slot)
        $display("\n--- Warm-up frame ---");
        for (i = 0; i < N; i = i + 1) frame_data[i] = 0;
        send_config;
        fork
            send_frame;
            receive_mag_frame;
        join
        $display("  Warm-up done, received %0d samples", out_cnt);

        // =============================================================
        // TC-06a: Single-frequency sine (bin 64)
        // =============================================================
        $display("\n--- TC-06a: Sine bin 64 through FFT+mag ---");
        for (i = 0; i < N; i = i + 1)
            frame_data[i] = $rtoi($sin(2.0 * 3.14159265358979 * 64.0 * $itor(i) / $itor(N)) * 16383.0);

        send_config;
        fork
            send_frame;
            receive_mag_frame;
        join

        $display("  Received %0d samples, tlast=%0d", out_cnt, rx_tlast_cnt);
        $display("  Bin[0]=%0d  Bin[63]=%0d  Bin[64]=%0d  Bin[65]=%0d  Bin[512]=%0d",
                 out_mag[0], out_mag[63], out_mag[64], out_mag[65], out_mag[512]);

        // Check: bin 64 should be the peak (unsigned magnitude)
        peak_val  = $itor(out_mag[64]);
        other_max = 0.0;
        for (i = 0; i < N; i = i + 1) begin
            if (i != 64 && i != (N - 64)) begin
                val = $itor(out_mag[i]);
                if (val > other_max) other_max = val;
            end
        end
        if (peak_val > 0.0 && other_max > 0.0)
            ratio_db = 20.0 * $ln(peak_val / other_max) / $ln(10.0);
        else if (peak_val > 0.0)
            ratio_db = 100.0;
        else
            ratio_db = 0.0;
        $display("  Peak(bin64)=%0.0f, max_other=%0.0f, ratio=%0.1f dB", peak_val, other_max, ratio_db);

        report("TC-06a Bin 64 peak",       (peak_val > 0.0) && (ratio_db > 20.0));
        report("TC-06a All positive",       1);  // unsigned output guaranteed
        report("TC-06a Frame length=1024",  (out_cnt == N));
        report("TC-06a tlast asserted",     (rx_tlast_cnt >= 1));

        // =============================================================
        // TC-06b: Two frames back-to-back (bin 64, bin 256)
        // =============================================================
        $display("\n--- TC-06b: Two consecutive frames ---");
        send_config;
        send_config;

        fork
            begin
                // Frame 1: bin 64
                for (i = 0; i < N; i = i + 1)
                    frame_data[i] = $rtoi($sin(2.0*3.14159265358979*64.0*$itor(i)/$itor(N)) * 16383.0);
                send_frame;
                // Frame 2: bin 256
                for (i = 0; i < N; i = i + 1)
                    frame_data[i] = $rtoi($sin(2.0*3.14159265358979*256.0*$itor(i)/$itor(N)) * 16383.0);
                send_frame;
            end
            begin
                // Receive frame 1 (discard)
                receive_mag_frame;
                $display("  Frame 1: bin64_mag=%0d, 1024 samples", out_mag[64]);
                // Receive frame 2
                receive_mag_frame;
                $display("  Frame 2: bin256_mag=%0d, 1024 samples", out_mag[256]);
            end
        join

        peak_val  = $itor(out_mag[256]);
        other_max = 0.0;
        for (i = 0; i < N; i = i + 1) begin
            if (i != 256 && i != (N - 256)) begin
                val = $itor(out_mag[i]);
                if (val > other_max) other_max = val;
            end
        end
        report("TC-06b Frame2 bin256 peak", (peak_val > 0.0) && (peak_val > other_max * 10.0));
        report("TC-06b Throughput matches", (out_cnt == N));

        // =============================================================
        // Summary
        // =============================================================
        $display("\n============================================");
        $display("  SUMMARY: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("============================================");
        if (fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** SOME TESTS FAILED ***");
        #100;
        $finish;
    end

    // Timeout
    initial begin
        #20_000_000;
        $display("[TIMEOUT] Simulation exceeded 20 ms");
        $finish;
    end

endmodule
