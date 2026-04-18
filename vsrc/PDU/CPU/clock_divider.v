// Clock Divider Module (bypassed)
// This file now directly forwards the system clock to the CPU so the
// CPU clock period equals the system clock period (10ns @ 100MHz).

module clock_divider (
    input       [0:0]    sys_clk,
    input       [0:0]    sys_rst,
    output      [0:0]    cpu_clk
);

    // Bypass divider: drive cpu_clk directly from sys_clk so CPU sees 10ns period
    assign cpu_clk = sys_clk;

endmodule