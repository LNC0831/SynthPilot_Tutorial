//////////////////////////////////////////////////////////////////////////////
// I2C Slave Controller
// Standard Mode, 7-bit address, clock stretching support
//////////////////////////////////////////////////////////////////////////////
module i2c_slave #(
    parameter SLAVE_ADDR = 7'h50
)(
    input  wire        clk,
    input  wire        rst_n,
    // RX data interface (data received from master)
    output reg  [7:0]  rx_data,
    output reg         rx_valid,
    input  wire        rx_ready,
    // TX data interface (data to send to master)
    input  wire [7:0]  tx_data,
    input  wire        tx_valid,
    output reg         tx_ready,
    // Status
    output reg         start_det,
    output reg         stop_det,
    output reg         addr_match,
    output reg         rw_bit,
    // I2C physical interface
    output reg         scl_o,
    output reg         scl_oen,      // 0=drive, 1=release
    input  wire        scl_i,
    output reg         sda_o,
    output reg         sda_oen,      // 0=drive, 1=release
    input  wire        sda_i
);

    // 3-stage synchronizer for SCL and SDA
    reg [2:0] scl_sync;
    reg [2:0] sda_sync;
    wire scl_s = scl_sync[2];
    wire sda_s = sda_sync[2];

    // Edge detection
    reg scl_prev, sda_prev;
    wire scl_rise = scl_s & ~scl_prev;
    wire scl_fall = ~scl_s & scl_prev;
    wire sda_rise = sda_s & ~sda_prev;
    wire sda_fall = ~sda_s & sda_prev;

    // START: SDA falls while SCL is high
    wire start_cond = scl_s & sda_fall;
    // STOP: SDA rises while SCL is high
    wire stop_cond  = scl_s & sda_rise;

    // FSM states
    localparam S_IDLE     = 4'd0;
    localparam S_ADDR     = 4'd1;
    localparam S_ADDR_ACK = 4'd2;
    localparam S_RX_DATA  = 4'd3;
    localparam S_RX_ACK   = 4'd4;
    localparam S_TX_DATA  = 4'd5;
    localparam S_TX_ACK   = 4'd6;
    localparam S_STRETCH  = 4'd7;

    reg [3:0]  state;
    reg [3:0]  bit_cnt;
    reg [7:0]  shift_reg;
    reg        stretch_return_tx; // 1=return to TX_DATA after stretch

    // Synchronizer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_sync <= 3'b111;
            sda_sync <= 3'b111;
            scl_prev <= 1'b1;
            sda_prev <= 1'b1;
        end else begin
            scl_sync <= {scl_sync[1:0], scl_i};
            sda_sync <= {sda_sync[1:0], sda_i};
            scl_prev <= scl_s;
            sda_prev <= sda_s;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            bit_cnt     <= 4'd0;
            shift_reg   <= 8'd0;
            rx_data     <= 8'd0;
            rx_valid    <= 1'b0;
            tx_ready    <= 1'b0;
            start_det   <= 1'b0;
            stop_det    <= 1'b0;
            addr_match  <= 1'b0;
            rw_bit      <= 1'b0;
            scl_o       <= 1'b0;
            scl_oen     <= 1'b1;
            sda_o       <= 1'b0;
            sda_oen     <= 1'b1;
            stretch_return_tx <= 1'b0;
        end else begin
            // Pulse signals
            start_det <= 1'b0;
            stop_det  <= 1'b0;
            tx_ready  <= 1'b0;

            // Clear rx_valid on handshake
            if (rx_valid && rx_ready)
                rx_valid <= 1'b0;

            // START condition detected in any state
            if (start_cond) begin
                start_det  <= 1'b1;
                state      <= S_ADDR;
                bit_cnt    <= 4'd0;
                shift_reg  <= 8'd0;
                sda_oen    <= 1'b1; // release SDA
                scl_oen    <= 1'b1; // release SCL
                addr_match <= 1'b0;
            end
            // STOP condition
            else if (stop_cond) begin
                stop_det   <= 1'b1;
                state      <= S_IDLE;
                sda_oen    <= 1'b1;
                scl_oen    <= 1'b1;
                addr_match <= 1'b0;
            end
            else begin
                case (state)
                    S_IDLE: begin
                        sda_oen <= 1'b1;
                        scl_oen <= 1'b1;
                    end

                    S_ADDR: begin
                        // Sample on SCL rising edge
                        if (scl_rise) begin
                            shift_reg <= {shift_reg[6:0], sda_s};
                            if (bit_cnt == 4'd7) begin
                                // All 8 bits received (7-bit addr + RW)
                                bit_cnt <= 4'd0;
                            end else begin
                                bit_cnt <= bit_cnt + 1;
                            end
                        end
                        // On SCL falling edge after bit 7, check address
                        if (scl_fall && bit_cnt == 4'd0 && shift_reg != 8'd0) begin
                            // shift_reg has the full byte now
                            if (shift_reg[7:1] == SLAVE_ADDR) begin
                                addr_match <= 1'b1;
                                rw_bit     <= shift_reg[0];
                                state      <= S_ADDR_ACK;
                                // Drive ACK (SDA low)
                                sda_oen    <= 1'b0;
                                sda_o      <= 1'b0;
                            end else begin
                                // Address mismatch, go idle
                                addr_match <= 1'b0;
                                state      <= S_IDLE;
                                sda_oen    <= 1'b1;
                            end
                        end
                    end

                    S_ADDR_ACK: begin
                        // Wait for SCL to go high (master clocks ACK)
                        // Then wait for SCL to fall
                        if (scl_fall) begin
                            if (rw_bit) begin
                                // Read: slave needs to send data
                                // Stretch clock until tx_data is available
                                if (tx_valid) begin
                                    tx_ready  <= 1'b1;
                                    shift_reg <= tx_data;
                                    sda_oen   <= tx_data[7] ? 1'b1 : 1'b0;
                                    sda_o     <= 1'b0;
                                    state     <= S_TX_DATA;
                                    bit_cnt   <= 4'd0;
                                end else begin
                                    // Clock stretching
                                    scl_oen <= 1'b0;
                                    scl_o   <= 1'b0;
                                    state   <= S_STRETCH;
                                    stretch_return_tx <= 1'b1;
                                end
                            end else begin
                                // Write: master will send data
                                sda_oen <= 1'b1; // release SDA
                                state   <= S_RX_DATA;
                                bit_cnt <= 4'd0;
                                shift_reg <= 8'd0;
                            end
                        end
                    end

                    S_RX_DATA: begin
                        // Sample on SCL rising edge
                        if (scl_rise) begin
                            shift_reg <= {shift_reg[6:0], sda_s};
                            bit_cnt   <= bit_cnt + 1;
                        end
                        if (scl_fall && bit_cnt == 4'd8) begin
                            // Byte complete
                            rx_data  <= shift_reg;
                            rx_valid <= 1'b1;
                            bit_cnt  <= 4'd0;
                            state    <= S_RX_ACK;
                            // Drive ACK
                            sda_oen  <= 1'b0;
                            sda_o    <= 1'b0;
                        end
                    end

                    S_RX_ACK: begin
                        if (scl_fall) begin
                            sda_oen   <= 1'b1; // release SDA
                            state     <= S_RX_DATA;
                            bit_cnt   <= 4'd0;
                            shift_reg <= 8'd0;
                        end
                    end

                    S_TX_DATA: begin
                        if (scl_fall) begin
                            if (bit_cnt == 4'd7) begin
                                // All 8 bits sent, release SDA for master ACK/NACK
                                sda_oen <= 1'b1;
                                state   <= S_TX_ACK;
                                bit_cnt <= 4'd0;
                            end else begin
                                bit_cnt <= bit_cnt + 1;
                                shift_reg <= {shift_reg[6:0], 1'b0};
                                sda_oen   <= shift_reg[6] ? 1'b1 : 1'b0;
                                sda_o     <= 1'b0;
                            end
                        end
                    end

                    S_TX_ACK: begin
                        // Sample master's ACK/NACK on SCL rising edge
                        if (scl_rise) begin
                            shift_reg[0] <= sda_s; // store ACK/NACK
                        end
                        if (scl_fall) begin
                            if (shift_reg[0] == 1'b1) begin
                                // NACK: master done reading
                                sda_oen <= 1'b1;
                                state   <= S_IDLE;
                            end else begin
                                // ACK: send next byte
                                if (tx_valid) begin
                                    tx_ready  <= 1'b1;
                                    shift_reg <= tx_data;
                                    sda_oen   <= tx_data[7] ? 1'b1 : 1'b0;
                                    sda_o     <= 1'b0;
                                    state     <= S_TX_DATA;
                                    bit_cnt   <= 4'd0;
                                end else begin
                                    // Stretch clock
                                    scl_oen <= 1'b0;
                                    scl_o   <= 1'b0;
                                    state   <= S_STRETCH;
                                    stretch_return_tx <= 1'b1;
                                end
                            end
                        end
                    end

                    S_STRETCH: begin
                        // Hold SCL low until tx_valid
                        if (tx_valid) begin
                            tx_ready  <= 1'b1;
                            shift_reg <= tx_data;
                            scl_oen   <= 1'b1; // release SCL
                            if (stretch_return_tx) begin
                                sda_oen <= tx_data[7] ? 1'b1 : 1'b0;
                                sda_o   <= 1'b0;
                                state   <= S_TX_DATA;
                                bit_cnt <= 4'd0;
                            end
                        end
                    end

                endcase
            end
        end
    end

endmodule
