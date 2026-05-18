# DMEM 重构执行总结

## 1. 本次实际完成的工作

本次按照 `AI_assistance/DMEM_Refactor_Plan.md` 对 CPU 后端数据存储器 `DMEM.v` 做了架构级重构，重点目标是同时满足仿真可用性、Cache Line 事务需求和 FPGA 资源约束。

已完成事项：

1. 保持 `DMEM` 外部接口不变，继续兼容 `MEM_ARBITER`、DCache 和 CPU_ctrl/PDU 调试路径。
2. 将旧版“一周期内并行访问 4 个 32 位 word”的 DMEM 实现，重构为单端口同步 RAM + 事务微序列器。
3. 保留完整的数据内存阵列：
   - `(* ram_style = "block" *) reg [31:0] mem [0:(1 << DEPTH)-1];`
   - 使用 `$readmemh(\`CPU_DMEM_FILE, mem)` 完整加载原 32 位 word 粒度初始化文件。
4. 对 128 位 Cache Line 读写进行 4 拍拆分：
   - line 写：依次写入 4 个连续 word。
   - line 读：依次读取 4 个连续 word，并按低地址到高地址拼入 `line_rdata`。
5. 对 32 位调试读写保持单 word 事务：
   - 调试写只写目标 word。
   - 调试读只返回目标 word，并同步填入 `line_rdata[31:0]` 便于观察。
6. 保留 `MEM_DELAY` 延迟模型和 `req/ready` 握手语义：
   - 请求只在 `STATE_IDLE` 采样一次。
   - `ready` 仍为单 `clk` 周期完成脉冲。
7. 添加中文注释，解释存储阵列、BRAM 推断策略、Cache Line 微序列、读写时序和输出整理逻辑。

## 2. 修改清单与 diff 简述

### `vsrc/PDU/CPU/memory/DMEM.v`

- 重写 DMEM 内部 FSM：
  - 新增 `STATE_IDLE / STATE_DELAY / STATE_LINE_WRITE / STATE_READ_WAIT / STATE_READ_CAP / STATE_DONE`。
  - `STATE_DELAY` 负责模拟主存延迟。
  - `STATE_LINE_WRITE` 将 128 位 line 写拆成 4 次 32 位写。
  - `STATE_READ_WAIT / STATE_READ_CAP` 将同步 BRAM 读拆成地址发起和数据采样。
  - `STATE_DONE` 统一返回读数据并产生 `ready`。
- 新增独立 RAM 端口寄存器：
  - `ram_addr`
  - `ram_din`
  - `ram_we`
  - `ram_dout`
- 将控制 FSM 与 RAM 访问模板分离，避免直接组合读取 `mem` 数组。
- 保留完整 32 位数据内存阵列和 `$readmemh` 初始化。
- 对 `line_mode=1` 的地址强制按 4-word Cache Line 对齐。
- 用中文注释补充说明：
  - 为什么要避免一周期 4 地址访问。
  - 低地址 word 如何映射到 `line_rdata[31:0]`。
  - 32 位调试访问和 128 位 Cache 访问如何共享同一 BRAM 阵列。

### `AI_assistance/DMEM_Refactor_Plan.md`

- 新增 DMEM 重构方案文档。
- 记录 CPU/DCache/DMEM/CPU_ctrl 的接口需求。
- 记录最终采用的“32 位 BRAM + 4 拍 Cache Line 微序列器”方案。
- 说明读写掩码分层：
  - CPU 的 SB/SH/SW 字节级合并由 `data_mem_ctrl.v` 与 `n_way_cache.v` 完成。
  - DMEM 接收完整 line 或 32 位调试 word，并负责 word 级选通。

### `AI_assistance/tb_dmem.v`

- 新增轻量级 DMEM 单元仿真。
- 覆盖：
  - 128 位整行写。
  - 128 位整行读。
  - 32 位 word 局部写。
  - 局部写后整行读，确认同一 Cache Line 内其他 word 不被破坏。
  - 32 位 word 读。

### `AI_assistance/vivado_lut_opt_synth/`

- 复用已有 Vivado batch 综合脚本输出最终综合报告。
- 主要报告文件：
  - `utilization_synth.rpt`
  - `utilization_synth_hier.rpt`
  - `timing_synth.rpt`
  - `post_synth.dcp`

## 3. 验证结果

### Icarus Verilog 顶层编译

命令：

```powershell
$files = Get-ChildItem -Path vsrc -Recurse -Filter *.v | ForEach-Object { $_.FullName }
iverilog -g2012 -Wall -I vsrc\include -s TOP -t null $files
```

结果：

- 通过，退出码 0。
- 剩余 warning 为既有数组敏感列表提示，来自 `CPU_ctrl.v` 和 `n_way_cache.v`，不是本次 DMEM 重构引入的语法错误。

### DMEM 单元仿真

命令：

```powershell
iverilog -g2012 -Wall -I vsrc\include -s tb_dmem -o AI_assistance\tb_dmem.vvp AI_assistance\tb_dmem.v vsrc\PDU\CPU\memory\DMEM.v
vvp AI_assistance\tb_dmem.vvp
```

结果：

- 输出 `DMEM_TEST_PASS`。
- `DEPTH=6` 的测试实例读取完整 `data.ini` 时会提示初始化文件 word 数多于测试 RAM 深度，这是测试裁剪深度导致的 warning，不影响功能判定。

### Vivado 综合

命令：

```powershell
E:\Xilinx\Vivado\2023.1\bin\vivado.bat -mode batch -source AI_assistance\run_lut_opt_synth.tcl
```

结果：

- `synth_design` 通过，0 error，0 critical warning。
- 最终总资源摘要：

| Resource | Used | Available | Utilization |
| --- | ---: | ---: | ---: |
| Slice LUTs | 5254 | 63400 | 8.29% |
| LUT as Logic | 4236 | 63400 | 6.68% |
| LUT as Memory | 1018 | 19000 | 5.36% |
| Slice Registers | 4873 | 126800 | 3.84% |
| Block RAM Tile | 9 | 135 | 6.67% |
| DSPs | 0 | 240 | 0.00% |

层次化 DMEM 资源：

| Instance | LUTs | FFs | RAMB36 | RAMB18 | DSP |
| --- | ---: | ---: | ---: | ---: | ---: |
| `dmem` | 271 | 477 | 1 | 0 | 0 |

Vivado RAM 映射报告确认：

- `dmem/mem_reg` 映射为 `1 K x 32 (READ_FIRST)`。
- 使用 `1` 个 `RAMB36`。
- 不再映射为分布式 RAM，也不再出现旧版 DMEM 的超大 LUT/FF 展开。

## 4. 关键结论

本次 DMEM 重构已经完成并通过语法、单元行为和 Vivado 综合验证。新的 DMEM 保留完整数据内存阵列和初始化逻辑，支持 DCache 的 128 位 Cache Line 事务，也支持 CPU_ctrl/PDU 的 32 位调试访问。

最重要的资源结果是：CPU 后端 `dmem` 已从此前约十万级 LUT 风险收敛到 `271 LUT + 1 RAMB36`，解决了前一轮综合中 DMEM 导致 LUT 严重超额的核心问题。
