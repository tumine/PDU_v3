# Benchmarking 功能集成方案

## 1. 现状分析结论

### 1.1 PDU 接管 CPU 的工作流

当前系统由 `TOP.v` 连接 PDU soft kernel、PDU 总线、`CPU_ctrl`、学生 CPU 与后端 IMEM/DMEM。

PDU 的交互链路如下：

1. 串口命令由 `PDU-Control/cmd.c` 解析。
2. 控制固件通过 `mmap.h` 中的 memory-mapped 寄存器访问 `CPU_ctrl`。
3. `PDU_BUS.v` 按地址把 PDU kernel 的数据访问分发到：
   - `0x00004000 ~ 0x00007fff`：PDU DMEM
   - `0x00008000 ~ 0x000080ff`：UART
   - `0x00008100 ~ 0x000081ff`：CPU_ctrl
4. `CPU_ctrl.v` 维护 `CORE_COMMAND`、断点、寄存器查看、指令/数据存储器访问等寄存器窗口。
5. `CPU_ctrl` 的状态机通过 `cpu_rst` 和 `cpu_global_en` 接管 CPU：
   - `RESET`：拉高 `cpu_rst`，CPU 内部 PC 与流水线寄存器复位。
   - `STEP`：拉高 `cpu_global_en`，等待一次 `cpu_commit_en_pulse` 后暂停。
   - `RUN`：持续拉高 `cpu_global_en`，直到命中断点或 `cpu_commit_halt`。
6. `TOP.v` 将 `cpu_rst`、`cpu_global_en` 从 `sys_clk` 同步到 `cpu_clk`，CPU 所有流水线寄存器只看 `cpu_clk` 域内的同步信号。

一个重要细节：硬件已经支持 `COMMAND_RUN`，但当前串口固件里的 `run()` 是循环调用 `step1()`，即反复单步。这种方式会把 PDU 串口/ACK 开销插入每条指令之间，不能用于 Benchmark。性能测试必须新增独立的硬件连续运行命令，或改造 `run()` 使用 `COMMAND_RUN`。为了不改变现有调试习惯，本方案新增 `brun` 命令。

### 1.2 无分支预测版本的控制流回退基线

上一提交链路中，`e32b70a` 是“初步完成分支预测功能”，其父提交 `e32b70a^` 是无预测版本。该版本在 `vsrc/PDU/CPU/your_cpu/cpu.v` 中的分支控制流如下：

```verilog
wire is_branch_EX = (opcode_EX == 7'b1100011);
wire is_jal_EX    = (opcode_EX == 7'b1101111);
wire pc_sel_EX    = is_branch_EX ? cmp_res_EX : (is_jal_EX | is_jalr_EX);

assign next_pc = pc_sel_EX ? (is_jalr_EX ? {alu_out_EX[31:1], 1'b0} : alu_out_EX)
                           : pc_plus_4_IF;

wire control_hazard = pc_sel_EX;

assign if_id_flush = (!dcache_wait) && control_hazard;
assign id_ex_flush = (!dcache_wait) && (load_use_hazard || control_hazard);
```

也就是说，无预测状态下：

- IF 阶段永远按 `PC + 4` 顺序取指。
- 分支、JAL、JALR 都在 EX 阶段得到真实跳转结果。
- EX 判断需要跳转时，下一拍用真实目标覆盖 PC。
- 同时冲刷 IF/ID 和 ID/EX，清掉已经顺序取进来的错误路径指令。
- `dcache_wait` 优先级最高，等待期间不执行 flush，避免流水线状态在 Cache miss 中被错误清空。

因此，禁用预测器时不需要重造控制流，只需要让当前 CPU 回到这条 EX 裁决路径。

## 2. 计时边界定义

### 2.1 计时单位

Benchmark 主计数器放在 CPU 时钟域，计数单位定义为 CPU 执行时钟 `cpu_clk` 周期。理由：

- 指令取指、流水线推进、Cache stall、WB retire 都发生在 `cpu_clk` 域。
- 分支预测性能收益应以处理器周期计量，否则 `sys_clk -> cpu_clk` 同步延迟会污染结果。
- 如需换算板级 `sys_clk` 周期，可按 `clock_divider.v` 的固定分频关系在固件打印时换算；性能对比仍以 CPU cycle 为准。

