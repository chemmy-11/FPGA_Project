---
alias: 复现_prj9_指南
type: 操作文档
摘要: prj9 复现指南——以太网 ↔ Aurora 光回环（无内存）的数据完好性复现。一键演示 `storm_demo.ps1 [quick|full]`；手动口径 `json_storm.py`（质量档 1ms 间隔 / 吞吐档 pace 13µs）。含烧录、体检、判读、预期输出与历史实测数字。
created: 2026-10-09
updated: 2026-10-09
---

# prj9 复现指南

> **prj9 是什么**：以太网 ↔ Aurora 10G 光回环的数据面（**没有内存**，纯流式直通）。
> **复现目标**：数据完好穿越光链路往返 —— 零丢失、零损坏、零乱序、SHA256 全量一致。

---

## 一、复现工具一览

| 工具 | 位置 | 作用 |
|---|---|---|
| `storm_demo.ps1` | `scripts/` | **一键演示（首选入口）**：自动体检 + 传输 + 判读 |
| `json_storm.py` | `scripts/` | **主力测量器**：把 JSONL 切片打过光链路，回显重组比对（质量档/吞吐档） |
| `json_reliable.py` | `scripts/` | 可靠传输版（面向易丢包场景的重传口径） |
| `udp_verify.py` | `scripts/` | 基础 UDP 回环验证（最轻量，冒烟用） |
| `program_board.tcl` | `scripts/` | **一键烧录 + 体检**（位流 + 探针同批指定） |
| `verdict_capture.ps1` | `scripts/` | 判决捕获（ILA/Vivado 侧取证） |
| `build_debug.tcl` | `scripts/` | 位流构建（含 2 个 ILA 调试核） |

**测试负载**：`testdata\session_full.jsonl`（10,293,111 B，会话 JSON 全量）；
另有 `session_reliable.jsonl` / `session_roundtrip.jsonl`。

---

## 二、执行命令（可直接复制）

### 第 0 步：烧录 + 体检

~~~powershell
cd D:\FPGA\prj\project_9
vivado -mode batch -source scripts\program_board.tcl -notrace
~~~

判据（三条，脚本自动打印）：
- `PROGRAM_OK`
- **调试核数量 = 2**（说明跑的是 project_9 的设计，不是别的工程）
- `user_clk`（GT/MMCM，与网线无关）在跑 · `eth_rxc`（PHY 的 125M RX 时钟）在跑 ⇒ **等价于 PHY 链路已建立**

### 第 1 步：一键演示（**推荐**）

~~~powershell
cd D:\FPGA\prj\project_9
powershell -ExecutionPolicy Bypass -File scripts\storm_demo.ps1 quick   # 100KB 校准，秒级
powershell -ExecutionPolicy Bypass -File scripts\storm_demo.ps1 full    # 10MB 全量，约 40s
~~~

脚本内部三步：`[0/3]` ping 体检 → `[1/3]` 传输 → `[2/3]` 判读（PASS = 零丢 + 零损坏 + SHA256 一致）。

> ⚠️ 该脚本**硬编码了 Python 路径** `C:\Users\15266\AppData\Local\Python\pythoncore-3.14-64\python.exe`；
> 换机器请改 `$py` 那一行，或改用下面的手动命令。

### 第 2 步：手动口径（想自己控制参数时）

~~~powershell
cd D:\FPGA\prj\project_9
$env:PYTHONUTF8 = 1

# ① 质量档：100KB 校准（秒级，期望 100% + SHA 一致）
python scripts\json_storm.py testdata\session_full.jsonl --limit-bytes 102400 `
       --chunk 1360 --gap-ms 1.0 --out testdata\calib_out.bin

# ② 质量档：10MB 全量（约 40s，J4 完整性判据就是这个口径）
python scripts\json_storm.py testdata\session_full.jsonl `
       --chunk 1466 --gap-ms 1.0 --out testdata\session_roundtrip.jsonl

# ③ 吞吐档：忙等节奏器 13µs/帧（冲击链路能力，看丢帧落点）
python scripts\json_storm.py testdata\session_full.jsonl `
       --chunk 1466 --pace-us 13 --out out\storm.jsonl

# ④ 离线自检（不建 socket，先验节奏器本身）
python scripts\json_storm.py --pacer-selfcheck 5000
python scripts\json_storm.py --syscall-selfcheck 5000
~~~

### 第 3 步（可选）：基础 UDP 冒烟

~~~powershell
python scripts\udp_verify.py
~~~

---

## 三、关键参数（`json_storm.py`）

| 参数 | 默认 | 说明 |
|---|---|---|
| `--chunk` | 1466 | 单帧净载荷字节。**>1466 会 IP 分片 → 板端全丢** |
| `--gap-ms` | - | 帧间隔 ms（`sleep` 实现，精度约 0.5ms） |
| `--pace-us` | 0 | **忙等节奏器**：每帧目标周期 µs；给了它就忽略 `--gap-ms` |
| `--sndbuf-mb` | - | 发送 socket `SO_SNDBUF`（MB） |
| `--parallel` | 1 | 并行进程数（各持独立端口，真并行绕开 GIL） |
| `--limit-bytes` | - | 只发前 N 字节（校准用） |
| `--out` | - | 重组输出路径 |
| `--pacer-selfcheck N` | - | **离线**自检：不建 socket，跑 N 帧同构循环验节奏器 |
| `--syscall-selfcheck N` | - | **离线**自检：向 127.0.0.1 实发 N 帧，测 `sendto` 单帧成本下界 |

---

## 四、判读与预期输出

**PASS 的四个条件**（脚本会打印 `JSON_STORM_SUMMARY` 一行 JSON，便于机器判读）：

~~~json
{"file_bytes":10293111,"chunks":7022,"chunk_size":1466,"gap_ms":1.0,
 "pace_us":0.0,"recv":7022,"lost":0,"corrupt":0,"inversions":0,"sha_match":true}
~~~

| 字段 | 合格值 |
|---|---|
| `recv` / `chunks` | 相等（100%） |
| `lost` | **0** |
| `corrupt` | **0** |
| `inversions` | **0**（到达流零乱序） |
| `sha_match` | **true** |

**历史实测（参考）**：质量档 10MB → `7022/7022`、SHA256 一致、RTT 平均 0.35ms；
吞吐档 `--pace-us 13` → 发送阶段 **51.76 MB/s（414 Mbps）**，**超链路能力会丢**（曾测到仅 51.44% 到达）。

> 丢帧定性时看**位置**：prj9 已知有约 0.4% 的相邻对丢失，**位置在 Aurora 渡纤段**；损坏/乱序应恒为 0。

---

## 五、失败时的第一步

| 现象 | 先查 |
|---|---|
| ping 100% 丢包 | 位流是否掉了（**JTAG 烧录易失**，断电即失）→ 重跑第 0 步；再看 T23 灯 |
| 调试核数量 ≠ 2 | 烧的不是 project_9 的位流 |
| `--chunk > 1466` | IP 分片，板端全丢 —— 这是**设计约束**，不是 bug |

---

*命令均取自脚本头部注释与真实 `--help` 输出。*