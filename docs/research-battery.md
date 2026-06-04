# battery（actuallymentor/battery）调研笔记

> 调研日期：2026-06-04。面向 smctl 的产品 / 运营 / 技术坑提炼。数据以 GitHub 仓库页与 raw 源文件为准（ecosyste.ms 镜像数据停在 2024，已弃用）。

## 0. 一句话定性

一个「不爽付费软件 AlDente，假期随手写的 shell 脚本」，因为同事想要 GUI 才套了个 Electron 壳，结果滚到 ~7k 星、17+ 贡献者、持续维护到 2026 年的 macOS 电池限充工具。**它的价值不在架构（shell + 预编译 smc 二进制，smctl 不该学），而在「CLI 先行 → GUI 长出来」的产品路线和分发增长的真实样本。**

## 一、产品与分发（重点）

### 1. 安装体验

**三条安装路径，分层清晰（值得直接抄这个结构）：**

- `brew install battery` —— 装 GUI（cask）
- 下载 `.dmg` —— 装 GUI
- `curl -s .../setup.sh | bash` —— **只装 CLI**

关键产品决策：**GUI 和 CLI 是同一套，装 GUI 自动把 CLI 也装上；纯命令行用户走 curl 一行**。一个安装入口，按用户类型分流。

**`setup.sh` 实际做了什么：**

- 程序目录：`/usr/local/co.palokaj.battery/`（root 拥有，755，反域名命名避免冲突）
- 符号链接：`/usr/local/bin/battery` 和 `/usr/local/bin/smc`
- PATH 注入：写 `/etc/paths.d/50-battery`（比改 shell rc 干净）
- 用户态配置：`~/.battery/`（pid / log）
- 开机自启：`~/Library/LaunchAgents/battery.plist`（**LaunchAgent，非 root daemon**）
- 提权：开头一次 `sudo echo` 缓存密码；常态用 sudoers NOPASSWD 让普通用户免密调特定 smc 写命令（见 §6）

**卸载体验：** `battery uninstall` 会重新启用充电、删 smc 与脚本，但 issue 区反映卸载不干净（残留 `~/.battery`、`/usr/local/bin` 缓存）。**smctl 教训：卸载要幂等且彻底（sudoers/LaunchDaemon/PATH 全回滚），并提供 `--purge`。**

### 2. CLI 命令面设计

| 命令 | 作用 | 参数风格 |
|---|---|---|
| `battery status` | SMC 状态、百分比、剩余时间 | 无 |
| `battery maintain` | **核心**，重启持久的限充 | `LEVEL[1-100,stop]` 或 `RANGE[lower-upper]`，如 `maintain 80`、`maintain 70-80` |
| `battery charging` | 手动开关充电 | `on/off` |
| `battery adapter` | 控制适配器供电 | `on/off` |
| `battery charge` | 充到指定百分比后停 | `LEVEL` |
| `battery discharge` | 阻断适配器直到放到目标 | `LEVEL` |
| `battery calibrate` | 校准：放到 15% → 充满 → 保持 1h → 回 80% | 无 |
| `battery visudo` | 重新配置 sudoers 免密 | 无 |
| `battery update` / `reinstall` / `uninstall` | 自维护 | 无 |

**值得 smctl 借鉴：**

- `maintain` 同时支持**单值（80）和区间（70-80）**——区间即天然滞回，smctl 应直接做区间 + hysteresis
- `maintain 80 stop` 用 `stop` 作 sentinel 值，比单独 `--stop` flag 顺手
- 动词命名直观：`smctl battery status / maintain / charge / discharge / calibrate` 可对齐
- `adapter on/off` 与 `charging on/off` 分开——「断墙电」和「停充电」是两个物理动作，保留区分
- 自维护（update/uninstall/visudo）内聚成子命令，用户不用记外部脚本路径

### 3. GUI 是怎么从 CLI 长出来的（增长样本）

- **起源**：作者嫌 AlDente license 限制，假期写了 CLI；同事要 GUI，花几个晚上套了 **Electron** 壳（更新走 electronjs.org 官方 update 基建，没自建）。
- **架构**：GUI 是 CLI 的薄壳，**直接 shell out 调 `battery` 命令**，不是共享 daemon。
- **增长影响**：语言占比从 Shell 主导变成 JS ~50% / Shell ~50%。**GUI 是 star 增长的放大器**——纯 CLI 难破万星，套 GUI + Homebrew + dmg 后才进入大众视野。
- **对 smctl 的启示**：印证「CLI 优先、GUI 是后期增长杠杆」路线。但「GUI shell out 调 CLI」是偷懒做法，带来权限弹窗、进程管理混乱（issue 区有「GUI 把电池放干」的严重 bug）。smctl 的 daemon 架构让 **GUI 走 IPC 连 daemon**，这是 battery 没能力做、smctl 的结构性优势。

### 4. README 与营销打法

- **口号直击痛点**：标题一句话 + 正文第一句讲收益（「长期插电的 Mac 保持 80% 能延长电池寿命」），**先讲收益再讲工具**，不堆技术。
- **划清与系统功能的边界**：专门一段解释「和 macOS Optimized Charging 有什么不同」（可控触发时机与目标百分比，不依赖机器学习）。**教育市场、消除「系统不是已经有了吗」疑虑的关键文案，smctl 必须有对应章节。**
- **诚实分流**：明确不支持 Intel，导流 AlDente——反而建立信任。
- **变现：几乎不做**。无付费版，明确声明「free and open-source and will remain that way」。**对 smctl：免费开源是该品类预期基线，付费版会被对标 AlDente；变现得想别的路子。**

