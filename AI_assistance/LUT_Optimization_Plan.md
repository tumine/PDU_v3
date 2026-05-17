# LUT 资源优化实施方案

## 1. 当前资源瓶颈判断

用户提供的 Vivado 综合估算显示 LUT 约为 120649 / 63400，利用率约 190.30%，已经明显超过器件容量；FF、BRAM、DSP 的利用率分别约为 29.66%、5.93%、5.00%，说明当前瓶颈主要不是寄存器或存储块数量，而是组合逻辑、分布式 RAM、宽选择器、复杂控制树带来的 LUT 消耗。

本轮优化的主线是“裁剪冗余硬件功能 + 简化 Cache 控制逻辑”。重点优先处理对 LUT 影响最大、风险相对可控的 CPU/Cache 私有路径。

## 2. 基础裁剪评估

### 2.1 ALU 乘除法功能裁剪

涉及文件：

- `vsrc/PDU/CPU/your_cpu/alu.v`
- `vsrc/PDU/CPU/your_cpu/decoder.v`
- `vsrc/PDU/CPU/your_cpu/cpu.v`
- `vsrc/PDU/CPU/your_cpu/pipe_reg.v`

现状分析：

- `alu.v` 中实现了 RV32M 的 `MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU`。
- 乘法路径包含多个 32/33 位乘法器：有符号乘、无符号乘、有符号乘无符号扩展乘。
- 除法和取余使用 `/`、`%` 组合表达式，Vivado 往往会综合为很大的组合除法网络；即使综合器部分映射到 DSP，除法/取余仍会带来大量 LUT。
- `decoder.v` 识别 `funct7 == 7'b0000001` 的 RV32M 指令，并把它们送入 ALU。
- 当前 ALU 操作码使用 5 位，主要是为了容纳 RV32M 后扩展到 19 个操作码；裁剪 M 扩展后实际只需要 11 个基础操作，4 位即可覆盖。

拟执行修改：

- 在 `alu.v` 删除所有乘法、除法、取余相关 localparam、wire 和 case 分支。
- 将 ALU 保留为 RV32I 基础运算：`ADD/SUB/SLL/SRL/SRA/AND/OR/XOR/SLT/SLTU/B_OUT`。
- 将 `alu.v` 的 `op` 从 5 位缩小为 4 位。
- 在 `decoder.v` 删除 RV32M 操作码 localparam 和 `funct7 == 7'b0000001` 的解码分支。
- R-type 指令只支持 RV32I 的 `funct7 == 7'b0000000` 与 `funct7[5]` 区分的基础操作；遇到 M 扩展编码时不产生硬件乘除法操作，按非法/不支持指令处理为无寄存器写入的安全 NOP。
- 在 `cpu.v` 和 `pipe_reg.v` 中把流水线携带的 `alu_op` 宽度由 5 位缩小到 4 位，进一步减少段寄存器扇出和控制 MUX。

预期收益：

- 删除组合除法器和取余器是本轮最重要的 LUT 回收点，预期可释放数万级 LUT，具体取决于 Vivado 原先对 `/`、`%` 的实现策略。
- 删除多组乘法器可减少 DSP 使用或乘法相关 LUT/DSP 周边控制逻辑。
- `alu_op` 宽度缩减带来的是小幅但全流水线覆盖的控制资源下降。

### 2.2 Cache 替换策略精简为纯 LRU

涉及文件：

- `vsrc/PDU/CPU/your_cpu/n_way_cache.v`
- `vsrc/PDU/CPU/your_cpu/cpu.v`

现状分析：

- `n_way_cache.v` 的参数 `REPLACE_POLICY` 同时保留了 0-LRU、1-FIFO、2-Random、3-LFU 四套策略入口。
- 即使 `cpu.v` 例化时传入 `.REPLACE_POLICY(0)`，源代码仍包含 FIFO 指针、Random 指针、LFU 计数器、最小 LFU 搜索树和多策略条件分支。Vivado 通常能常量传播裁剪一部分，但参数化分支、数组和复位更新逻辑仍会增加综合复杂度和 LUT 风险。
- 当前实际例化为 2-way、8-set、4-word/line 的小型 DCache，纯 LRU 足够满足功能需求。

拟执行修改：

