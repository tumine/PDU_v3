# LUT 资源优化执行总结

## 1. 本次实际完成的工作

本次重构按照 `AI_assistance/LUT_Optimization_Plan.md` 中 1-7 项执行，并补充了 Vivado 非工程综合验证脚本与报告输出。

已完成事项：

1. 裁剪 CPU ALU 的 RV32M 乘法、除法和取余硬件。
2. 删除 decoder 中 RV32M 指令到 ALU 的操作码映射。
3. 将 ALU 控制码从 5 位缩小到 4 位。
4. 将流水线段间寄存器和 CPU 内部 `alu_op` 信号同步缩小到 4 位。
5. 在 Cache 模块中固定纯 LRU 替换策略，并删除多策略参数收口。
6. 在 CPU DCache 例化处删除 `REPLACE_POLICY` 参数。
7. 为 CPU 侧 IMEM/DMEM 添加 `(* ram_style = "block" *)` 属性，提示 Vivado 优先使用 BRAM。
8. 新增 Vivado batch 综合脚本 `AI_assistance/run_lut_opt_synth.tcl`，生成综合后资源报告。

## 2. 修改清单与 diff 简述

### `vsrc/PDU/CPU/your_cpu/alu.v`

- `op` 位宽由 `[4:0]` 改为 `[3:0]`。
- 删除 `MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU` localparam。
- 删除有符号乘法、无符号乘法、有符号乘无符号扩展乘相关 wire。
- 删除 `/`、`%` 组合除法/取余 case 分支。
- 保留 `ADD/SUB/SLL/SRL/SRA/AND/OR/XOR/SLT/SLTU/B_OUT`。

资源意图：彻底阻断 Vivado 综合组合乘除法器，释放大规模 LUT/DSP 周边逻辑。

### `vsrc/PDU/CPU/your_cpu/decoder.v`

- `alu_op` 输出位宽由 `[4:0]` 改为 `[3:0]`。
- 删除 RV32M 操作码定义。
- `funct7 == 7'b0000001` 的 R-type 指令不再写寄存器，按安全 NOP 处理。
- 添加中文注释说明 M 扩展被硬件裁剪。

资源意图：从译码源头避免 M 扩展操作进入 ALU，并减少控制位宽。

### `vsrc/PDU/CPU/your_cpu/pipe_reg.v`

- `alu_op_in/out` 位宽由 5 位改为 4 位。
- `reg_alu_op` 的 `pipe_reg` 实例宽度由 5 改为 4。
- 添加中文注释说明位宽收窄与 RV32M 裁剪关系。

资源意图：减少段间控制寄存器、控制扇出和 MUX 控制位。

### `vsrc/PDU/CPU/your_cpu/cpu.v`

- `alu_op_ID`、`alu_op_EX` 改为 4 位。
- 未使用段间寄存器输入从 `5'b0` 改为 `4'b0`。
- DCache 例化删除 `.REPLACE_POLICY(0)`。
- 添加中文注释说明 DCache 固定为纯 LRU。

资源意图：让 CPU 顶层连接与轻量 ALU/固定 LRU Cache 保持一致。

### `vsrc/PDU/CPU/your_cpu/n_way_cache.v`

- 删除 `REPLACE_POLICY` 参数。
- 保留用户已完成的纯 LRU 状态，删除 FIFO/Random/LFU 相关收口逻辑。
- 补充中文注释说明 `lru_age` 含义、invalid way 优先、LRU 更新行为。

资源意图：去除替换策略选择树和多策略状态寄存器，降低 Cache 控制 LUT。

### `vsrc/PDU/CPU/memory/IMEM.v`

- 为 `mem` 增加 `(* ram_style = "block" *)`。
- 添加中文注释说明目标是引导 Vivado 使用 BRAM。

综合观察：Vivado 报告中 IMEM 仍显示为 512 LUTRAM，说明现有异步读结构未被稳定推入 BRAM。

### `vsrc/PDU/CPU/memory/DMEM.v`

- 为 `mem` 增加 `(* ram_style = "block" *)`。
- 添加中文注释说明目标是缓解 LUT 超额。

