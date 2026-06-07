# smctl

> The missing control knob for your Mac's SMC.
> 开源、CLI 优先的 Mac 硬件控制工具：风扇曲线、电池充放电策略、电源管理，一个工具搞定。

**当前状态：调研 / 设计阶段。** 本 README 暂为中文工作文档，正式发布时改写为英文。

## 愿景

macOS 用户在风扇和电池管理上长期被碎片化、半收费、半失修的工具折磨。smctl 的定位：

- **CLI 优先**：`smctl fan` / `smctl battery` / `smctl sensors`，命名传统对齐 `systemctl` / `launchctl`
- **策略驱动**：声明式配置文件（TOML）定义风扇曲线与充电策略，可进 dotfiles 同步
- **后续封装 macOS 桌面端**：daemon 架构保证 GUI 阶段零返工，GUI 只是另一个客户端
- **开源（MIT）**

## 核心功能规划

### 1. 风扇控制（Mac mini / Mac Studio / MacBook Pro 等带风扇机型）

- 读传感器温度、读/写风扇转速，自定义风扇曲线
- 策略引擎差异化：多传感器加权、滞回（hysteresis，防转速抖动）、场景 profile（静音模式 / 全速模式）
- headless 场景一等公民：Mac mini 当 homelab 服务器的用户没有任何 CLI 风扇工具可用

### 2. 电池充放电策略（MacBook 系列）

- 充到 X% 停止充电、高于 Y% 主动放电、sailing 区间（如 75–80% 浮动不充）
- 出门前 top-up 一键充满、校准模式（定期放电到低位再充满）
- 循环次数 / 健康度 / 历史曲线记录（本地 SQLite，GUI 阶段直接画图）

### 3. 周边集成（同一用户群的高复用痛点）

- **温度与功耗监控**：CPU/GPU/电池温度、封装功耗（`powermetrics` 需 root，daemon 正好有）；老牌 `istats` 已失修多年，CLI 真空
- **睡眠/保持唤醒**：`caffeinate` 人性化封装（「下载完前别睡」「合盖不睡 2 小时」）
- **低电量模式 / 电源策略切换**：按电源状态自动切（插电高性能、电池省电）
- **MagSafe LED 控制**：SMC key `ACLC`，配合充电限位（限充时灯变绿）
- **热压制可见性**：`pmset -g therm` 读 CPU speed limit，告诉用户被降频了多少
- **菜单栏状态**（GUI 阶段）：温度 + 转速 + 充电状态，对标 Stats 但「看 + 控 + 策略」

**明确不做**：内存清理、缓存清理等「优化大师」功能——与硬件控制定位不搭，拉低专业感。

## 技术调研结论（2026-06）

### SMC 是唯一底层通路

读温度、读写转速、控制充电，全部通过 IOKit 与 `AppleSMC` 内核驱动通信。不需要关 SIP，但**写操作需要 root** → 必须有特权 daemon。

关键 SMC keys：

| 功能 | Key | 说明 |
|---|---|---|
| 充电开关 | `CH0B` / `CH0C` | AlDente、batt 均用此组（Apple Silicon） |
| 断开电源输入 | `CH0I` / `CH0J` | 实现「插电时主动放电」 |
| 官方 80% 限充 | `CHWA` | 只有 80% 一档，不可自定义 |
| 风扇模式（AS） | `F0Md` | auto / forced |
| 风扇目标转速 | `F0Tg` | Intel 时代也是它；Intel 另有 `F0Ac`（实际转速）、`FS! `（强制手动） |
| MagSafe LED | `ACLC` | 改灯色 |

注意：M 系列每代传感器 key（大量 `Tp__`/`Tg__` 私有 key）都可能变。**调研更新（见 `docs/research-macos-smc-fan.md` §3）**：风扇控制 key 的代际差异可用**运行时探测**（readKey 探针试 key 大小写 + Ftst 存在性）解决，无需维护静态芯片表；但私有温度传感器 key 和充电 key 仍可能随 macOS 大版本漂移（如 Tahoe 26 新增 `CHTE`/`CHIE`，见 `docs/research-batt.md` §4），需要「启动时能力探测 + 多 key 兼容表」。

### ⚠️ Apple Silicon 风扇控制：刚被破解的前沿（最重要发现）

