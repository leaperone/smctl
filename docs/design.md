# smctl 技术设计文档

> 状态：初稿，2026-06-04。
> 输入：`research-macos-smc-fan.md`（风扇解锁）、`research-batt.md`（daemon 架构）、`research-battery.md`（产品路线）。
> 本文档定案语言、架构、IPC、安全机制与 MVP 边界，是脚手架与实现的依据。

## 1. 设计目标与非目标

**目标：**

- 开源（MIT）、CLI 优先的 Mac 硬件控制统一工具：风扇曲线、电池充放电策略、电源管理
- daemon 架构一步到位，GUI 阶段零返工
- **安全第一等公民**：任何异常路径（crash、kill、卸载、升级、macOS 升级击穿）都回到「系统默认控制」，绝不留砖、绝不静默失灵

**非目标：**

- 不做内存/缓存清理类「优化大师」功能
- 不进 App Store（root daemon 决定了永远进不去，不按沙盒设计）
- MVP 不做 GUI、不做日程调度（schedule）、不做 Intel 机型适配（结构上预留）

## 2. 总体架构

```
┌──────────────┐
│ smctl (CLI)  │ 非特权，用户态
└──────┬───────┘
       │ XPC (mach service, audit token 校验)
┌──────▼───────────────────────────────────────────┐
│ smctld (root LaunchDaemon, SMAppService 注册)     │
│                                                  │
│  ┌─ IPC 层（XPC listener + 权限分级 + 事件广播）   │
│  ├─ 策略引擎（风扇曲线 / 充电状态机 / 睡眠状态机）  │
│  ├─ SMC 抽象层（IOKit ↔ AppleSMC，兼容表+探测）    │
│  ├─ 电源事件（IORegisterForSystemPower）          │
│  └─ 安全监督（死手机制 / 温度护栏 / 状态对账）      │
└──────────────────────────────────────────────────┘

GUI（以后）= 另一个 XPC 客户端，与 CLI 完全对等
```

核心原则：

1. **策略在 daemon，客户端只是遥控器**。CLI/GUI 都不含业务逻辑，只发结构化请求 + 渲染结果。
2. **特权只存在于 smctld 一处**。不用 sudoers NOPASSWD（battery 的供应链教训），不让 CLI 自我更新执行特权代码。
3. **daemon 是有状态的**：风扇手动控制需要持续保持 `Ftst=1` 对抗 thermalmonitord reclaim（空闲 ~4s / 热负载 ~250ms），常驻进程不是架构洁癖，是功能前提。

## 3. 语言与工程定案

**Swift，定案。** 理由（详见 research-macos-smc-fan §6）：

- SMC 的 80 字节 `SMCParamStruct` + `IOConnectCallStructMethod` 纯 Swift 可写，无需 C 桥接
- XPC、SMAppService、audit token 签名校验全是原生通路；Rust 无成熟 XPC binding，特权 IPC 层得写 Swift/ObjC 薄壳，等于两种语言
- GUI 阶段（SwiftUI 菜单栏）无缝
- 四个 MIT 参照（battery、bclm、BatFi、macos-smc-fan）三个是 Swift

**SPM 布局：**

```
smctl/
├── Package.swift
├── Sources/
│   ├── SMCCore/        # IOKit 通信、SMCParamStruct、数据格式(fpe2/float)、key 兼容层
│   ├── PolicyEngine/   # 风扇曲线、充电状态机、睡眠状态机（纯逻辑，可单测）
│   ├── SMCtlProtocol/  # XPC 协议 + 共享 DTO（CLI/daemon/GUI 三方依赖）
│   ├── smctld/         # daemon 可执行体
│   └── smctl/          # CLI 可执行体（swift-argument-parser）
└── Tests/
```

`PolicyEngine` 与 IOKit 解耦（注入 `SMCBackend` 协议），状态机全部可在 CI 跑单测——这是对「策略正确性」的工程保证，竞品全都没有。

## 4. SMC 抽象层（SMCCore）

### 4.1 IOKit 通信

- Service `AppleSMC`，`IOServiceOpen` connection type 0，`IOConnectCallStructMethod` selector 2
- 命令字节：`9`=读 key info、`5`=读值、`6`=写值
- 80 字节 struct 布局照 research-macos-smc-fan §5（注意 `MemoryLayout.stride` 而非 `.size`）
- 数据格式双轨：Apple Silicon = 4 字节 IEEE754 小端 float；Legacy = `fpe2` 大端定点（预留）

