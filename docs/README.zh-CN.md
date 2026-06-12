# smctl

[![CI](https://github.com/leaperone/smctl/actions/workflows/ci.yml/badge.svg)](https://github.com/leaperone/smctl/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-lightgrey.svg)](https://github.com/leaperone/smctl)

> 你的 Mac 缺失的那个硬件控制旋钮。

**smctl** 是一个开源（MIT）、命令行优先的 Mac 硬件控制工具——风扇转速、电池充电、温度功耗遥测，这些 macOS 替你"管理"却不让你碰的东西，现在可以在终端里直接控制。

[English](../README.md) | 中文

![smctl demo](assets/demo.gif)

```console
$ smctl battery maintain 70-80     # 电量维持在 70%–80% 区间
$ smctl fan profile quiet          # 自定义风扇曲线，不热不转
$ smctl sensors --watch            # 实时温度、风扇转速、封装功耗
```

## 为什么需要它

- **电池在 100% 满电状态下老化最快。** macOS 只提供一个黑盒的"优化充电"和固定 80% 一档，smctl 给你确定性的自定义限充区间——设一次，写进 dotfiles 永久同步。
- **Apple Silicon Mac 完全不开放风扇控制。** 没有官方 API，也没有第三方命令行工具——smctl 在 M 系列芯片上实现了手动转速和声明式风扇曲线，并内置温度安全护栏。
- **无头 Mac 值得一等公民待遇。** Mac mini 当家用服务器？所有功能都能走 SSH，所有命令都支持 `--json` 输出，随便接脚本。

## 功能

| 命令 | 作用 |
|---|---|
| `smctl sensors [--watch] [--json]` | 按传感器分组的温度、风扇转速/模式、电池、封装功耗 |
| `smctl battery status` | 电量、充电状态、当前限充配置、剩余时间估计 |
| `smctl battery maintain 80` / `70-80` / `stop` | 带死区的充电限制；加 `--force-discharge` 可主动放电到区间 |
| `smctl battery charging on\|off` / `adapter on\|off` | 手动切换充电许可与适配器供电 |
| `smctl battery charge 90` / `discharge 40` | 一次性充到目标 / 监督放电到目标 |
| `smctl fan status` | 每个风扇的实际/目标/最小/最大转速和控制模式 |
| `smctl fan set 2500 [--fan N]` | 手动设定目标转速 |
| `smctl fan profile quiet\|full\|auto\|<自定义>` | 声明式风扇曲线（TOML），带滞回和变速率限制 |
| `smctl power status [--watch] [--json]` | 热压制状态、CPU 降频幅度（限速 %）、封装功耗与输入功率 |
| `smctl alert list\|status\|test <name>` | 温度/事件告警 → webhook、命令或日志（TOML 配置） |
| `smctl daemon install\|uninstall\|status\|ping\|logs` | 管理特权 daemon 并查看最近日志 |

策略配置在 `/etc/smctl/config.toml`——声明式、可 diff、对 dotfiles 友好。

## 安装

### Homebrew（推荐）

```console
$ brew install leaperone/smctl/smctl
$ sudo smctl daemon install
```

也可以先 tap 一次，之后都用短命令：

```console
$ brew tap leaperone/smctl
$ brew install smctl        # 以后升级：brew upgrade smctl
```

### 源码构建

```console
$ git clone https://github.com/leaperone/smctl && cd smctl
$ swift build -c release
$ sudo .build/release/smctl daemon install
```

### 签名二进制

每个 [release](https://github.com/leaperone/smctl/releases) 附带 `smctl` + `smctld` 的 zip，均经 Developer ID 签名和 Apple 公证。

充电限制和风扇控制由 root LaunchDaemon `smctld` 执行，CLI 通过 XPC 与之通信；只读传感器不需要 daemon 也不需要 root。

Homebrew 安装会自动配置 shell 补全（bash/zsh/fish）和 `man smctl` 手册页。

## 安全设计

在用户态控制风扇和充电，必须以最坏情况为设计前提。smctl 把这些当作一等不变量：

- **绝不留砖。** 卸载、停止、杀死 daemon 都会把风扇和充电交还系统控制——由退出钩子、启动对账、launchd 自动重启三道防线保证。
- **温度护栏。** 风扇处于手动控制期间，smctl 每秒监控全部温度传感器；持续超过上限会强制风扇回到系统控制并锁定手动模式，直到降温。基础上限默认 100°C，硬上限 105°C；Apple Silicon 的 `Tp*` 热点传感器在普通负载下可能高于板载/外壳/邻近传感器，因此单独允许到 110°C。护栏**不可关闭**，温度读不到同样视为不安全。
- **写入校验。** 每次 SMC 写入都会回读验证（带沉降窗口，兼容异步生效的固件）——失败会如实报错，绝不静默装作成功。
- **优雅降级。** 如果 macOS 更新改变了 SMC 行为，受影响的功能会降级为只读并明确提示，而不是假装还能工作。

## 隐私

daemon 仅在以下情况下发起对外网络请求，且都由你掌控：

1. **更新检查**——每天一次查询 GitHub releases API 获取最新版本号，由 CLI 提示你升级。默认开启，可用 `[update] check = false` 关闭。
2. **告警 webhook**——只发往*你自己*在 `[[alert]]` 规则里配置的 URL。不配告警（默认）就没有这类请求。
3. **Sentry 崩溃/错误上报**——只有当你在 `[sentry]` 里配置 DSN 时才启用。默认空 DSN 会让 SDK 完全不启动。smctl 设置 `sendDefaultPii = false`，也不会启用性能追踪，除非你显式配置 `traces_sample_rate`。

无产品分析。CLI 本身从不发起网络请求——所有对外流量都来自 daemon 的上述可开关情况。完全离线：在 `/etc/smctl/config.toml` 写入

```toml
[update]
check = false

[sentry]
dsn = ""
```

然后 `sudo smctl daemon restart`，并且不配置任何 webhook 告警。也可以用 `SMCTL_SENTRY_DISABLED=1` 在 daemon 进程层硬关闭 Sentry。

## 告警

daemon 为了温度护栏，本就每秒扫描所有温度传感器。告警规则挂在同一个循环上：条件满足时 daemon 执行一个动作——shell 命令、HTTP webhook 或一条日志。适合把 Mac mini 服务器接进 Prometheus/Gotify 等告警体系。

规则是 `/etc/smctl/config.toml` 里的声明式 TOML：

```toml
[[alert]]
name = "cpu-hot"
on = "temp"            # temp | guard | write-error
sensor = "Tp09"        # 传感器键，或 "any" 取最热的一个
above = 85             # ℃
for = 30               # 持续满足这么多秒才触发（去抖）
cooldown = 300         # 触发后静默这么多秒
resolve = true         # 条件恢复时再发一条
action = "webhook"     # webhook | exec | log
url = "http://gotify.lan/message?token=..."
```

`exec` 命令会同时拿到占位符（`{name}` `{kind}` `{trigger}` `{reason}` `{value}`）和 `SMCTL_ALERT_*` 环境变量。检视与验证：

```console
$ smctl alert list            # 规则定义、有效性、脱敏后的动作目标
$ smctl alert status          # 每条规则的状态 + 最近事件
$ smctl alert test cpu-hot    # 立即触发动作，验证 webhook/脚本是否通
```

`alert list` 在普通文本和 JSON 输出里都会隐藏 webhook query string 与 exec 参数，避免 `/etc/smctl/config.toml` 里的 token 通过只读状态 API 泄露。

> **安全提示**：`exec` 动作以 **root** 运行（daemon 是 root）。信任边界 = 能编辑 root 拥有的 `/etc/smctl/config.toml` 的人——与其它所有策略一致。命令只走 argv 数组（不经 shell），无命令注入面，但应把「能改配置」视同 root 权限。

## 支持的硬件

- **Apple Silicon Mac，macOS 14+**
- 风扇控制已在 **M4 Mac mini** 上完整验证（直写路径）。部分 MacBook 机型需要的诊断模式解锁路径已按公开研究实现，需要更多真机覆盖——[欢迎反馈](https://github.com/leaperone/smctl/issues)
- 充电控制使用与成熟工具相同的 SMC key（pre-Tahoe 与 macOS 26 两套 key 运行时自动探测）
- Intel Mac：暂不支持（传感器只读可用）

能力探测在运行时进行——硬件不支持的功能会明确告诉你不可用，而不是静默失败。

## 对比

| | smctl | macOS 自带 | AlDente | Macs Fan Control | stats |
|---|---|---|---|---|---|
| CLI / 可脚本化 | ✅ | — | — | — | — |
| 电池限充 | ✅ 自定义区间 | 固定 80% | ✅ | — | — |
| 风扇控制（Apple Silicon） | ✅ 曲线 | — | — | ✅ 仅 GUI | — |
| 声明式配置 | ✅ TOML | — | — | — | — |
| 开源 | ✅ MIT | — | — | — | ✅ |

## 路线图

- Homebrew tap → homebrew-core
- 热压制可见性（`smctl power`）
- `smctl battery calibrate` —— 计划中，待 MacBook 真机验证（校准必须在 daemon 内运行以避免与 maintain loop 打架，且需要真实电池硬件验证）
- 菜单栏 App（daemon 已经说 XPC，GUI 只是另一个客户端）

## 文档

- [架构与技术设计](design.md)
- [真机实测笔记：M4 Mac mini](field-notes-m4-mini.md)——含 SMC 异步写入等一手发现
- [项目调研与规划笔记](project-notes.zh-CN.md)

## 许可证

[MIT](../LICENSE)

## 免责声明

smctl 会写入 Mac 的系统管理控制器（SMC）。上述安全机制按保守原则设计，但使用风险自负——尤其是持续高负载下的手动风扇控制。