### 5. 社区运营与项目状态

- **活跃维护**：v1.4.0（2026-02，安全加固）；7k+ star、154 open issues、17+ 贡献者。
- **release 节奏不规律但响应及时**：macOS 大版本一出快速连发补丁（v1.3.1/1.3.2 隔一天专修 macOS 26）。
- **高度依赖社区 PR**：macOS 26 兼容、严重耗电 bug 都靠外部贡献者。

## 二、技术坑（吸取教训）

### 6. sudoers NOPASSWD 实现与安全面

机制：不跑 root daemon，`battery visudo` 往 sudoers 写免密规则：

```
Cmnd_Alias CHARGING_OFF = /usr/local/bin/smc -k CH0B -w 02, /usr/local/bin/smc -k CH0C -w 02 ...
Cmnd_Alias CHARGING_ON  = /usr/local/bin/smc -k CH0B -w 00, ...
ALL ALL = NOPASSWD: /usr/local/co.palokaj.battery/battery update_silent
```

免密范围：开/关充电、强制放电、MagSafe LED、静默更新。

- 做对的：二进制及父目录 root 拥有、用户不可写；sudoers 硬编码绝对路径防 PATH 劫持。
- 风险：`update_silent` 免密 + 自动从 GitHub 拉新版 = **「免密执行一个会自我更新的二进制」**，供应链一旦被污染就是免密 root。v1.4.0 的安全加固正是冲这个去的。

> **smctl 教训**：daemon 架构是更干净的解法——特权集中在 root LaunchDaemon，CLI 通过 socket 发结构化请求，daemon 做白名单校验。**彻底不碰 sudoers NOPASSWD，也不让 CLI 自我更新执行特权代码。**

### 7. 睡眠期间偷充 —— 基本没解决

- 维护是 `nohup ... maintain_synchronous &` 的**用户态后台循环，每 60 秒轮询**。睡眠时循环挂起 → 偷充。
- 只在主动充/放电操作里用 `caffeinate -is`；维护循环用裸 `sleep 60`，**没有 sleep/wake hook**，醒来要等下一个 tick 才纠正。

> **smctl 教训**：daemon 注册 `IORegisterForSystemPower`，唤醒立即重新评估；事件驱动 + 轮询结合，别用裸 sleep。（batt 的方案见 `research-batt.md` §2，更进一步。）

### 8. 预编译 smc 二进制的 license 隐患

- `dist/smc` 预编译自 **hholtmann/smcFanControl（GPL-2.0）**，而 battery 仓库是 MIT——**MIT 仓库捆 GPL 二进制存在合规张力**，只是没被引爆（issue 区未见实质讨论）。

> **smctl 教训**：绝不捆 GPL 二进制。Swift 直接调 IOKit/AppleSMC 自实现 SMC 读写——license 干净、无外部二进制依赖、利于签名/公证。

### 9. 高频 issue 类型

1. **macOS 大版本升级即失效（最高频、最痛）**：`SMCWriteKey() = e00002bc`，Apple 改 SMC key/权限，限充直接失灵，每年重演
2. 安装失败（架构不符、权限）
3. 充电卡死 / 状态不更新
4. clamshell（合盖外接显示器）模式失效
5. 新芯片机型在新 key 出来前失灵
6. GUI 严重耗电 bug（曾把电池放干）

> **smctl 教训**：macOS 升级击穿是品类的**结构性宿命**。应对：(1) 「机型 × macOS 版本 → key 集合」数据驱动兼容表，新系统只加映射不改逻辑；(2) 写失败**明确报错 + 降级**，绝不静默失灵让用户以为在保护电池其实没生效；(3) macOS beta 兼容测试纳入发布流程。

### 10. 平台支持

- 只支持 Apple Silicon，明确不支持 Intel（导流 AlDente）。
- key 按机型/系统分版本：旧 AS 用 `CH0B`/`CH0C`、放电 `CH0I`/`CH0J`/`CHIE`；Tahoe（macOS 26）改用 `CHTE`；LED `ACLC`。与 batt 调研交叉印证。
- 兼容策略 = **跟随式打补丁**：出问题 → 社区 PR 补 key → 快速发版，无前瞻测试。

## 三、给 smctl 的可操作结论

1. **抄安装分层**：一个入口按用户分流（brew/dmg 装 GUI 自带 CLI；curl 一行只装 CLI）；卸载彻底幂等 + `--purge`。
2. **抄命令面**：`status / maintain(区间+滞回) / charge / discharge / calibrate`，自维护子命令内聚。
3. **抄文案打法**：先讲收益、专段讲清「和系统 Optimized Charging 的区别」、诚实标注硬件边界。
4. **不抄架构，守住 4 条护城河**：
   - Swift IOKit 自实现 SMC 读写，不捆 GPL 二进制
   - 特权集中 root daemon + IPC 白名单，弃用 sudoers NOPASSWD
   - 注册 wake/sleep 通知，唤醒即纠正（解决偷充硬伤）
   - SMC key 数据驱动兼容表（机型 × 系统版本）
5. **变现预期管理**：免费开源是品类基线；增长靠 GUI + Homebrew 破圈，不靠卖软件。

**主要来源**：GitHub 仓库主页 / README / `setup.sh` / `battery.sh`（raw main 分支）、releases、issues（按评论排序及 #384/#386/#420）、作者起源自述。
