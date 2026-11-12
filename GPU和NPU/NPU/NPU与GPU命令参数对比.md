# NPU（昇腾）与 GPU（NVIDIA）命令参数对比

本文把两侧命令按「参数含义、取值、实际用法」逐条拆开。NPU 侧重点在 `npu-smi` 的 `-t` / `-i` / `-c` 三层参数体系，GPU 侧重点在 `pmon` / `dmon` / `--query-gpu` 的字段与过滤参数。每部分末尾附一个快速对照，最后集中对比命令层面的设计差异。

---

## 第一部分：NPU（昇腾）命令参数拆解

### 1. `npu-smi` 的参数体系：`-t` 决定“查什么”，`-i` 决定“查哪张卡”，`-c` 决定“查哪个芯片”

`npu-smi` 的通用形态是：

```text
npu-smi <主命令> [-t <类型>] [-i <卡号>] [-c <芯片号>]
```

三层参数各司其职，**不区分这三层，是 `npu-smi` 用起来最别扭的地方**。

#### `-t`（type）：指定查询的信息类型

这是 `npu-smi` 最核心的参数，决定“你要看哪一类信息”。常用取值：

| `-t` 取值 | 含义 | 典型场景 |
|---|---|---|
| `proc-mem` | 按进程列出显存（HBM）占用 | 显存被谁占了 |
| `health` | 整体健康状态 | 卡是否“正常” |
| `ecc` | ECC 错误计数 | HBM 硬件可靠性 |
| `temp` | 温度 | 散热排查 |
| `power` | 功耗 | 判断是否满载 |
| `usages` | 利用率（AICore 等） | 算力是否在用 |
| `memory` | HBM 读写带宽 | 判断是否 Memory-Bound |
| `network\hccs` | HCCS 链路状态 | 多卡通信排查 |
| `board` | 板卡 / 固件 / 驱动版本 | 版本一致性检查 |

**注意**：不同驱动/CANN 版本下 `-t` 支持的取值可能有差异。**以机器上 `npu-smi info -h` 的实际输出为准**，这是最稳妥的确认方式。

#### `-i`（id）：指定 NPU 卡的逻辑 ID

`-i 0` 表示第 0 张卡，`-i 0,1` 表示同时查第 0、1 张卡。不指定 `-i` 时，多数子命令默认作用于全部卡或给出全局视图，具体行为取决于子命令。在多卡节点上，**先 `npu-smi info` 看全局，再用 `-i` 锁定单卡**，是最不容易误判的顺序。

#### `-c`（chip）：指定卡内的芯片 ID

昇腾部分型号一张卡上有多颗芯片（die）。`-c 0` 表示该卡的第 0 颗芯片。对于单芯片卡，`-c 0` 通常是默认值，写不写效果一样；对于多芯片卡，**不加 `-c` 可能默认只显示部分芯片，或需要显式指定才能拿到目标 die 的数据**。这是 `npu-smi` 与 `nvidia-smi` 在参数设计上最显著的差异之一——GPU 侧没有对应的“卡内芯片”层级。

**组合示例**：

```text
npu-smi info -t proc-mem -i 0          # 0 号卡上各进程的显存占用
npu-smi info -t usages   -i 0 -c 0     # 0 号卡第 0 颗芯片的利用率
npu-smi info -t network  -i 0          # 0 号卡的 HCCS 链路状态
```

`npu-smi info` 不带任何参数时，输出的是**默认概览**：上半部分设备级汇总，下半部分进程表。这是最常用的“一眼看全局”命令，但字段粒度粗，深入排查必须加 `-t`。

### 2. `ascend-dmi`：硬件诊断与压测的参数（需要部署toolBox组件）

`ascend-dmi` 的主入口是 `--dg` / `--diagnosis`（故障诊断），参数围绕“**诊断哪些项、对哪些设备、输出什么格式、是否加压**”展开。

#### `-i` / `--items`：指定诊断项

`-i` 后面跟一个或多个诊断项，多项用逗号分隔。可选取值包括：

