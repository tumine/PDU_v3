`timescale 1ns/1ps

module tb_dmem;
    reg clk;
    reg req;
    reg we;
    reg line_mode;
    reg [5:0] addr;
    wire [31:0] rdata;
    reg [31:0] wdata;
    wire [127:0] line_rdata;
    reg [127:0] line_wdata;
    wire ready;

    DMEM #(.DEPTH(6), .MEM_DELAY(1)) dut (
        .clk(clk),
        .req(req),
        .we(we),
        .line_mode(line_mode),
        .addr(addr),
        .rdata(rdata),
        .wdata(wdata),
        .line_rdata(line_rdata),
        .line_wdata(line_wdata),
        .ready(ready)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task wait_ready;
        begin
            wait (ready);
            #1;
        end
    endtask

    task finish_request;
        begin
            wait_ready();
            req = 1'b0;
            we = 1'b0;
            line_mode = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        req = 1'b0;
        we = 1'b0;
        line_mode = 1'b0;
        addr = 6'b0;
        wdata = 32'b0;
        line_wdata = 128'b0;
        repeat (2) @(posedge clk);

        addr = 6'd4;
        line_wdata = 128'h44332211_ddccbbaa_55667788_11223344;
        line_mode = 1'b1;
        we = 1'b1;
        req = 1'b1;
        @(posedge clk);
        finish_request();

        addr = 6'd4;
        line_mode = 1'b1;
        req = 1'b1;
        @(posedge clk);
        wait_ready();
        if (line_rdata !== 128'h44332211_ddccbbaa_55667788_11223344) begin
            $display("LINE_READ_MISMATCH %h", line_rdata);
            $finish(1);
        end
        req = 1'b0;
        line_mode = 1'b0;
        @(posedge clk);
        #1;

        addr = 6'd6;
        wdata = 32'hcafebabe;
        we = 1'b1;
        req = 1'b1;
        @(posedge clk);
        finish_request();

        addr = 6'd4;
        line_mode = 1'b1;
        req = 1'b1;
        @(posedge clk);
        wait_ready();
        if (line_rdata !== 128'h44332211_cafebabe_55667788_11223344) begin
            $display("MASK_WRITE_MISMATCH %h", line_rdata);
            $finish(1);
        end
        req = 1'b0;
        line_mode = 1'b0;
        @(posedge clk);
        #1;

        addr = 6'd6;
        req = 1'b1;
        @(posedge clk);
        wait_ready();
        if (rdata !== 32'hcafebabe) begin
            $display("WORD_READ_MISMATCH %h", rdata);
            $finish(1);
        end

        $display("DMEM_TEST_PASS");
        $finish(0);
    end
endmodule