综合观察：Vivado 警告 `Trying to implement RAM 'mem_reg' in registers`，DMEM 仍被展开为大量寄存器/逻辑。原因是当前 DMEM 对同一数组存在整行 4 字读写、调试 1 字读写、多个组合派生地址以及复杂事务写入模式，仅添加属性不足以推断 BRAM。

### `AI_assistance/run_lut_opt_synth.tcl`

- 新增 Vivado 非工程综合脚本。
- 读取当前 RTL，综合 `TOP`，输出资源、层次化资源和 timing summary。

输出目录：

- `AI_assistance/vivado_lut_opt_synth/utilization_synth.rpt`
- `AI_assistance/vivado_lut_opt_synth/utilization_synth_hier.rpt`
- `AI_assistance/vivado_lut_opt_synth/timing_synth.rpt`
- `AI_assistance/vivado_lut_opt_synth/post_synth.dcp`

## 3. 验证结果

### 静态检查

命令：

```powershell
Select-String ... 'MUL|DIV|REM|REPLACE_POLICY|fifo_ptr|rand_ptr|lfu_cnt'
```

结果：

- ALU 硬件中不再存在乘法、除法、取余实现。
- Decoder 中只剩中文注释提到 `MUL/DIV/REM`，没有实际操作码映射。
- Cache 中不再存在 `REPLACE_POLICY/fifo_ptr/rand_ptr/lfu_cnt`。

### Icarus Verilog 语法检查

命令：

```powershell
iverilog -g2012 -Wall -I vsrc\include -s TOP -t null ...
```

结果：

- 语法检查通过。
- 仅存在数组敏感列表等 warning，未发现语法错误或位宽连接错误。

### Vivado 综合验证

命令：

```powershell
E:\Xilinx\Vivado\2023.1\bin\vivado.bat -mode batch -source AI_assistance\run_lut_opt_synth.tcl
```

结果：

- `synth_design` 完成，0 error，0 critical warning。
- 综合后资源摘要：

| Resource | 本次综合后 | Available | Utilization |
| --- | ---: | ---: | ---: |
| Slice LUTs | 118261 | 63400 | 186.53% |
| LUT as Logic | 117243 | 63400 | 184.93% |
| LUT as Memory | 1018 | 19000 | 5.36% |
| Slice Registers | 37604 | 126800 | 29.66% |
| Block RAM Tile | 8 | 135 | 5.93% |
| DSP | 0 | 240 | 0.00% |
| Bonded IOB | 4 | 210 | 1.90% |
| BUFG | 2 | 32 | 6.25% |

与用户截图对比：

- LUT：120649 -> 118261，减少 2388，利用率 190.30% -> 186.53%。
- DSP：12 -> 0，说明乘法相关 DSP 已完全释放。
- FF：37607 -> 37604，基本持平。
- BRAM：8 -> 8，未因 CPU IMEM/DMEM 属性上升。

## 4. 关键结论

本次 1-7 项已经按要求完成，乘除法裁剪和 Cache LRU 收口均已落实，Vivado 综合也确认 DSP 从 12 降为 0。

但 LUT 总量仍严重超标，主要原因已经从 ALU/Cache 转移并明确暴露为 CPU 后端 `DMEM`：

- 层次化报告显示 `dmem` 单独占用约 112880 LUT、33210 FF。
- Vivado 明确警告 DMEM 的 `mem_reg` 无法实现为 Block RAM，被展开成寄存器。
- 当前总 LUT 118261 中，绝大多数来自 DMEM，而不是 ALU 或 DCache。

因此，若目标是把 LUT 压到 63400 以下，下一步最有效的优化不是继续微调 ALU，而是重构 `vsrc/PDU/CPU/memory/DMEM.v` 的存储结构：

1. 将 DMEM 改为明确的同步读/写 BRAM 模式。
2. 避免一个周期内对同一 RAM 数组进行 4 个独立写口风格的 line 写。
3. 将 128 位 Cache Line 读写拆为多拍 32 位访问，或把 DMEM 存储宽度改为 128 位 line array。
4. 只复位控制寄存器，不复位整个 RAM 内容。

这一步预计能释放超过十万级 LUT，是后续真正解除 LUT 超额的核心方向。

