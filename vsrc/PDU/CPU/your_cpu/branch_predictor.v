// Tournament branch predictor with BTB and RAS.
// 条件分支方向仍由局部/全局/选择器预测；BTB 统一缓存控制流类型与目标；
// RAS 专门为 JAL/JALR 的调用/返回关系提供预测目标。
module local_predictor #(
    parameter PC_IDX_W = 8,
    parameter LOCAL_HIST_W = 6
)(
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    en,

    input  wire [PC_IDX_W-1:0]     pred_pc_idx,
    output wire [LOCAL_HIST_W-1:0] pred_hist,
    output wire                    pred_taken,

    input  wire                    train_valid,
    input  wire [PC_IDX_W-1:0]     train_pc_idx,
    input  wire [LOCAL_HIST_W-1:0] train_hist_snapshot,
    input  wire                    train_taken
);
    localparam integer BHT_ENTRIES = (1 << PC_IDX_W);
    localparam integer PHT_ENTRIES = (1 << LOCAL_HIST_W);

    reg [LOCAL_HIST_W-1:0] bht [0:BHT_ENTRIES-1];
    reg [1:0] pht [0:PHT_ENTRIES-1];

    integer i;

    function [1:0] sat_update;
        input [1:0] cur;
        input       taken;
        begin
            sat_update = cur;
            if (taken) begin
                if (cur != 2'b11) begin
                    sat_update = cur + 2'b01;
                end
            end
            else begin
                if (cur != 2'b00) begin
                    sat_update = cur - 2'b01;
                end
            end
        end
    endfunction

    assign pred_hist = bht[pred_pc_idx];
    assign pred_taken = pht[pred_hist][1];

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < BHT_ENTRIES; i = i + 1) begin
                bht[i] <= {LOCAL_HIST_W{1'b0}};
            end
            for (i = 0; i < PHT_ENTRIES; i = i + 1) begin
                pht[i] <= 2'b01;
            end
        end
        else if (en && train_valid) begin
            // 使用 IF 阶段捕获的局部历史快照训练 PHT，避免流水线中后续同 PC 分支污染本次索引。
            pht[train_hist_snapshot] <= sat_update(pht[train_hist_snapshot], train_taken);
            bht[train_pc_idx] <= {bht[train_pc_idx][LOCAL_HIST_W-2:0], train_taken};
        end
    end
endmodule

module global_predictor #(
    parameter PC_IDX_W = 8,
    parameter GHR_W = 8
)(
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    en,

    input  wire [PC_IDX_W-1:0]     pred_pc_idx,
    output wire [GHR_W-1:0]        pred_ghr,
    output wire                    pred_taken,

    input  wire                    train_valid,
    input  wire [PC_IDX_W-1:0]     train_pc_idx,
    input  wire [GHR_W-1:0]        train_ghr_snapshot,
    input  wire                    train_taken
);
    localparam integer PHT_ENTRIES = (1 << PC_IDX_W);

    reg [GHR_W-1:0] ghr;
    reg [1:0] pht [0:PHT_ENTRIES-1];

    integer i;

    function [1:0] sat_update;
        input [1:0] cur;
        input       taken;
        begin
            sat_update = cur;
            if (taken) begin
                if (cur != 2'b11) begin
                    sat_update = cur + 2'b01;
                end
            end
            else begin
                if (cur != 2'b00) begin
                    sat_update = cur - 2'b01;
                end
            end
        end
    endfunction

    wire [PC_IDX_W-1:0] pred_idx = pred_pc_idx ^ ghr[PC_IDX_W-1:0];
    wire [PC_IDX_W-1:0] train_idx = train_pc_idx ^ train_ghr_snapshot[PC_IDX_W-1:0];

    assign pred_ghr = ghr;
    assign pred_taken = pht[pred_idx][1];

    always @(posedge clk) begin
        if (rst) begin
            ghr <= {GHR_W{1'b0}};
            for (i = 0; i < PHT_ENTRIES; i = i + 1) begin
                pht[i] <= 2'b01;
            end
        end
        else if (en && train_valid) begin
            // 全局预测使用 IF 阶段的 GHR 快照定位训练项，保证乱序完成的控制流不会写错 PHT 项。
            pht[train_idx] <= sat_update(pht[train_idx], train_taken);
            ghr <= {ghr[GHR_W-2:0], train_taken};
        end
    end
endmodule

module choice_predictor #(
    parameter PC_IDX_W = 8
)(
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    en,

    input  wire [PC_IDX_W-1:0]     pred_pc_idx,
    output wire                    pred_use_global,

    input  wire                    train_valid,
    input  wire [PC_IDX_W-1:0]     train_pc_idx,
    input  wire                    train_local_pred,
    input  wire                    train_global_pred,
    input  wire                    train_actual_taken
);
    localparam integer CHOICE_ENTRIES = (1 << PC_IDX_W);

    reg [1:0] choice_pht [0:CHOICE_ENTRIES-1];
    integer i;

    function [1:0] sat_update;
        input [1:0] cur;
        input       move_up;
        begin
            sat_update = cur;
            if (move_up) begin
                if (cur != 2'b11) begin
                    sat_update = cur + 2'b01;
                end
            end
            else begin
                if (cur != 2'b00) begin
                    sat_update = cur - 2'b01;
                end
            end
        end
    endfunction

    assign pred_use_global = choice_pht[pred_pc_idx][1];

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < CHOICE_ENTRIES; i = i + 1) begin
                choice_pht[i] <= 2'b01;
            end
        end
        else if (en && train_valid) begin
            if (train_local_pred != train_global_pred) begin
                // 只有局部/全局预测分歧时训练选择器，减少选择表在同向正确时的无意义抖动。
                if (train_global_pred == train_actual_taken) begin
                    choice_pht[train_pc_idx] <= sat_update(choice_pht[train_pc_idx], 1'b1);
                end
                else if (train_local_pred == train_actual_taken) begin
                    choice_pht[train_pc_idx] <= sat_update(choice_pht[train_pc_idx], 1'b0);
                end
            end
        end
    end
endmodule

module branch_predictor #(
    parameter PC_IDX_W = 8,
    parameter LOCAL_HIST_W = 6,
    parameter GHR_W = 8,
    parameter META_W = 64
)(
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    en,       // CPU 全局运行使能，来自 PDU 的 run/step 控制
    input  wire                    predictor_disable,  // PDU 统一预测禁用开关，单独进入预测器避免和 global_en 语义混淆
    input  wire                    stall,

    input  wire [31:0]             if_pc,
    input  wire [31:0]             if_inst,
    output wire                    if_pred_valid,
    output wire                    if_pred_taken,
    output wire [31:0]             if_pred_target,
    output wire [META_W-1:0]       if_pred_meta,

    input  wire                    ex_valid,
    input  wire [31:0]             ex_pc,
    input  wire [31:0]             ex_pc_plus4,
    input  wire [31:0]             ex_target_actual,
    input  wire                    ex_taken_actual,
    input  wire                    ex_is_branch,
    input  wire                    ex_is_jal,
    input  wire                    ex_is_jalr,
    input  wire [META_W-1:0]       ex_meta,
    input  wire                    ex_bp_used,

    output wire                    redirect_valid,
    output wire [31:0]             redirect_pc
);
    localparam [1:0] KIND_BRANCH  = 2'b00;
    localparam [1:0] KIND_JAL     = 2'b01;
    localparam [1:0] KIND_JALR    = 2'b10;
    localparam [1:0] KIND_INVALID = 2'b11;

    localparam integer BTB_ENTRIES = (1 << PC_IDX_W);
    localparam integer BTB_TAG_W = 32 - PC_IDX_W - 2;
    localparam integer RAS_DEPTH = 8;
    localparam integer RAS_PTR_W = 3;
    localparam integer RAS_CNT_W = 4;
    localparam [RAS_CNT_W-1:0] RAS_DEPTH_COUNT = RAS_DEPTH;

    localparam integer META_PC_LO          = 0;
    localparam integer META_PC_HI          = 7;
    localparam integer META_LOCAL_HIST_LO  = 8;
    localparam integer META_LOCAL_HIST_HI  = 13;
    localparam integer META_GHR_LO         = 14;
    localparam integer META_GHR_HI         = 21;
    localparam integer META_LOCAL_PRED     = 22;
    localparam integer META_GLOBAL_PRED    = 23;
    localparam integer META_CHOICE_GLOBAL  = 24;
    localparam integer META_PRED_TAKEN     = 25;
    localparam integer META_PRED_VALID     = 26;
    localparam integer META_KIND_LO        = 27;
    localparam integer META_KIND_HI        = 28;
    localparam integer META_BTB_HIT        = 29;
    localparam integer META_LOOKUP_ACTIVE  = 30;
    localparam integer META_RAS_OP_VALID   = 31;
    localparam integer META_PRED_TARGET_LO = 32;
    localparam integer META_PRED_TARGET_HI = 63;

    reg                    btb_valid  [0:BTB_ENTRIES-1];
    reg [BTB_TAG_W-1:0]    btb_tag    [0:BTB_ENTRIES-1];
    reg [1:0]              btb_kind   [0:BTB_ENTRIES-1];
    reg [31:0]             btb_target [0:BTB_ENTRIES-1];

    reg [31:0]             ras_arch_stack [0:RAS_DEPTH-1];
    reg [31:0]             ras_spec_stack [0:RAS_DEPTH-1];
    reg [RAS_PTR_W-1:0]    ras_arch_sp;
    reg [RAS_PTR_W-1:0]    ras_spec_sp;
    reg [RAS_CNT_W-1:0]    ras_arch_count;
    reg [RAS_CNT_W-1:0]    ras_spec_count;

    wire                    predictor_active = en && !predictor_disable;
    wire [PC_IDX_W-1:0]     if_pc_idx = if_pc[PC_IDX_W+1:2];
    wire [BTB_TAG_W-1:0]    if_pc_tag = if_pc[31:PC_IDX_W+2];
    wire [PC_IDX_W-1:0]     ex_pc_idx = ex_pc[PC_IDX_W+1:2];
    wire [BTB_TAG_W-1:0]    ex_pc_tag = ex_pc[31:PC_IDX_W+2];

    wire [LOCAL_HIST_W-1:0] if_local_hist_snapshot;
    wire [GHR_W-1:0]        if_ghr_snapshot;
    wire                    if_local_pred;
    wire                    if_global_pred;
    wire                    if_choice_use_global;
    wire                    if_branch_dir_pred = if_choice_use_global ? if_global_pred : if_local_pred;

    wire                    if_lookup_active = predictor_active && !stall;
    wire                    if_btb_raw_hit = btb_valid[if_pc_idx] && (btb_tag[if_pc_idx] == if_pc_tag);
    wire                    if_btb_hit = if_lookup_active && if_btb_raw_hit;
    wire [1:0]              if_btb_kind = btb_kind[if_pc_idx];
    wire [31:0]             if_btb_target = btb_target[if_pc_idx];

    wire [RAS_PTR_W-1:0]    if_ras_top_idx = ras_spec_sp - {{(RAS_PTR_W-1){1'b0}}, 1'b1};
    wire [31:0]             if_ras_top = ras_spec_stack[if_ras_top_idx];
    wire                    if_ras_not_empty = (ras_spec_count != {RAS_CNT_W{1'b0}});

    wire                    if_kind_branch = if_btb_hit && (if_btb_kind == KIND_BRANCH);
    wire                    if_kind_jal    = if_btb_hit && (if_btb_kind == KIND_JAL);
    wire                    if_kind_jalr   = if_btb_hit && (if_btb_kind == KIND_JALR);
    wire                    if_jalr_predictable = if_kind_jalr && if_ras_not_empty;
    wire                    if_ras_op_valid = if_kind_jal || if_jalr_predictable;

    wire [LOCAL_HIST_W-1:0] ex_local_hist_snapshot = ex_meta[META_LOCAL_HIST_HI:META_LOCAL_HIST_LO];
    wire [GHR_W-1:0]        ex_ghr_snapshot = ex_meta[META_GHR_HI:META_GHR_LO];
    wire                    ex_local_pred = ex_meta[META_LOCAL_PRED];
    wire                    ex_global_pred = ex_meta[META_GLOBAL_PRED];
    wire                    ex_pred_taken = ex_meta[META_PRED_TAKEN];
    wire                    ex_pred_valid = ex_meta[META_PRED_VALID];
    wire [1:0]              ex_pred_kind = ex_meta[META_KIND_HI:META_KIND_LO];
    wire                    ex_lookup_active = ex_meta[META_LOOKUP_ACTIVE];
    wire [31:0]             ex_pred_target = ex_meta[META_PRED_TARGET_HI:META_PRED_TARGET_LO];
    wire                    ex_is_control = ex_is_branch || ex_is_jal || ex_is_jalr;
    wire [1:0]              ex_actual_kind = ex_is_branch ? KIND_BRANCH :
                                             ex_is_jal    ? KIND_JAL    :
                                             ex_is_jalr   ? KIND_JALR   :
                                                           KIND_INVALID;

    // PDU 禁用开关只通过 predictor_active 统一影响 BTB/RAS/BHT/PHT/Choice。
    // en=0 表示 PDU 暂停 CPU，不更新任何预测状态；predictor_disable=1 表示 CPU 可运行但预测器完全旁路。
    wire                    train_fire = predictor_active && !stall && ex_valid && ex_is_branch && ex_lookup_active;
    wire                    train_choice_fire = train_fire && (ex_local_pred != ex_global_pred);
    wire                    btb_update_fire = predictor_active && !stall && ex_valid && ex_lookup_active && ex_is_control;
    wire                    btb_invalidate_fire = predictor_active && !stall && ex_valid && ex_bp_used && !ex_is_control;

    wire                    ex_kind_mismatch = ex_bp_used && ex_pred_valid && (ex_pred_kind != ex_actual_kind);
    wire                    ex_direction_mismatch = ex_bp_used && ex_pred_valid && (ex_pred_taken != ex_taken_actual);
    wire                    ex_target_mismatch = ex_bp_used && ex_pred_valid && ex_pred_taken && ex_taken_actual
                                                && (ex_pred_target != ex_target_actual);
    wire                    predicted_path_redirect = ex_kind_mismatch || ex_direction_mismatch || ex_target_mismatch;
    wire                    baseline_path_redirect = (!ex_bp_used) && ex_valid && ex_is_control && ex_taken_actual;
    wire                    ras_repair_fire = ex_valid && (predicted_path_redirect || baseline_path_redirect);

    local_predictor #(
        .PC_IDX_W(PC_IDX_W),
        .LOCAL_HIST_W(LOCAL_HIST_W)
    ) u_local_predictor (
        .clk            (clk),
        .rst            (rst),
        .en             (en),
        .pred_pc_idx    (if_pc_idx),
        .pred_hist      (if_local_hist_snapshot),
        .pred_taken     (if_local_pred),
        .train_valid    (train_fire),
        .train_pc_idx   (ex_pc_idx),
        .train_hist_snapshot(ex_local_hist_snapshot),
        .train_taken    (ex_taken_actual)
    );

    global_predictor #(
        .PC_IDX_W(PC_IDX_W),
        .GHR_W(GHR_W)
    ) u_global_predictor (
        .clk            (clk),
        .rst            (rst),
        .en             (en),
        .pred_pc_idx    (if_pc_idx),
        .pred_ghr       (if_ghr_snapshot),
        .pred_taken     (if_global_pred),
        .train_valid    (train_fire),
        .train_pc_idx   (ex_pc_idx),
        .train_ghr_snapshot(ex_ghr_snapshot),
        .train_taken    (ex_taken_actual)
    );

    choice_predictor #(
        .PC_IDX_W(PC_IDX_W)
    ) u_choice_predictor (
        .clk            (clk),
        .rst            (rst),
        .en             (en),
        .pred_pc_idx    (if_pc_idx),
        .pred_use_global(if_choice_use_global),
        .train_valid    (train_choice_fire),
        .train_pc_idx   (ex_pc_idx),
        .train_local_pred(ex_local_pred),
        .train_global_pred(ex_global_pred),
        .train_actual_taken(ex_taken_actual)
    );

    // IF 多路目标选择：
    // BRANCH 使用 BTB 目标和 tournament 方向；JAL 固定 taken 使用 BTB 目标；
    // JALR 只有在 BTB 命中且 RAS 非空时才预测，目标取 RAS 栈顶。
    assign if_pred_valid  = if_kind_branch || if_kind_jal || if_jalr_predictable;
    assign if_pred_taken  = if_kind_branch ? if_branch_dir_pred :
                            (if_kind_jal || if_jalr_predictable);
    assign if_pred_target = if_jalr_predictable ? if_ras_top : if_btb_target;

    // 64 位预测元数据随 IF/ID 和 ID/EX 流水寄存器前进，EX 阶段据此验证类型、方向和目标。
    assign if_pred_meta = {
        if_pred_target,
        if_ras_op_valid,
        if_lookup_active,
        if_btb_hit,
        if_btb_hit ? if_btb_kind : KIND_INVALID,
        if_pred_valid,
        if_pred_taken,
        if_choice_use_global,
        if_global_pred,
        if_local_pred,
        if_ghr_snapshot,
        if_local_hist_snapshot,
        if_pc_idx
    };

    assign redirect_valid = predicted_path_redirect;
    assign redirect_pc = ex_taken_actual ? ex_target_actual : ex_pc_plus4;

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < BTB_ENTRIES; i = i + 1) begin
                btb_valid[i] <= 1'b0;
                btb_tag[i] <= {BTB_TAG_W{1'b0}};
                btb_kind[i] <= KIND_INVALID;
                btb_target[i] <= 32'b0;
            end
            for (i = 0; i < RAS_DEPTH; i = i + 1) begin
                ras_arch_stack[i] <= 32'b0;
                ras_spec_stack[i] <= 32'b0;
            end
            ras_arch_sp <= {RAS_PTR_W{1'b0}};
            ras_spec_sp <= {RAS_PTR_W{1'b0}};
            ras_arch_count <= {RAS_CNT_W{1'b0}};
            ras_spec_count <= {RAS_CNT_W{1'b0}};
        end
        else if (en) begin
            if (btb_update_fire) begin
                // EX 阶段用真实 opcode 和真实目标更新 BTB，IF 只消费已经确认过的控制流类型。
                btb_valid[ex_pc_idx] <= 1'b1;
                btb_tag[ex_pc_idx] <= ex_pc_tag;
                btb_kind[ex_pc_idx] <= ex_actual_kind;
                btb_target[ex_pc_idx] <= ex_target_actual;
            end
            else if (btb_invalidate_fire) begin
                // 如果旧 BTB 表项命中了普通指令，说明发生 index 别名；清掉表项并由 EX 重定向回 PC+4。
                btb_valid[ex_pc_idx] <= 1'b0;
            end

            if (predictor_active && !stall && ex_valid && ex_lookup_active) begin
                // 解析态 RAS 只由 EX 阶段的真实 JAL/JALR 更新，是所有预测失败恢复的基准。
                if (ex_is_jal && (ras_arch_count != RAS_DEPTH_COUNT)) begin
                    ras_arch_stack[ras_arch_sp] <= ex_pc_plus4;
                    ras_arch_sp <= ras_arch_sp + {{(RAS_PTR_W-1){1'b0}}, 1'b1};
                    ras_arch_count <= ras_arch_count + {{(RAS_CNT_W-1){1'b0}}, 1'b1};
                end
                else if (ex_is_jalr && (ras_arch_count != {RAS_CNT_W{1'b0}})) begin
                    ras_arch_sp <= ras_arch_sp - {{(RAS_PTR_W-1){1'b0}}, 1'b1};
                    ras_arch_count <= ras_arch_count - {{(RAS_CNT_W-1){1'b0}}, 1'b1};
                end
            end

            if (!predictor_active) begin
                // PDU 禁用期间 BTB/RAS/BHT/PHT/Choice 都不训练；这里只丢弃旧投机 RAS 状态。
                for (i = 0; i < RAS_DEPTH; i = i + 1) begin
                    ras_spec_stack[i] <= ras_arch_stack[i];
                end
                ras_spec_sp <= ras_arch_sp;
                ras_spec_count <= ras_arch_count;
            end
            else if (!stall) begin
                if (ras_repair_fire) begin
                    // 一旦 EX 触发重定向，年轻指令会被 flush；RAS 投机态也恢复到“执行完当前 EX 指令后”的状态。
                    for (i = 0; i < RAS_DEPTH; i = i + 1) begin
                        ras_spec_stack[i] <= ras_arch_stack[i];
                    end
                    if (ex_is_jal && ex_lookup_active && (ras_arch_count != RAS_DEPTH_COUNT)) begin
                        ras_spec_stack[ras_arch_sp] <= ex_pc_plus4;
                        ras_spec_sp <= ras_arch_sp + {{(RAS_PTR_W-1){1'b0}}, 1'b1};
                        ras_spec_count <= ras_arch_count + {{(RAS_CNT_W-1){1'b0}}, 1'b1};
                    end
                    else if (ex_is_jalr && ex_lookup_active && (ras_arch_count != {RAS_CNT_W{1'b0}})) begin
                        ras_spec_sp <= ras_arch_sp - {{(RAS_PTR_W-1){1'b0}}, 1'b1};
                        ras_spec_count <= ras_arch_count - {{(RAS_CNT_W-1){1'b0}}, 1'b1};
                    end
                    else begin
                        ras_spec_sp <= ras_arch_sp;
                        ras_spec_count <= ras_arch_count;
                    end
                end
                else begin
                    // IF 阶段投机更新 RAS：预测 JAL 时压入返回地址，预测 JALR 时弹出栈顶。
                    // 该路径与 BTB 查找共享 predictor_active，因此 PDU 禁用时不会发生任何 push/pop。
                    if (if_kind_jal && if_pred_valid && (ras_spec_count != RAS_DEPTH_COUNT)) begin
                        ras_spec_stack[ras_spec_sp] <= if_pc + 32'd4;
                        ras_spec_sp <= ras_spec_sp + {{(RAS_PTR_W-1){1'b0}}, 1'b1};
                        ras_spec_count <= ras_spec_count + {{(RAS_CNT_W-1){1'b0}}, 1'b1};
                    end
                    else if (if_jalr_predictable && if_pred_valid) begin
                        ras_spec_sp <= ras_spec_sp - {{(RAS_PTR_W-1){1'b0}}, 1'b1};
                        ras_spec_count <= ras_spec_count - {{(RAS_CNT_W-1){1'b0}}, 1'b1};
                    end
                end
            end
        end
    end
endmodule