- 移除 `REPLACE_POLICY` 参数，Cache 模块固定为 LRU。
- 删除 `fifo_ptr`、`rand_ptr`、`lfu_cnt` 及其复位、命中更新、refill 更新逻辑。
- 替换 way 选择逻辑固定为“优先 invalid way，否则选择 `lru_age == WAY_NUM - 1` 的 way”。
- LRU 更新逻辑只保留命中更新与 refill 更新两条路径，并用中文注释解释年龄计数含义。
- 在 `cpu.v` 例化 Cache 时删除 `.REPLACE_POLICY(0)` 参数。

预期收益：

- 直接删除 LFU 计数器数组、FIFO/Random 状态和最小值比较树。
- 减少替换选择组合 MUX 和状态更新条件树。
- 对当前 2-way 配置收益中等；如果后续扩大路数，固定 LRU 相比多策略切换的收益会更明显。

## 3. 拓展优化方案论证

### 3.1 将 CPU IMEM/DMEM 显式约束为 Block RAM

涉及文件：

- `vsrc/PDU/CPU/memory/IMEM.v`
- `vsrc/PDU/CPU/memory/DMEM.v`

现状分析：

- PDU 侧 `PDU_IMEM.v` / `PDU_DMEM.v` 已使用 `(* ram_style = "block" *)`。
- CPU 侧 `IMEM.v` / `DMEM.v` 目前没有显式 `ram_style = "block"`，在异步读或多读组合访问形态下，Vivado 可能推断为分布式 RAM 或 LUT 组合逻辑。
- 用户提供的 BRAM 使用量仅 8 / 135，非常宽裕；将 CPU 指令/数据存储尽量推入 BRAM 是合理方向。

可行性与风险：

- 低风险做法：先为 CPU IMEM/DMEM 的 `mem` 数组添加 `(* ram_style = "block" *)`，提示 Vivado 优先使用 BRAM。
- 更激进做法：改成同步读 RAM，更容易稳定推断 BRAM，但会改变取指/访存读延迟，需要重做流水线时序和 PDU 调试路径，不建议混入本轮。

本轮建议：

- 执行低风险属性优化：添加 `ram_style = "block"`。
- 暂不改 IMEM/DMEM 读时序。

预期收益：

- 如果 Vivado 原先把 CPU 存储推成 LUTRAM/分布式 RAM，则可明显降低 LUT/LUTRAM 压力。
- 若 Vivado 已经自行推断为 BRAM，则此项收益有限，但不会引入明显功能风险。

### 3.2 Cache RAM 推断优化

涉及文件：

- `vsrc/PDU/CPU/your_cpu/n_way_cache.v`

现状分析：

- 文件内部的 `bram` 模块名称虽叫 bram，但实现为组合读 `assign dout = mem[raddr]`，并在复位时 for 循环清空整个 RAM。
- Xilinx BRAM 通常更偏好同步读；大规模复位清零 RAM 内容也会阻碍 BRAM 推断，可能导致分布式 RAM 或 FF/LUT 实现。
- 由于 Cache 当前 LOOKUP 状态依赖组合读，同步读改造会增加至少一个 tag/data 读等待周期，需要调整 FSM，不适合作为本轮低风险裁剪。

本轮建议：

- 不改变 Cache RAM 读时序。
- 在文档中作为后续高收益优化记录：后续可将 tag/data RAM 改为同步读，只复位 valid bit，不清空 data RAM，从而更稳地使用 BRAM。

预期收益：

- 后续若实施，能把 Cache data array 从 LUTRAM/LUT 迁移到 BRAM，同时减少复位清零树。

### 3.3 段间寄存器按阶段拆分，消除统一大端口模块

涉及文件：

- `vsrc/PDU/CPU/your_cpu/pipe_reg.v`
- `vsrc/PDU/CPU/your_cpu/cpu.v`

现状分析：

- 当前 `seg_reg` 是统一段间寄存器，包含所有可能跨段的信号；每一级例化时大量输入接 0、大量输出悬空。
- Vivado 一般能裁剪未使用输出，但统一模块会增加前端综合负担，也容易产生不必要的控制扇出。

本轮建议：

- 只做与 ALU 裁剪直接相关的 `alu_op` 位宽缩小。
- 不在本轮重写为 `if_id_reg/id_ex_reg/ex_mem_reg/mem_wb_reg` 四个专用模块，避免把功能裁剪扩展成大面积流水线重构。

预期收益：

- 后续专用化可以进一步降低控制 MUX 和无效寄存器风险，但收益相对 ALU/Cache 裁剪小，且改动面较大。

### 3.4 寄存器堆实现方式

涉及文件：

- `vsrc/PDU/CPU/your_cpu/regfile.v`

现状分析：

