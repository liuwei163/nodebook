# 昇腾 NPU 排查命令与面试要点

> 说明：`ascend-dmi: command not found` 以及 `-t network` 报错的根本原因是**工具链组件缺失或版本差异**，而非操作问题。

---

## 一、先解决两个常见报错

### 1. `ascend-dmi` 找不到

- `ascend-dmi` 属于 **ToolBox** 组件，默认不一定随驱动一起安装。
- 可执行文件通常在 `/usr/local/Ascend/toolbox/latest/Ascend-DMI/bin` 下。
- 当前节点大概率没有安装 ToolBox，或没有将该路径加入 PATH。
- **日常排查不需要它**，`npu-smi` 已覆盖 90% 的场景。
- 如需确认：`ls /usr/local/Ascend/toolbox/latest/Ascend-DMI/bin`，存在则用绝对路径执行或加入 PATH；不存在则说明 ToolBox 未安装，跳过即可。

### 2. `-t network` 不存在

- 昇腾不同驱动版本下，`npu-smi` 支持的 `-t` 取值会变化。
- 你机器上 `npu-smi info -h` 的输出就是**最权威的可用列表**。
- 查卡间通信应使用 **`-t hccs`** 或 **`-t topo`**，而不是 `network`。

---

## 二、最常用的 NPU 排查命令

### 第一梯队：日常必用，覆盖 90% 场景

| 命令 | 一句话用途 | 关键判读 |
|---|---|---|
| `npu-smi info` | **全局巡检入口** | HBM-Usage、AICore、Temp/Power 三列优先看 |
| `npu-smi info -t proc-mem -i <卡号>` | **显存被谁占了** | 多租户排查首选；进程列表为空但显存满 → 幽灵占用 |
| `dmesg -T \| grep -i "ascend\|hdc\|aicpu"` | **驱动层"底牌"** | 任务莫名挂掉、HCCL 超时时第一个翻的地方 |
| `npu-smi info -t hccs -i <卡> -c <芯片>` | **HCCS 链路健康** | `link lane list` 有无 `0`、`link speed` 是否一致、`retry/error count` 是否增长 |

### 第二梯队：按需深入

| 命令 | 用途 |
|---|---|
| `npu-smi info -t topo` | 确认 8 卡是否在 HCCS 全互联域内 |
| `npu-smi info -t common -i <卡>` | 查当前频率；`AICore curFreq` 低于标称值 → 降频 |
| `npu-smi info -t health -i <卡>` | 健康状态快速筛查（OK / Warning / Error） |
| `npu-smi info -t board -i <卡>` | 驱动/固件版本一致性检查 |
| `watch -n 1 "npu-smi info"` | 压测时盯功耗/温度曲线；功耗上不去 + AICore 低 → host 瓶颈 |

---

## 三、面试高频问题与回答框架

### ❓ AICore 利用率长期很低，怎么排查？

**先区分"正常波动"和"真瓶颈"**。推理时 AICore 忽高忽低是正常的，算子之间有气泡。**只有长期低于 10% 且业务量不小**，才需要往下查。

排查方向是**先看 host 侧，再看 NPU 本身**：
- 功耗上不去、AICore 也低 → 大概率卡在等数据，用 `msprof` 确认是否 DataLoader / tokenize 拖慢；
- 如果 AICore 频率本身被降了（`npu-smi info -t common` 查 `curFreq`），那是 EDP 降频或散热问题，不是代码能解决的。

### ❓ HCCL 超时怎么定位？

**核心思路：HCCL 超时的根因经常不在 NPU 上**。先看 `dmesg`，网卡驱动 reset 这类问题会伪装成 HCCL 超时。

其次检查几个高频"不一致"点：
- **TLS 配置**——两端 TLS SWITCH 不一致会导致建链握手失败，用 `hccn_tool -i <id> -tls -g` 确认；
- **算子下发**——开 `HCCL_ENTRY_LOG_ENABLE=1`，在各 rank 日志里 `grep "Entry-"` 看是否有 rank 没下发或下发超时；
- **拓扑**——用 `npu-smi info -t topo` 确认不是某两张卡走了 PCIe 而非 HCCS。

单机场景还可以先跑 `hccl_test` 做端到端环测，排除基础通信问题。

### ❓ 显存"幽灵占用"怎么处理？

进程列表里没有对应进程，但 `npu-smi info` 显示显存仍被占着。根因通常是**进程被 OOM killer 杀掉后，驱动侧上下文没清干净**。

步骤：
1. `npu-smi info -t proc-mem -i <卡>` 确认没有真实进程；
2. **重启对应容器**，或执行 `sudo /usr/local/Ascend/driver/tools/upgrade-tool --device_clear_context <卡号>`（路径随驱动版本略有差异）。

**不要一上来就重启整机**，这是昇腾侧需要刻意避免的反射动作。

### ❓ `npu-smi` 和 `nvidia-smi` 在排查思路上最大的区别是什么？

命令形态差异不是重点，**判断直觉的差异才是**：
- GPU 的 `GPU-Util` 低不一定代表卡闲；
- NPU 的 `AICore` **瞬时波动是常态，长期低才值得查，而且第一嫌疑是 host 侧供给**；
- 另外，NPU 侧"幽灵占用"更常见，清理路径是容器/上下文级，而不是整机重启。

把握住这两条，就已经避开了大部分从 GPU 经验"硬套"过来的坑。

---

## 四、一句话排查链路

> **先看资源水位（`npu-smi info`）→ 再定进程归属（`proc-mem`）→ 再翻驱动日志（`dmesg`）→ 最后才上 Profiling（`msprof`）**。

面试时把这条链路讲清楚，比罗列命令更能体现排查能力。`ascend-dmi` 在当前环境不可用，跳过它完全不影响日常排查和面试准备的完整性。