### 4.2 key 兼容层：数据驱动表 + 运行时探测，双层混合

这是品类存活的关键工程（batt 的 Tahoe 击穿、battery 的「每年升级即失效」都源于此）：

- **静态表**（`KeyCatalog`，代码内数据结构，未来可外置 JSON）：按「功能 → 候选 key 列表（按优先级）」组织，如充电控制 = `[CHTE(Tahoe), CH0B+CH0C(pre-Tahoe)]`、断墙电 = `[CHIE, CH0I+CH0J]`
- **运行时探测**（启动时跑一次，结果缓存为 `Capabilities`）：对每个候选 key 做 readKey 探针（`0x84 SmcNotFound` 即不存在），风扇模式 key 探大小写（`F0Md` vs `F0md`）、`Ftst` 探存在性
- 新 macOS 击穿时：只在 KeyCatalog 加一行映射，不改任何逻辑

`Capabilities` 同时是**降级的依据**：探测不到充电 key → battery 子命令报「此机型/系统不支持，只读监控可用」；探测不到风扇写权限 → fan 降级只读。**绝不静默失灵**（battery 最痛 issue 的反面）。

### 4.3 写入纪律（batt 没做的鲁棒性）

所有 SMC 写遵循统一流程：**写 → 回读校验 → 不一致则重试（指数退避，上限 3 次）→ 仍失败则上报错误并触发该子系统降级**。充电禁/启、Ftst 开/关这类安全关键写入，失败必须让用户看见。

## 5. 风扇子系统

### 5.1 解锁状态机（照搬 macos-smc-fan 的两阶段自发现）

```
locked ──直写 modeKey=1 成功──► manual          （M1/M5 路径）
   │
   └─失败且 ftstAvailable──► 写 Ftst=1 → 等 0.5s
        → 重试 modeKey=1（间隔 0.1s，超时 10s）──► manual   （M4 路径）
        └─超时──► unsupported（降级只读）
```

手动控制 = `modeKey=1` + `F%dTg`=目标 RPM（4 字节小端 float）。

### 5.2 Ftst 全局闸门管理

- `Ftst` 是全局的，daemon 内用引用计数管理：**最后一个退出手动模式的风扇才清 Ftst=0**（清之前先读，为 1 才写，保证幂等）
- M1/M5 走 direct 路径，Ftst 引用计数恒为 0，恢复逻辑天然跳过

### 5.3 crash 安全 / 死手机制（对原项目 Untested 区的补强）

固件兜底（sleep 清 Ftst、独立热保护）是**推断未实测**，不可依赖。三道防线：

1. **退出钩子**：signal handler（SIGTERM/SIGINT）+ 正常退出路径，best-effort 写 `Ftst=0` + 所有风扇 `modeKey=0`
2. **启动对账**：daemon 由 launchd `KeepAlive` 拉起后，启动时核对「持久化的期望状态」vs「SMC 实际状态」——若发现 Ftst=1 但本地无活跃手动策略（上次 crash 的残留），立即恢复 auto
3. **温度护栏（安全地板）**：手动模式期间 daemon 以 1s 间隔监控关键温度传感器；任一传感器超过安全阈值（默认保守值，可配但有硬下限）→ 强制恢复 auto 并告警。手动模式下 thermalmonitord 不管散热，**这道护栏由我们补上**

另外：SIGKILL 杀掉 daemon 时 1、2 都来不及/延迟，此时 thermalmonitord 的 reclaim（Ftst≠1 时几秒内收回）+ launchd 秒级重启 + 启动对账兜底——残余风险窗口只剩「Ftst=1 且 daemon 未被重启」，靠 KeepAlive 把这个窗口压到秒级。

### 5.4 风扇曲线引擎（PolicyEngine）

- 曲线 = 折线段：`[(温度, RPM), ...]`，输入为**多传感器加权聚合值**（可配权重，默认取 max）
- **滞回**：双阈值死区（升温越过 T 才升档，降温越过 T−delta 才降档），杜绝转速抖动——与充电状态机共用同一个 hysteresis 抽象
- **变化率限制**：RPM 目标变化做 slew rate 限制，避免风扇忽高忽低的体感噪音
- profile：`quiet` / `auto` / `full` / 自定义曲线，TOML 定义

### 5.5 唤醒恢复

固件在睡眠转换时自动清 Ftst（实测来源：research-macos-smc-fan §4）→ 监听唤醒事件，**唤醒后自动重跑解锁序列**恢复手动策略，用户无感。

