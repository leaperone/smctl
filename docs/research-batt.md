# batt 架构技术笔记（charlie0129/batt）

> 调研日期：2026-06-04。仅梳理机制与设计决策，**不含 GPL 代码片段**（batt 为 GPL-2.0，只参考思路）。所有 SMC key 名、事件名、状态条件来自对源码的阅读归纳。
>
> 仓库布局：`cmd/batt`（CLI 各子命令）、`pkg/daemon`（守护进程主体）、`pkg/smc`（SMC 读写）、`pkg/client`（CLI→daemon HTTP 客户端）、`pkg/config`、`pkg/utils/daemon`（安装/卸载）、`hack/`（plist 模板与脚本）。Go 约 89%，少量 Obj-C/C 做 IOKit/SMC 桥接。

## 1. daemon ↔ CLI 通信

- **传输层**：Docker 式 client-server。daemon 监听一个 **Unix domain socket**，CLI/GUI 作客户端连接。上层跑 **HTTP**（gin，release 模式），即「HTTP over Unix socket」——关键设计：复用成熟 HTTP 语义（method + path + JSON body），调试可直接用 `curl --unix-socket`。
- **权限模型（防越权的核心）**：daemon 以 root 跑（写 SMC 需要），**访问控制完全靠 socket 文件权限位**，内核 enforce，代码里没有再做 caller uid 校验：
  - 默认：socket `0700`（仅 owner=root 可连）→ 非 root 用户连不上，自然无法改充电策略。
  - `install --allow-non-root-access`：把 socket chmod 成 `0777`，任何用户可连可改。安全降级开关，等于放弃权限隔离。
  - 评价：把鉴权下放给文件权限位很省事，但粒度只有「全开/全关」，没有「只读 vs 读写」分级，也无逐操作授权。
- **API 面（约 26 个端点，gin 路由）**：
  - 配置/策略（GET 读 / POST 写）：`/config`、`/limit`、`/lower-limit-delta`、`/prevent-idle-sleep`、`/disable-charging-pre-sleep`、`/prevent-system-sleep`、`/adapter`、`/control-magsafe-led`
  - 状态只读：`/charging`、`/current-charge`、`/plugged-in`、`/charging-control-capable`（机型能力探测）、`/battery-info`、`/version`
  - 遥测/事件：`/telemetry`、`/events`（**SSE 推送 daemon 状态变化，供 GUI 用**）
  - 校准：`/calibration/{start,pause,resume,cancel}`、`/calibration/discharge-threshold`、`/calibration/hold-duration`
  - 调度：`/schedule`（cron 表达式）、`/schedule/{skip,postpone}`

## 2. 睡眠/唤醒钩子

- **注册机制**：C 桥接（`pkg/daemon/hook.c` + `sleepcallback.go`）调用 IOKit `IORegisterForSystemPower`，监听 4 个事件：
  - `kIOMessageCanSystemSleep`（idle sleep 询问，可否决）
  - `kIOMessageSystemWillSleep`（即将真睡，不可否决，只能确认）
  - `kIOMessageSystemWillPowerOn`（开始唤醒）
  - `kIOMessageSystemHasPoweredOn`（唤醒完成）
- **睡前动作（`WillSleep`）**：若 limit < 100%，**主动写 SMC 禁充**（`disable-charging-pre-sleep`，默认开），可选关 MagSafe LED；然后必须 `IOAllowPowerChange` 放行，否则会阻塞系统睡眠。
- **idle sleep 否决（`CanSystemSleep`）**：若开了 `prevent-idle-sleep` 且当前在维持充电中（或刚唤醒），调用 `CancelPowerChange` 否决 idle 睡眠——让充电会话不被打断。注意**只挡 idle，不挡手动/合盖强制睡眠**。
- **唤醒后动作**：记录唤醒时间戳，调 `scheduler.HandleWakeUp()`；若启用限充，要么立刻强制跑一次 maintain loop，要么把下一次 maintain 延后约 30s。唤醒后约 60s 内延迟接受 idle sleep，给 maintain loop 留执行窗口；README 提到唤醒后最多临时禁充约 2 分钟。
- **「睡眠中继续充电」问题怎么解的**（核心痛点，issue #14）：
  - 根因：睡眠时 maintain loop 不跑，SMC 充电状态保持睡前的「允许充电」，于是越睡越满（用户反馈设 60% 却充到 77%）。
  - 三层方案（互有取舍）：
    1. `disable-charging-pre-sleep`（默认开）——睡前直接写禁充 key，从源头堵住。
    2. `prevent-idle-sleep`（默认开）——充电会话期间不让 idle 睡。
    3. `prevent-system-sleep`（实验性）——充电时建电源 assertion 连手动睡也挡住，与前两者互斥。
  - **额外护栏（掉拍检测）**：maintain loop 用时间序列记录器检测「掉拍」（两次迭代间隔远超 10s ⇒ 期间睡过/被挂起）。一旦发现掉拍且当前在充电，**立即禁充**，防止睡眠期偷充。