`driver`、`cann`、`device`、`network`、`bandwidth`、`aiflops`、`hbm`、`signalQuality`、`aicore`、`aicpu`、`prbs`、`tdp`、`edp`、`nic`、`random`。

**默认行为**：不传 `-i` 时，执行除 `aicore`、`prbs`、`aicpu`、`edp`、`tdp`、`nic`、`random` 之外的全部检查项。也就是说，默认跑的是“安全项”，加压类和高风险项需要显式指定。

**互斥规则**：`aicore`、`prbs`、`edp`、`tdp`、`aicpu`、`random` **不能与其他项同时使用**；`hbm` 与 `chipMemory` 也不能同时指定。

#### `-d` / `--device`：指定诊断的设备

`-d 0` 只诊断 0 号设备，`-d 0,1,2,3` 诊断多张卡。**不指定时默认检查全部设备**。但注意：`cann` 和 `driver` 诊断项**不受 `-d` 约束**，它们本身就是整机级检查；当诊断项包含 `signalQuality` 或 `p2p` 压测时，指定的设备数少于 2 张，对应的 HCCS 信号质量或 P2P 压测会被跳过。

#### `-r` / `--result`：诊断结果保存路径

指定一个**绝对路径**作为结果保存位置，工具会在该路径下创建 `ascend_check` 文件夹。不指定时，root 用户默认保存到 `/var/log/ascend_check`，非 root 用户保存到 `$HOME/var/log/ascend_check`。路径**不支持通配符**，且需要符合安全要求。

#### `-fmt` / `--format`：输出格式

可选 `normal` 或 `json`，默认 `normal`。指定 `json` 时，故障诊断结果会额外写入 `ascend_check/environment_check_before.txt`；不指定 `json` 时，诊断结果**不会自动保存到文件**，只回显到终端。这是一个容易忽略的点：**想留档，就要显式加 `-fmt json` 或配合 `-r`**。

#### `-s` / `--stress` 与 `--st`：加压与加压时长

`-s` 触发压测，可配合 `hbm`、`aicore`、`p2p`、`edp`/`tdp` 等加压项使用。`--st`（`--stress-time`）指定压测时长，**必须先指定 `-s` 才能生效**，取值范围 60–604800 秒。单机 8 卡环境做稳定性验证时，`-s` 配合适度 `--st` 比跑满默认诊断更有实际意义。

**典型组合**：

```text
ascend-dmi --dg -i device,hbm -d 0,1 -fmt json -r /tmp/diag
ascend-dmi --dg -i aicore -s --st 600
```

### 3. `msprof`：Profiling 的参数逻辑

`msprof` 的参数分为两大类：**采集谁** 和 **采什么**。

#### `--output` 与 `--application`：采集入口

通用格式是：

```text
msprof --output=<输出目录> --application="<启动命令>"
```

`--output` 指定结果存放目录；`--application` 指定被采集的进程启动命令，例如 `"python3 train.py"` 或 `"./run.sh"`。**两者同时出现时，采集的是“这个应用运行期间的数据”**；只指定 `--output` 而不指定 `--application`，则进入“仅采集昇腾 AI 处理器系统数据”的模式，此时 `--sys-period`、`--sys-devices` 等参数才成为必选。

#### 常用采集开关

以下开关的取值统一为 `on` / `off`，默认大多为 `off`，需要显式开启：

| 参数 | 采集内容 | 典型用途 |
|---|---|---|
| `--runtime-api` | Runtime API 耗时（Host↔Device 拷贝等） | 判断数据搬运是否拖慢整体 |
| `--task-time` | 算子下发耗时 + 执行耗时 | 定位算子级瓶颈 |
| `--ai-core` | AICore 数据 | 配合 `--task-time` 使用 |
| `--aicpu` | AICPU 算子耗时、拷贝耗时 | 排查 AICPU 侧异常 |
| `--hccl` | HCCL 通信数据 | 多卡场景通信排查 |
| `--sys-hardware-mem` | 片上内存读写速率 | 判断 Memory-Bound |