## 6. 电池子系统

### 6.1 充电状态机（继承 batt 的双阈值死区）

- 配置：`limit`（上限）+ `lower_delta`（默认 2%）；`maintain 70-80` 风格的区间语法直接映射这两个值
- 转换：电量 < lower 且未充 → 开充；≥ upper 且在充 → 停充；区间内 → 保持现状（死区）
- 评估循环 10s + 事件驱动（电源插拔、唤醒立即重评估）
- 主动放电：断墙电（`CHIE`/`CH0I+CH0J`）让系统吃电池，仅 calibrate 和显式 `discharge` 命令触发
- MagSafe LED（`ACLC`）：限充保持中亮绿（可配）

### 6.2 统一睡眠状态机（不学 batt 的三个互斥开关）

对用户只暴露一个语义开关：`sleep_policy = "strict" | "relaxed"`（默认 strict）。内部状态机统一处理：

- **pre-sleep**（`kIOMessageSystemWillSleep`）：limit 激活时一律写禁充，然后 `IOAllowPowerChange` 放行（绝不阻塞睡眠）
- **idle sleep 否决**（`kIOMessageCanSystemSleep`）：仅 strict 且「正处于充电会话、距 limit 还差 > 3%」时否决，避免充电被打断；其余放行
- **唤醒**（`kIOMessageSystemHasPoweredOn`）：立即强制重评估充电状态 + 重跑风扇解锁
- **掉拍检测**（继承 batt 的护栏）：评估循环间隔异常拉长 ⇒ 期间睡过/被挂起 ⇒ 保守动作（若在充电先禁充，重评估后再决定）
- DarkWake：唤醒处理里区分 full wake / dark wake（`IOPMUserIsActive`），dark wake 只做状态纠正不做策略变更

### 6.3 健康度记录

循环次数 / 健康度 / 充电历史落本地 SQLite（`/var/lib/smctl/history.db`），GUI 阶段直接画图。MVP 仅记录，不出图表命令。

## 7. daemon 与 IPC

### 7.1 决策：XPC（mach service），不用 HTTP over Unix socket

batt 的 socket 方案唯一实质优势是 curl 可调试；代价是鉴权只剩文件权限位（全开/全关）。smctl 选 XPC：

- **audit token 校验调用方代码签名 / Team ID**（`SecCodeCopyGuestWithAttributes`），这是 root daemon 的安全底线——macos-smc-fan 的 `shouldAcceptNewConnection` 无条件放行是反面教材，必须补上
- SMAppService 注册 LaunchDaemon + `MachServices` 原生一体
- 事件推送用 XPC 双向回调，GUI 订阅同一接口
- 调试劣势用 `smctl daemon ping/status/log` 子命令弥补；第三方集成走 `smctl ... --json`，不暴露裸协议

### 7.2 权限分级

- **读类请求**（sensors、status、config 读）：任何本地已签名客户端放行
- **写类请求**（改策略、手动风扇、充放电、daemon 管理）：校验调用方 euid（root 或 admin 组）**且**代码签名匹配；不满足时 CLI 引导 `sudo smctl ...`
- 安全关键操作（如关闭温度护栏）额外要求显式 `--force`

### 7.3 API 面（XPC 协议草案）

```
// 只读
getSensors() / getFans() / getBatteryStatus() / getCapabilities() / getDaemonStatus()
subscribeEvents(handler)        // 状态变化推送（GUI/watch 模式共用）

// 策略（写）
setFanPolicy(profile|curve)  setFanManual(fan, rpm)  setFanAuto(fan)
setChargeLimit(range)  setChargingEnabled(bool)  setAdapterEnabled(bool)
startCalibration() / cancelCalibration()
setConfig(key, value) / reloadConfig()
```

## 8. 策略引擎与配置

配置文件 `/etc/smctl/config.toml`，声明式，可进 dotfiles。草案：

```toml
[battery]
limit = "70-80"            # 单值 "80" 等价 "78-80"（默认 delta 2）
sleep_policy = "strict"
magsafe_led = true

[fan]
profile = "auto"           # quiet | auto | full | custom

[[fan.curves]]             # profile = "custom" 时生效
name = "custom"
sensors = ["cpu", "gpu"]   # 聚合：默认 max，可加权
points = [[50, 0], [65, 2000], [80, 4000], [95, "max"]]
hysteresis = 3             # ℃

[safety]
temp_ceiling = 100         # 温度护栏（℃），不可关闭，硬上限 105；连续 2 tick 超限才触发
                           # （实测标定：AS 结温热点传感器负载下常态 95-103℃，见 field-notes-m4-mini.md §4）
```