文档和串口输出中建议使用名称 `cycles`，含义为 CPU 时钟周期。

### 2.2 Start 触发条件

Benchmark 程序必须先执行 `reset`，再配置预测器开关，最后执行 `brun`。

计时器在 CPU 内部以如下硬件条件启动：

```verilog
start_pulse = bench_armed && !bench_running && global_en && !pc_stall;
```

该条件对应 CPU 第一次真正接受取指的 `cpu_clk` 上升沿：

- `bench_armed`：PDU 已经通过控制寄存器声明下一次连续运行是 Benchmark。
- `global_en`：PDU 已经把 CPU 放行。
- `!pc_stall`：PC 和 IF/ID 确实会推进，不把尚未开始执行的等待周期算入程序时间。

在 reset 后的正常 `brun` 中，这个上升沿正是第一条指令从 IF 被捕获进 IF/ID 的时刻。计数器在该上升沿从 0 变为 1，因此包含第一条指令开始执行的周期。

### 2.3 Stop 触发条件

Benchmark 程序以 `EBREAK` 作为最后一条指令。计时器在 CPU 内部以如下硬件条件停止：

```verilog
stop_pulse = bench_running && commit_advance && commit_WB && halt_WB;
```

该条件对应最后一条 `EBREAK` 在 WB 阶段完全退休的 `cpu_clk` 上升沿：

- `commit_advance = global_en && !dcache_wait`，保证 Cache stall 中不重复退休。
- `commit_WB` 是当前 WB 段有效退休指令。
- `halt_WB` 表示该退休指令是 `EBREAK`。

停止时锁存 `cycle_count + 1`，把最后一条指令退休的周期也计入结果。这样得到的跨度是“第一条指令被流水线接受”到“最后一条指令完全退休”的闭区间 CPU 周期数，包含流水线填充、Cache stall、load-use stall、分支冲刷惩罚和预测收益。

## 3. PDU 改造方案

### 3.1 CPU_ctrl 寄存器扩展

当前 `CPU_ctrl` 在 `CORE_CURRENT_PC` 的 `0x54` 与断点地址窗口 `0x60 ~ 0x7c` 之间还有两个 32-bit 空位。建议新增：

| 偏移 | 名称 | 方向 | 说明 |
| --- | --- | --- | --- |
| `0x58` | `CORE_BENCH_CTRL` | R/W | Benchmark 控制与状态寄存器 |
| `0x5c` | `CORE_BENCH_CYCLES` | R | 最近一次 Benchmark 的 CPU 周期数 |

`CORE_BENCH_CTRL` 位定义：

| 位 | 名称 | 方向 | 说明 |
| --- | --- | --- | --- |
| `[0]` | `branch_predictor_disable` | R/W | `1` 禁用预测器，`0` 启用预测器 |
| `[1]` | `benchmark_arm` | R/W | `1` 表示下一次 `COMMAND_RUN` 启动计时 |
| `[2]` | `benchmark_clear` | W1P | 写 1 清空计数器、done 标志和 snapshot |
| `[8]` | `benchmark_done` | R | CPU 已经在 halt retire 点锁存周期数 |
| `[9]` | `benchmark_running` | R | CPU 计时器当前正在计数 |

`CORE_BENCH_CYCLES` 返回最近一次完成的 `cycle_count_snapshot[31:0]`。32 位在当前 CPU 频率下足够覆盖数分钟级运行；若后续需要更长程序，可把 CPU_ctrl 窗口扩展到 `0x00008200` 以后再加入高 32 位。

### 3.2 计时单元结构

计时器建议放入 `CPU` 内部，或作为 `benchmark_timer` 子模块实例化在 `cpu.v` 中。原因是 Stop 必须使用 `commit_WB/halt_WB/commit_advance` 这组 CPU 内部同拍信号；若在 `TOP.v` 外部采样已经寄存输出的 `commit_halt`，会晚一个 CPU 周期停止。

建议接口：