`--runtime-api` 采集的是 Host 与 Device 之间、Device 之间的同步/异步内存拷贝时延，结果会出现在 `msprof_*.json` 的 `CANN_Runtime` 层级和 `api_statistic_*.csv` 中。`--task-time` 控制算子下发与执行耗时的采集，`--task-time` 为 `on`/`l1` 时 `--ai-core` 默认跟随开启，为 `off`/`l0` 时默认关闭。

#### 频率与采样参数

`--sys-io-sampling-freq` 控制 NIC/ROCE 采集频率，范围 1–100，默认 100 Hz，且**需要先开启 `--sys-io-profiling` 才生效**。类似地，`--sys-pid-sampling-freq`（进程 CPU/内存采样频率）需要先开启 `--sys-pid-profiling`。这类“采样频率依附于采集开关”的设计在 `msprof` 中很常见，**单独调频率而不开开关是无效的**。

---

## 第二部分：GPU（NVIDIA / RTX 4060）命令参数拆解

### 1. `nvidia-smi pmon`：进程级监控的参数

`pmon` 的定位是“**按进程看谁在用卡**”，常用参数如下：

| 参数 | 含义 | 取值 / 说明 |
|---|---|---|
| `-i` | 指定 GPU 设备列表 | `-i 0` 或 `-i 0,1`，逗号分隔，**最多选取 4 个设备** |
| `-s` | 指定要显示的指标组 | `u` = 利用率（SM/Mem/Enc/Dec）；`m` = Frame Buffer 占用（MB） |
| `-c` | 指定采样次数后退出 | `-c 10` 显示 10 个样本后结束 |
| `-d` | 指定刷新间隔（秒） | 范围 **1–10 秒**，不指定时默认 1 秒 |
| `-o` | 附加日期或时间戳 | `D` = `YYYYMMDD`；`T` = `HH:MM:SS` |

`pmon -s u` 报告的是**自上一个监控周期以来的平均利用率**（SM、Memory、Encoder、Decoder 的百分比），而 `-s m` 报告的是**瞬时** Frame Buffer 占用。两者的语义不同：`u` 适合看“这段时间进程在算吗”，`m` 适合看“此刻占了多少显存”。

一个实用组合：

```bash
nvidia-smi pmon -s um -d 1 -o T
```

同时显示利用率和显存，每秒刷新，带时间戳，适合定位“显存突然涨了但利用率没涨”的时刻。

### 2. `nvidia-smi dmon`：设备级滚动监控的参数

`dmon` 按**设备**滚动输出，常用参数：

| 参数 | 含义 | 取值 |
|---|---|---|
| `-s` | 指标组 | 常用 `pucvmet`：p=功耗，u=利用率，c=时钟，v=violation，m=显存，e=ECC，t=温度 |
| `-d` | 刷新间隔 | 秒 |
| `-o` | 时间格式 | `D` 或 `T` |

`dmon` 的输出是**逐设备一行**，适合看整卡的趋势；`pmon` 是**逐进程一行**，适合定位归属。**判断“卡忙不忙”用 `dmon`，判断“谁在忙”用 `pmon`**，这是两个命令的核心分工。

### 3. `nvidia-smi --query-gpu`：结构化查询的参数

`--query-gpu=` 后面跟**逗号分隔的字段名**，`--format=csv` 指定输出格式。常用字段包括：

`index`、`name`、`utilization.gpu`、`utilization.memory`、`memory.used`、`memory.total`、`temperature.gpu`、`power.draw`、`power.limit`、`clocks.current.sm`。

`--format` 的取值有 `csv`、`noheader`、`nounits` 等，可以组合，例如 `--format=csv,noheader,nounits` 适合脚本直接取值。`-i` 同样可以限定设备，`-l` 指定刷新间隔（秒），`-f` 将输出写入文件。

**注意**：可用字段列表随驱动版本变化，**`nvidia-smi --help-query-gpu` 是确认当前机器支持哪些字段的权威方式**，比凭记忆写字段更可靠。

### 4. `dcgmi diag -r`：诊断级别参数