- 当前寄存器堆为 32 x 32，2 个异步读端口 + 1 个同步写端口 + 1 个调试异步读端口。
- 多异步读端口天然更容易使用 LUT/寄存器实现，不容易直接推断单个 BRAM。

本轮建议：

- 不修改寄存器堆。调试端口和流水线读端口对 PDU 可观察性很重要，改为 BRAM 多副本或时分读会影响时序和控制。

后续方向：

- 若 LUT 仍超标，可考虑在 CPU 暂停时复用一个读端口给 debug，减少第三读端口；或用多副本 BRAM/分布式 RAM 结构换取更可控资源。

## 4. 本轮拟定重构清单

必须执行：

1. `vsrc/PDU/CPU/your_cpu/alu.v`
   - 删除 RV32M 乘除法/取余硬件。
   - ALU 操作码宽度由 5 位缩小到 4 位。
   - 添加中文注释说明 M 扩展已裁剪，未支持操作返回 0。

2. `vsrc/PDU/CPU/your_cpu/decoder.v`
   - 删除 RV32M localparam 和解码分支。
   - `funct7 == 7'b0000001` 的 R-type 指令不再写寄存器，避免错误地走基础 ALU。
   - ALU 操作码输出由 5 位缩小到 4 位。
   - 添加中文注释说明不支持 M 扩展的处理方式。

3. `vsrc/PDU/CPU/your_cpu/pipe_reg.v`
   - `alu_op_in/out` 和对应 `pipe_reg` 实例宽度由 5 位改为 4 位。
   - 添加中文注释说明控制位宽缩小是配合 ALU 裁剪。

4. `vsrc/PDU/CPU/your_cpu/cpu.v`
   - 所有 `alu_op_*` 信号由 5 位改为 4 位。
   - Cache 例化删除 `REPLACE_POLICY` 参数。
   - 添加中文注释说明 DCache 已固定 LRU。

5. `vsrc/PDU/CPU/your_cpu/n_way_cache.v`
   - 删除多策略参数和 FIFO/Random/LFU 相关状态。
   - 固定使用纯 LRU 替换策略。
   - 保留 invalid way 优先选择。
   - 添加中文注释说明 LRU 状态、替换选择和更新策略。

建议同步执行：

6. `vsrc/PDU/CPU/memory/IMEM.v`
   - 为 `mem` 添加 `(* ram_style = "block" *)`。
   - 添加中文注释说明引导 Vivado 使用 BRAM，减少 LUTRAM/LUT。

7. `vsrc/PDU/CPU/memory/DMEM.v`
   - 为 `mem` 添加 `(* ram_style = "block" *)`。
   - 添加中文注释说明后端数据存储优先映射到 BRAM。

暂缓执行，仅作为后续可选：

- Cache RAM 同步读 BRAM 化。
- 段间寄存器按流水阶段专用化。
- 寄存器堆 debug 读端口复用/BRAM 多副本化。

## 5. 预期效果

资源改善目标：

- 第一目标：移除组合除法/取余后，LUT 总量应有最大幅度下降，目标是把 LUT 从 190% 利用率显著拉低，至少消除最夸张的综合爆炸项。
- 第二目标：Cache 只保留 LRU 后，删除多策略状态与比较树，降低控制逻辑 LUT，并让综合结果更稳定、可解释。
- 第三目标：CPU IMEM/DMEM 添加 BRAM 约束后，尽量利用当前仍很空闲的 BRAM 资源，减少存储阵列对 LUT/LUTRAM 的占用。

预期综合趋势：

- LUT：大幅下降，主要来自 ALU 除法/取余裁剪，其次来自 Cache 多策略逻辑删除和存储器 BRAM 约束。
- DSP：若乘法曾被映射到 DSP，DSP 数量可能下降；若原先被映射到 LUT，LUT 会进一步下降。
- BRAM：可能小幅上升，但当前 BRAM 余量充足。
- FF：变化不大或小幅下降，主要来自删除 Cache 替换策略寄存器。

验证计划：

- 完成代码修改后先做静态搜索，确认 `MUL/DIV/REM/REPLACE_POLICY/fifo_ptr/rand_ptr/lfu_cnt` 等硬件逻辑已清理。
- 使用可用的 Verilog 工具或 Vivado 重新综合进行语法/综合验证；若本机没有可调用 Vivado，则记录无法执行综合的原因。
- 重新查看 Vivado utilization report，对比 LUT、LUTRAM、BRAM、DSP 的变化。