- CLI 改策略 = 通过 daemon API 写配置 + 立即生效（daemon 是 config 的唯一 owner，避免双写竞态）
- 手动编辑文件后 `smctl daemon reload`，或 daemon watch 文件变更自动 reload

## 9. 生命周期（不留砖原则）

- **安装**：Homebrew formula / 公证 pkg → 首次 `sudo smctl daemon install` 用 SMAppService 注册 LaunchDaemon（`KeepAlive=true`）。二进制固定落 `/usr/local/libexec/smctl/`（root 拥有），规避 batt 的「移动二进制 daemon 起不来」一类 issue
- **卸载**：`smctl daemon uninstall` 顺序执行：恢复充电默认 → 恢复风扇 auto + 清 Ftst → 注销 daemon → 删 plist；`--purge` 额外删配置与历史库。卸载流程幂等，可重复执行
- **升级**：替换二进制 + 重注册；daemon 启动对账机制（§5.3）天然覆盖升级期间的状态衔接
- **日志**：os_log（`subsystem: one.leaper.smctl`）+ `smctl daemon log` 查看，不落 /tmp

## 10. CLI 命令面（v1）

命名对齐 systemctl 的「名词 动词」风格，电池动词对齐 battery 的成熟习惯：

```
smctl sensors [--watch] [--json]            # 温度/功耗/转速一览
smctl fan status | set <rpm> [--fan N] | auto | profile <name>
smctl battery status | maintain <80|70-80|stop> | charge <90> | discharge <40> | calibrate
smctl power status                          # 热压制可见性(pmset therm)、电源状态
smctl config get/set/edit
smctl daemon install|uninstall|status|reload|log|ping
```

全局：`--json`（机器可读输出，所有子命令支持）。

## 11. 降级矩阵

| 故障 | 行为 |
|---|---|
| 风扇解锁失败 / Apple 封堵 Ftst | fan 降级只读监控，明确提示「此 macOS 版本不支持写入」 |
| 充电 key 探测失败（新 macOS 击穿） | battery 降级只读，报错引导升级 smctl / 提 issue |
| SMC 写回读不一致（重试耗尽） | 该子系统降级 + 事件告警，绝不静默 |
| daemon crash | KeepAlive 秒级重启 + 启动对账恢复一致状态 |
| daemon 被 SIGKILL 且未重启 | thermalmonitord reclaim 收回风扇（系统接管=安全态）；充电残留由重启对账修复 |
| 温度超护栏 | 强制风扇 auto + 告警事件 |

## 12. 分发与签名

- **硬前置：Developer ID 付费开发者账号**（SMAppService 特权 helper 必需，自签名无效）——立即办理，不阻塞开发但阻塞分发
- Homebrew tap 起步 → 进 homebrew-core；公证 pkg 给非 brew 用户
- 安装分层学 battery：brew 一行装 CLI；GUI 阶段 dmg/cask 装 GUI 自带 CLI

## 13. MVP 切分

纵切三步，每步都是完整可用的产品（即使 Apple 封堵 Ftst，前两步仍成立）：

1. **M1 — 只读监控**：SMCCore + 探测 + `smctl sensors`，无 daemon（直接读，无需 root）。验证 SMC 层正确性
2. **M2 — 电池策略**：daemon + XPC + 充电状态机 + 睡眠状态机 + `smctl battery`。技术最成熟（batt 已验证通路），先建立口碑
3. **M3 — 风扇控制**：解锁状态机 + 死手机制 + 温度护栏 + 曲线引擎 + `smctl fan`。风险最高放最后，但卡位价值最大（市场上无 CLI 竞品）

M2/M3 并行度高（PolicyEngine 内两个独立状态机），脚手架完成后可双线推进。

## 14. 开放问题

- [ ] `Ftst` 在 M2/M3 上的行为未实测（原项目空白）——需要社区测试矩阵，README 招募
- [ ] 固件「crash 后热保护兜底」未验证——M3 发布前设计安全的验证实验（轻负载下杀 daemon 观察）
- [ ] Intel 支持是否进 v1（`BCLM`/`FS! ` 另一套 key 体系）——倾向 v1 只读支持、写入 v2
- [ ] SQLite vs 纯文件 append log 做历史记录——MVP 阶段再定
- [ ] 菜单栏 GUI 技术选型（SwiftUI MenuBarExtra）——M3 之后