```verilog
module benchmark_timer (
    input  wire        clk,
    input  wire        rst,
    input  wire        global_en,
    input  wire        pc_stall,
    input  wire        arm,
    input  wire        clear,
    input  wire        commit_advance,
    input  wire        commit_wb,
    input  wire        halt_wb,
    output reg         running,
    output reg         done,
    output reg [31:0]  cycles
);
```

状态机建议：

- `IDLE`：等待 `arm && global_en && !pc_stall`。
- `RUNNING`：每个 `global_en` 的 CPU 周期递增，stall 周期也计入；遇到 `stop_pulse` 锁存最后结果并进入 `DONE`。
- `DONE`：保持 `cycles` 稳定，等待 PDU 写 `benchmark_clear`。

核心计数规则：

```verilog
if (clear || rst) begin
    cycles  <= 32'b0;
    running <= 1'b0;
    done    <= 1'b0;
end
else if (start_pulse) begin
    cycles  <= 32'd1;
    running <= 1'b1;
    done    <= 1'b0;
end
else if (running && global_en) begin
    if (stop_pulse) begin
        cycles  <= cycles + 32'd1;
        running <= 1'b0;
        done    <= 1'b1;
    end
    else begin
        cycles <= cycles + 32'd1;
    end
end
```

### 3.3 跨时钟域处理

控制方向是 `sys_clk -> cpu_clk`：

- `branch_predictor_disable`
- `benchmark_arm`
- `benchmark_clear`

这些信号在 `TOP.v` 中使用两级同步进入 CPU 时钟域。`benchmark_clear` 建议实现为 toggle 或保持型 clear 请求，避免单拍脉冲跨域丢失。最简单安全的实现是：

- `CPU_ctrl` 中保存 `benchmark_clear_req` level。
- CPU 计时器看到 clear 后清空并拉高 `benchmark_clear_ack`。
- `TOP.v` 将 ack 同步回 `sys_clk`，`CPU_ctrl` 再清除请求。

数据方向是 `cpu_clk -> sys_clk`：

- `benchmark_done`
- `benchmark_running`
- `benchmark_cycles`

`cycles` 只要求在 `done=1` 后读取。由于 done 后计数值保持稳定，`CPU_ctrl` 可以在同步到 `benchmark_done` 上升沿后锁存 `benchmark_cycles` 到 `core_benchmark_cycles_snapshot`。不要在运行中把多位计数器当作实时跨域总线直接读。

### 3.4 串口命令协议

在 `PDU-Control/cmd.h/cmd.c/mmap.h` 中新增命令。

建议命令：

| 命令 | 参数 | 行为 |
| --- | --- | --- |
| `bpd` | 无 | 读取当前预测器禁用状态 |
| `bpd 0` | `0` | 启用分支预测器 |
| `bpd 1` | `1` | 禁用分支预测器 |
| `cycles` | 无 | 读取并打印 `CORE_BENCH_CYCLES` |
| `brun` | 无 | 清空并 arm 计时器，发起硬件 `COMMAND_RUN`，halt 后打印周期数 |

`brun` 的固件流程：

1. 写 `CORE_BENCH_CTRL[2] = 1` 清空计时器。
2. 写 `CORE_BENCH_CTRL[1] = 1` arm 计时器，保留 bit0 的预测器配置。
3. 写 `CORE_COMMAND = COMMAND_RUN`。
4. 等待 `CORE_ACK == 1`。
5. 若 `CORE_BREAK == 8` 且 `CORE_BENCH_CTRL[8] == 1`，打印：
   - `Halted at <CORE_CURRENT_PC>`
   - `Benchmark cycles: <CORE_BENCH_CYCLES>`
6. 清 `CORE_COMMAND`，等待 ACK 释放。
7. 清 `CORE_BENCH_CTRL[1]`，避免下一次普通运行误触发。

注意：Benchmark 运行时不应设置断点。若 `COMMAND_RUN` 因断点停止而非 `EBREAK` 停止，本次周期数不能作为完整程序运行时间。

## 4. CPU 旁路改造方案

### 4.1 顶层布线

新增信号路径：