- macOS 上 Apple 的 `thermalmonitord` 守护进程会**主动拦截 SMC 风扇写入**，强制锁定 "System Mode"（mode 3）。在 2026 年之前 macOS 上的 Apple Silicon 手动风扇控制**没有任何公开文档**（Asahi Linux 只在 Linux 侧实现过）。
- [agoodkind/macos-smc-fan](https://github.com/agoodkind/macos-smc-fan)（MIT）首次公开了绕过方法：**`Ftst` 诊断模式解锁序列**，提供 M1–M5 全代际可用实现，XPC + 特权 helper 架构。README 明确允许「研究成果自由用于独立实现」。
- 解锁公开后，2026 年 5 月涌现一批 0–50 星的 Apple Silicon 风扇 GUI 小工具（CoolMyMac、ChillPill、macfanctl 等），**窗口期正在打开，但还没人做统一 CLI**。
- **风险**：`Ftst` 本质是诊断模式，Apple 可能在未来 macOS 版本封堵。设计上必须把「风扇控制不可用时优雅降级为只读监控」做成一等公民。

### 睡眠期间的充电行为是口碑分水岭

Mac 睡着后 daemon 不跑，系统可能继续充满。成熟方案（AlDente、batt）在睡眠前钩子里写入禁充 key，或阻止睡眠。这块细节决定工具口碑。

### 竞品格局

| 项目 | 星数 | 语言 / License | 状态 | 备注 |
|---|---|---|---|---|
| [exelban/stats](https://github.com/exelban/stats) | 39.3k | Swift / MIT | 活跃 | 菜单栏监控，只读不可控 |
| [actuallymentor/battery](https://github.com/actuallymentor/battery) | 7.0k | Shell / MIT | 活跃 | **CLI → GUI 路线的活样本**；底层糙（调预编译 smc 二进制） |
| [hholtmann/smcFanControl](https://github.com/hholtmann/smcFanControl) | 2.5k | ObjC / GPL-2.0 | **失修**（2023 止） | Intel 时代遗产 |
| [zackelia/bclm](https://github.com/zackelia/bclm) | 2.2k | Swift / MIT | 半维护 | Intel 限充为主 |
| [charlie0129/batt](https://github.com/charlie0129/batt) | 1.6k | Go / **GPL-2.0** | 活跃 | **架构最佳参照**：daemon + CLI + Unix socket + 睡眠钩子；代码不可抄进 MIT |
| [rurza/BatFi](https://github.com/rurza/BatFi) | 580 | Swift / MIT | 活跃 | GUI 限充 |
| [dkorunic/iSMC](https://github.com/dkorunic/iSMC) | 188 | Go / GPL-3.0 | 活跃 | SMC 只读 CLI |
| [agoodkind/macos-smc-fan](https://github.com/agoodkind/macos-smc-fan) | 19 | Swift / MIT | 新研究 | **AS 风扇解锁首个公开文档** |
| AlDente | — | 闭源收费 | 活跃 | 只做电池，无 CLI |
| Macs Fan Control / TG Pro | — | 闭源（半收费） | 活跃 | 只做风扇，无 CLI，策略弱 |

**结论：市场上没有「开源 + CLI 优先 + 风扇/电池/电源策略统一」的工具，smctl 卡位这个空白。**

### License 策略

- 本项目 **MIT**
- 可直接借鉴代码：battery、bclm、BatFi、agoodkind/macos-smc-fan（均 MIT）
- 只可参考思路、不可抄代码：batt、smcFanControl、iSMC（GPL）；SMC key 本身是事实，不受版权保护

## 架构设计（初稿）

```
┌─ CLI (smctl) ──┐
│                ├──→ Unix socket / XPC ──→ 特权 daemon (root, LaunchDaemon)
└─ GUI (以后) ───┘                             ├──→ SMC 读写（IOKit → AppleSMC）
                                               ├──→ 策略引擎（风扇曲线 / 充电策略）
                                               └──→ 睡眠/唤醒钩子
```

设计要点：

- **策略引擎放 daemon 里**，CLI / GUI 都只是客户端 → GUI 阶段零返工
- 语言候选：**Swift**（IOKit 绑定顺、SMAppService 注册 daemon 顺、GUI 无缝）或 **Rust**（有 `smc` crate）；Go 的问题是 GUI 阶段要换语言
- 配置：声明式 TOML 定义风扇曲线与充电策略
- 分发：Homebrew + 公证 pkg。**永远进不了 App Store**（root daemon），一开始就不按沙盒约束设计
- **硬约束**：SMAppService 安装特权 helper 需要 **Developer ID 签名（付费开发者账号）**，做桌面端反正需要，提前办

## 命名

`smctl` = SMC + ctl。落选：`tend` / `stasis` / `halcyon`（同名活跃项目）、`macctl`（已有同概念仓库）、`wattson`（撞 Apex 角色）。GitHub 无实质冲突，Homebrew 无冲突（2026-06 核查）。

## 下一步

- [x] 精读 agoodkind/macos-smc-fan（`Ftst` 解锁细节、风扇行为）→ `docs/research-macos-smc-fan.md`
- [x] 精读 batt 的 daemon 设计（socket 协议、睡眠钩子、状态机）→ `docs/research-batt.md`
- [x] 精读 battery 的产品路线与分发打法（CLI→GUI、安装分层、命令面、踩坑）→ `docs/research-battery.md`
- [x] 技术设计文档：SMC 抽象层、daemon 通信协议、策略引擎、降级策略 → `docs/design.md`
- [x] 定语言：**Swift**（XPC/SMAppService 生态原生，Rust 做特权 IPC 极痛，见 `docs/design.md` §3）；IPC 定 **XPC**（audit token 签名校验，§7）
- [x] MVP 边界：M1 只读监控 → M2 电池策略 → M3 风扇控制，纵切三步每步可用（`docs/design.md` §13）
- [x] 仓库脚手架：SPM 多 target（SMCCore / PolicyEngine / SMCtlProtocol / smctld / smctl）
- [x] M1：SMCCore 只读层 + `smctl sensors`（真机验证 ✅）
- [x] M2：电池策略 daemon + XPC + `smctl battery`（真机 E2E ✅；充电写路径待 MacBook 实测）
- [x] M3：Apple Silicon 风扇控制 + 温度护栏（真机全链路 ✅，实测发现见 `docs/field-notes-m4-mini.md`）

MVP 之后（v0.1 发布线）：

- [ ] 办 Apple Developer ID 账号（签名/公证硬前置）→ XPC 调用方签名校验补全
- [ ] 建 GitHub 仓库 + README 改写英文 + Homebrew tap
- [ ] MacBook 实测：充电写路径（CHTE/CH0B）、睡眠偷充、Ftst 回退路径（M4 Max/M2/M3 机型）
- [ ] `smctl battery calibrate`、`smctl power status`（热压制可见性）
- [ ] 长测：曲线 profile 多日稳定性、macOS 升级击穿演练

调研沉淀的关键设计约束（技术设计文档必须吸收）：

1. **风扇手动控制需常驻进程持续保持 `Ftst=1`**——thermalmonitord 空闲 ~4s / 热负载 ~250ms 就会 reclaim，不是「写一次就完事」
2. **crash 安全**：daemon 异常退出必须 best-effort 还原 `Ftst=0` + auto 模式；固件兜底（sleep 清 Ftst、独立热保护）是推断未实测，不可依赖
3. **睡眠模型统一成一个状态机**（pre-sleep 写值 + power assertion + 唤醒重算 + 掉拍检测），不学 batt 的三个互斥开关
4. **SMC 写要回读校验 + 重试**（batt 没做，是其鲁棒性短板）
5. **卸载/异常路径都要恢复硬件默认态**（「不留砖」一等公民）
6. **IPC 调用方要校验代码签名/Team ID**（macos-smc-fan 的 XPC 校验形同虚设，不能学）

## 增长投稿记录

| 渠道 | 时间 | 链接 | 状态 |
|---|---|---|---|
| 阮一峰周刊（ruanyf/weekly） | 2026-06-06 | [issue #10233](https://github.com/ruanyf/weekly/issues/10233) | 已投，等待刊发（每周五发布；纪律：不催更、不二次评论；2-3 期未收录则等产品节点换角度再投。参考：MultiPost 曾于第 336 期被收录） |
| Show HN / r/macapps / V2EX | — | 文案已备 | 待发 |