`-r` / `--run` 后面的数字表示**诊断级别**，级别越高，覆盖的检查项越多、耗时越长、对 GPU 的占用也越大。低级别做快速筛查，高级别做深度硬件验证。在共享节点上运行高级别诊断前，应先排空作业，避免诊断与业务互相干扰。RTX 4060 属于消费级卡，DCGM 的完整诊断能力主要面向数据中心 GPU，**在 4060 上部分检查项可能不可用**，以实际 `dcgmi diag -r <level>` 的输出为准。

### 5. `torch.profiler`：参数集中在“采什么”和“怎么采”

核心参数：

| 参数 | 含义 | 取值 / 默认 |
|---|---|---|
| `activities` | 采集哪些活动组 | `[ProfilerActivity.CPU]`、`[ProfilerActivity.CUDA]`，可组合 |
| `schedule` | 采集节奏 | `torch.profiler.schedule(wait, warmup, active, repeat)` |
| `record_shapes` | 记录算子输入张量的 shape | `bool`，默认 `False` |
| `profile_memory` | 追踪张量内存分配/释放 | `bool`，默认 `False` |
| `with_stack` | 记录调用栈 | `bool` |

`activities` 决定采集 CPU 侧还是 GPU 侧，**只采 CPU 或只采 GPU 都会缺失另一半的因果链**，通常两边都开。`schedule` 中的 `wait` 是预热前等待的 step 数，`warmup` 是预热步数，`active` 是实际采集步数，`repeat` 是重复轮数；**不做 warmup 直接采，前几步的初始化开销会污染结果**。`record_shapes=True` 会短暂持有张量引用，可能增加显存占用，**在显存紧张时谨慎开启**。

---

## 第三部分：命令层面的核心差异对比

| 维度 | NPU（昇腾） | GPU（NVIDIA） |
|---|---|---|
| **设备寻址层级** | `-i` 卡号 + `-c` **芯片号**，两级寻址 | `-i` 卡号，一级寻址；无“卡内芯片”概念 |
| **查询类型的选择方式** | `-t <type>` 显式切换，**不同类型走不同子命令** | `pmon` / `dmon` / `--query-gpu` 按场景切换，字段通过 `--query-gpu=` 组合 |
| **进程级指标语义** | `proc-mem` 给的是**占用快照**，通常不带“自上次周期以来的平均利用率” | `pmon -s u` 给的是**周期平均利用率**，`-s m` 给的是瞬时 Frame Buffer |
| **采样频率的依附关系** | `msprof` 中频率参数**依附于采集开关**，不开开关频率无效 | `pmon` / `dmon` 的 `-d` 直接控制刷新间隔，无额外依附 |
| **输出留档方式** | `ascend-dmi` 默认**不自动保存**诊断结果，需 `-fmt json` 或 `-r` | `nvidia-smi` 可用 `-f` 直接写文件；`--query-gpu` + `--format` 适合管道化 |
| **加压/诊断的显式性** | `ascend-dmi` 的压力项（`aicore`、`prbs` 等）**默认不执行**，需显式 `-i` + `-s` | `dcgmi diag -r` 的级别隐含了检查范围，但消费级卡支持度受限 |
| **Profiling 参数组织** | 大量 `--xxx=on/off` 开关，**粒度细、需要显式开启** | `torch.profiler` 以 `activities` + `schedule` + 布尔开关组织，**参数数量少但语义集中** |

**一句话收束参数层面**：NPU 侧的命令参数更“**分层、显式、依附关系多**”——不指定 `-t` 看到的信息粒度粗，不指定 `-c` 可能漏 die，不开采集开关频率参数无效，不显式 `-fmt json` 诊断结果不落盘。GPU 侧的命令参数更“**按场景分工具、字段可组合**”——`pmon` 管进程、`dmon` 管设备、`--query-gpu` 管结构化输出。用 GPU 的“一条命令查全部”直觉去用 `npu-smi`，最容易在 `-t` / `-c` / 结果留档这三个地方踩空。
