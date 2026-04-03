// Clock Divider Module
// Divides 100MHz system clock to ~7.69MHz (130ns period) for CPU
// Division ratio: 100MHz / 13 ≈ 7.69MHz
// Using 50% duty cycle (6-7 cycles high, 6-7 cycles low)

module clock_divider (
    input       [ 0 : 0]    sys_clk,
    input       [ 0 : 0]    sys_rst,
    output reg  [ 0 : 0]    cpu_clk
);

    // Counter width: 4 bits (enough for counting 0-13)
    reg [3:0] counter;
    
    initial begin
        counter = 0;
        cpu_clk = 0;
    end
    
    always @(posedge sys_clk) begin
        if (sys_rst) begin
            counter <= 0;
            cpu_clk <= 0;
        end
        else begin
            // Toggle at count 6 and 13 for ~50% duty cycle
            // Period = 13 cycles = 130ns @ 100MHz
            if (counter == 4'd6) begin
                cpu_clk <= 1;
                counter <= counter + 1;
            end
            else if (counter == 4'd13) begin
                cpu_clk <= 0;
                counter <= 0;
            end
            else begin
                counter <= counter + 1;
            end
        end
    end

endmodule