```text
PDU-Control 串口命令
  -> CPU_ctrl.CORE_BENCH_CTRL[0]
  -> TOP.v sys_clk 到 cpu_clk 两级同步
  -> CPU.branch_predictor_disable
  -> cpu.v IF PC 选择与 branch_predictor 训练门控
```

涉及端口：

- `CPU_ctrl` 新增输出 `branch_predictor_disable`。
- `TOP.v` 新增同步寄存器，并把同步后的 `branch_predictor_disable_cpu` 传给 `CPU`。
- `CPU` 新增输入端口 `branch_predictor_disable`。

约束：固件应只在 CPU 暂停或 reset 后修改该位。硬件仍要做到运行中切换不破坏正确性。

### 4.2 IF 阶段旁路

当前 IF 使用：

```verilog
next_pc = bp_redirect_valid ? bp_redirect_pc
        : (bp_pred_valid_IF && bp_pred_taken_IF) ? bp_pred_target_IF
        : pc_plus_4_IF;
```

改造后应分离“本条指令是否使用了预测器”的流水线元信息：

```verilog
bp_used_IF = !branch_predictor_disable && bp_pred_valid_IF;
```

IF 取指选择：

```verilog
next_pc = control_redirect ? control_redirect_pc
        : (bp_used_IF && bp_pred_taken_IF) ? bp_pred_target_IF
        : pc_plus_4_IF;
```

当 `branch_predictor_disable=1` 时，`bp_used_IF=0`，IF 必然走 `PC + 4`。

### 4.3 EX 阶段回退路径

新增 `bp_used_ID/bp_used_EX` 一位 sideband 寄存器，与现有 `bp_meta_IF/ID/EX` 一起经过 `pipe_reg`，使用相同 stall/flush。

EX 控制流选择：

```verilog
wire no_predict_redirect = actual_taken_EX;
wire predict_redirect    = bp_redirect_valid;

wire control_redirect = bp_used_EX ? predict_redirect : no_predict_redirect;
wire [31:0] control_redirect_pc = actual_taken_EX ? actual_target_EX : pc_plus_4_EX;
```

语义：

- 本条指令在 IF 使用过预测器：按预测器的 mispredict 逻辑纠错。
- 本条指令在 IF 未使用预测器：完全回到上一提交的无预测语义，只有真实 taken/JAL/JALR 才 flush 并 redirect。

这样即使运行中切换 `branch_predictor_disable`，每条已经在流水线中的控制流指令仍按它自己在 IF 阶段的模式解析，不会出现半预测、半无预测的混合语义。

### 4.4 预测器状态冻结

需要两层保护：

1. 预测器写使能冻结：

```verilog
predictor_train_en = global_en && !dcache_wait && !branch_predictor_disable;
```

2. 训练合法性来自随指令流动的 `bp_used_EX`：

```verilog
train_fire = predictor_train_en && ex_valid && ex_is_branch && bp_used_EX;
```

这样可以避免：

- 禁用预测器期间仍更新 BHT/PHT/GHR/Choice。
- 禁用期间取入的分支在稍后重新启用预测器后，使用无效 meta 污染历史表。
- Cache stall 期间同一条 EX 分支重复训练。

`branch_predictor.v` 建议新增 `disable` 或 `train_en` 输入，或在 `cpu.v` 中直接门控 `.en()` 与训练条件。由于当前 `branch_predictor` 内部 `train_fire` 已经包含 `en && !stall && ex_valid && ex_is_branch`，建议把 `bp_used_EX` 作为新增输入，训练条件改为：

```verilog
wire train_fire = en && !stall && ex_valid && ex_is_branch && ex_bp_used;
```

## 5. 潜在冲突排查与解决方案

### 5.1 计时器 Stop 晚一拍

风险：若计时器在 `TOP.v` 使用 CPU 已寄存输出的 `commit_halt`，外部 always block 会在下一拍才看到 halt，结果多计 1 个 CPU 周期。

解决：计时器放在 `CPU` 内部，直接使用 `commit_advance/commit_WB/halt_WB` 同拍停止。

### 5.2 `sys_clk` 与 `cpu_clk` 跨域污染计数