- **已知缺陷/边界**：issue #33 DarkWake（定时唤醒、Power Nap）下电源状态判断异常；强制睡眠/合盖（clamshell）场景 `prevent-idle-sleep` 无效；`prevent-system-sleep` 与 clamshell 冲突（clamshell 下切断 adapter 会直接让 Mac 睡）。issue #34：macOS Tahoe 26 早期不支持（key 漂移）。

## 3. 充电策略状态机

- **主循环**：每 **10 秒**跑一次 maintain loop。
- **区间定义**：upper limit（`limit`，10–99 触发限充，100 = 关闭限充）；lower limit = upper − `lower-limit-delta`（默认 delta 2%）。两者之间是「维持区/sailing 区」。
- **状态转换**：
  - 电量 < lower limit 且未充电 → 开充（但若刚检测到掉拍/刚唤醒，先等 loop 稳定，避免睡眠期误开）。
  - 电量 ≥ upper limit 且在充电 → 立即停充。
  - 在 [lower, upper] 维持区内 → **保持当前状态不动**（dead-band hysteresis 迟滞死区），靠这个防止阈值附近反复开关充电抖动。
  - limit = 100（限充关闭）→ 永远允许充电，MagSafe LED 交还系统控制。
- **防抖**：核心就是双阈值死区 + 10s 周期，无额外去抖计时器。
- **主动放电**：通过禁用 adapter（切断墙电）实现，让系统吃电池；CLI-only，主要用于校准（calibration）流程，不在常规 maintain 自动触发。
- **强制路径**：HTTP API 改配置时走 forced maintain loop，跳过睡眠延迟等待，立即生效。

## 4. SMC 写入细节

- **key 映射（arm64，`consts_arm64.go`）**：
  - 充电控制：`CH0B`、`CH0C`、`CHTE`（**Tahoe 固件新增**）
  - adapter（墙电开关）：`CH0I`、`CH0J`、`CHIE`（Tahoe）
  - MagSafe LED：`ACLC`；AC 在位检测：`AC-W`；电量：`BUIC`
  - 遥测：DC-in 电流/电压/功率 `ID0R`/`VD0R`/`PDTR`，电池电流/电压/功率 `B0AC`/`B0AV`/`PPBR`
- **写入值语义**：
  - 充电 pre-Tahoe（CH0B+CH0C 两 key 同写）：enable 写 `0x0`，disable 写 `0x2`
  - 充电 Tahoe（CHTE，4 字节）：enable 写 `00 00 00 00`，disable 写 `01 00 00 00`
  - adapter：enable 写 `0x0`；disable 在 CH0I/CH0J 写 `0x1`，在 CHIE 写 `0x8`
- **读状态**：读 CH0B（pre-Tahoe，单字节）或 CHTE（Tahoe，4 字节），全 0 即「充电允许中」。adapter：单字节 `0x0` 即 enabled。
- **机型/版本兼容**：启动时探测 capabilities map，决定用哪组 key（pre-Tahoe vs Tahoe；哪个 adapter key 受支持），按序探测可用项。Intel（`consts_amd64.go`）另有一套：`CH0B`/`CH0C` 充电、adapter 为 `CH0K`、电量 `BBIF`；但 batt 明确「不打算支持经典 Intel MacBook」，多数 Intel key 未验证。
- **写失败处理**：SMC 读写错误直接向上 return，**无重试、无 fallback**。鲁棒性短板——单次写失败可能让充电状态卡在错误值。

## 5. daemon 生命周期

- **安装**：
  - 二进制 chmod `0755`；plist 模板做路径替换；写 `/Library/LaunchDaemons/cc.chlc.batt.plist`（`0644`，`chown root:wheel`——launchd 对 LaunchDaemon 有 root 属主硬要求）；`launchctl load` 注册并启动。
  - 坑：launchd 记的是当前二进制**绝对路径**，移动二进制 daemon 就起不来（issue #103/#117 类问题来源）。