风险：PDU 控制信号来自 `sys_clk`，CPU 运行在 `cpu_clk`，单拍 clear/arm 可能丢失，多位计数器直接读可能亚稳。

解决：

- 控制请求采用 level/ack 或 toggle 同步。
- 计数值只在 `done` 后跨域锁存。
- 串口命令只读取 snapshot，不读取运行中的多位计数器。

### 5.3 禁用预测器后 JAL 未跳转

风险：当前预测器把 JAL 在 IF 固定预测为 taken；若简单屏蔽 IF 预测，但 EX 仍只用 `bp_redirect_valid`，JAL 不会产生 redirect。

解决：当 `bp_used_EX=0` 时，EX 使用无预测基线 `actual_taken_EX` 作为 redirect 条件。JAL/JALR 都会在 EX 正常跳转。

### 5.4 运行中切换预测器导致训练污染

风险：某条分支在禁用状态下取指，随后预测器重新启用，该分支到 EX 后可能用空 meta 训练表项。

解决：新增 `bp_used` sideband。只有 `bp_used_EX=1` 的分支允许训练；禁用状态取入的分支永远按无预测路径处理且不训练。

### 5.5 Cache stall 与 flush 冲突

风险：DCache miss 时 EX/MEM/WB 保持，若此时 flush 或 train 继续发生，会清错流水线或重复训练。

解决：保持现有优先级：

```verilog
if_id_flush = (!dcache_wait) && control_hazard;
id_ex_flush = (!dcache_wait) && (load_use_hazard || control_hazard);
```

预测器训练也必须包含 `!dcache_wait`。

### 5.6 关键路径恶化

风险：在 IF PC 选择路径中增加过多组合逻辑会影响时序。

解决：

- `branch_predictor_disable` 在 `cpu_clk` 域寄存后使用。
- 新增逻辑只是在现有 `next_pc` mux 前增加一位使能选择，不插入 ALU/compare 数据路径。
- `bp_used` 是寄存 sideband，不参与 ALU、寄存器堆、DCache 地址路径。
- 计时器只看现有控制信号，不反向影响流水线控制。

## 6. 预计修改文件

第三阶段预计修改：

- `vsrc/PDU/CPU/CPU_ctrl.v`
  - 新增 `CORE_BENCH_CTRL`、`CORE_BENCH_CYCLES`。
  - 新增 `branch_predictor_disable` 输出。
  - 新增计时器 arm/clear/done/running 的寄存器读写和 CDC 对接。
- `vsrc/TOP.v`
  - 新增 branch predictor disable 与 benchmark 控制信号跨域同步。
  - 新增 CPU benchmark 结果回传到 CPU_ctrl。
- `vsrc/PDU/CPU/your_cpu/cpu.v`
  - 新增 `branch_predictor_disable`、benchmark timer 端口。
  - 新增 `bp_used` sideband。
  - 改造 IF next PC mux 和 EX redirect 选择。
  - 集成 CPU 内部精确计时器。
- `vsrc/PDU/CPU/your_cpu/branch_predictor.v`
  - 新增训练合法输入或 disable 输入。
  - 禁用或未使用预测器的指令不更新历史表。
- `PDU-Control/mmap.h`
  - 新增 benchmark 寄存器地址和 bit 定义。
- `PDU-Control/cmd.h`
  - 新增 `BRANCH_PREDICTOR_DISABLE`、`BENCHMARK_RUN`、`BENCHMARK_CYCLES` 等命令枚举和函数声明。
- `PDU-Control/cmd.c`
  - 新增 `bpd`、`cycles`、`brun` 串口命令解析和执行。
- `PDU-Control/README.md`
  - 记录新增命令用法。

## 7. 推荐测试流程

预测器开启测试：

```text
reset
bpd 0
brun
cycles
```

预测器关闭测试：

```text
reset
bpd 1
brun
cycles
```

对比要求：

- 两次测试加载同一份 IMEM/DMEM。
- 每次运行前都 reset，避免寄存器、Cache、预测器 warm state 混入结果。
- 如需比较 warm predictor 收益，可额外设计“不开 reset 连续运行”的实验，但必须单独标注。
- Benchmark 程序以 `EBREAK` 结束，不设置断点。