- **plist 要点**：`RunAtLoad = true`、`KeepAlive = true`、`ProcessType = Interactive`（防被系统降权/挂起）、日志落 `/tmp/batt.log`。
- **升级**：原地替换 plist + 重新 load，不阻止覆写。
- **卸载（恢复默认充电，至关重要）**：
  - 服务移除层只做 `launchctl unload` + 删 plist，**不碰 SMC**。
  - **真正的恢复在 CLI uninstall 命令**：① 停服务 → ② 重新允许充电（EnableCharging）→ ③ 恢复墙电（EnableAdapter）。提供 `--no-reset-charging` 跳过。
  - 结论：走 CLI uninstall 不会留「永远充不满」的砖态；但**用户手动删 plist / kill 进程时禁充 key 会残留**——真实风险点，新项目要重视。

## 6. 已知坑（GitHub issues）

- **#14 睡眠中继续充电（open）**：核心顽疾，催生三套睡眠特性，forced/clamshell 睡眠仍非完美。
- **#33 DarkWake**：DarkWake 下电源状态误判。
- **#34 macOS Tahoe 26**：新 macOS 固件换 SMC key（CHTE/CHIE）→ **SMC key 随系统大版本漂移，长期维护负担**。
- **#117 / #53 / #103 / #29**：一大类 daemon 启动/socket/路径问题，多源于二进制被移动、brew service 环境差异、安装路径不一致。
- 其余边界：多用户机器下 `--allow-non-root-access` 等于全员可改策略；clamshell + adapter disable = 直接睡眠；掉拍检测在睡眠跨度大时仍可能短暂偷充。

## 7. 设计批判（面向 smctl）

**值得继承：**

- **daemon(root) + 多客户端(CLI/GUI) + HTTP-over-Unix-socket**：协议成熟、易调试、GUI/CLI 共用同一 API 面。事件用 SSE（`/events`）推 GUI 也很干净。
- **双阈值死区**（lower/upper + delta）做迟滞防抖，简单可靠，**风扇转速档位同理适用**。
- **掉拍检测护栏**：用循环间隔异常推断「睡过/被挂起」并采取保守动作，是对抗睡眠类边界的好模式。
- **能力探测 + 多 key 兼容表**（capabilities map）：把机型/固件差异收敛到一张映射表，smctl 应一开始就建这层抽象。
- **卸载即恢复硬件默认态**：把「不留砖」当一等公民。

**值得改进：**

- **权限只有全开/全关**：应做「只读 vs 写」分级，通过 peer credential（`getpeereid`/`SO_PEERCRED`）读对端 uid 做 per-endpoint 授权。smctl 涉及风扇等更危险操作，更需要细粒度。
- **SMC 写无重试无回读**：应加幂等重试 + 写后回读校验（read-back verify），「禁充/恢复充电」尤其要确认落地。
- **恢复依赖走对 uninstall 路径**：更稳的做法是 daemon 退出时（含 crash/被 kill）有「死手」机制——watchdog 或退出 hook 在 daemon 异常消失时自动恢复 SMC 默认态，避免「手动删 plist 就砖」。**对风扇控制这是安全问题而不只是体验问题**。
- **睡眠模型割裂**：三个 sleep 特性互斥、需用户理解差异。smctl 应统一成一个状态机（power assertion + pre-sleep 写值 + 唤醒重算），对用户只暴露「睡眠期是否维持限充」一个开关。
- **日志落 `/tmp` + 默认 debug**：应走 `os_log` / `/var/log` 并可配。
- **Intel 基本放弃**：若 smctl 要覆盖 Intel Mac，得自建并验证 Intel SMC key 表（如 `BCLM` 充电上限 key），不能照搬。

---

**关键文件索引（batt 仓库内路径）**：通信 `pkg/daemon/daemon.go`、`pkg/daemon/handlers.go`、`pkg/client/*`；状态机 `pkg/daemon/loop.go`；睡眠 `pkg/daemon/sleepcallback.go`、`sleepassertion.go`、`hook.c`；SMC `pkg/smc/charging.go`、`adapter.go`、`consts_arm64.go`、`consts_amd64.go`；安装/卸载 `pkg/utils/daemon/install.go`、`uninstall.go`、`cmd/batt/install.go`、`hack/cc.chlc.batt.plist`。

注：issue #14 评论线程仅核对了首帖（GitHub 动态加载限制），解决方案对应关系是结合源码特性反推的；如需逐条核对建议直接浏览该 issue。
