# 显示器控制调研

> 调研日期：2026-06-24。目标不是复刻 BetterDisplay，而是判断 `smctl` 作为 System Control 工具，是否应该扩展到外接显示器硬件控制与诊断。结论以官方文档、项目 README、wiki 和公开源码仓库为准。

## 0. 一句话结论

值得做，但边界要收紧。

`smctl` 不应该做一个 BetterDisplay 克隆。BetterDisplay 已经覆盖 HiDPI 缩放、虚拟屏、XDR/HDR 增亮、PIP/串流、EDID override、断开/重连显示器、色彩模式、布局保护等很宽的桌面体验面。`smctl` 的机会在另一层：**外接显示器硬件控制 + 可脚本化诊断**。

更准确的产品定义：

- 用 CLI 列出 Mac 看到的所有显示器，并给出稳定身份。
- 探测显示器是否支持 DDC/CI，以及支持哪些 MCCS/VCP 控制项。
- 安全地控制外接显示器的硬件亮度、对比度、音量和输入源。
- 给出 `doctor` 诊断，让用户知道问题在端口、线材、转接坞、DisplayLink、电视 DDC 支持，还是显示器 MCCS 实现不标准。

这和 `smctl` 现有定位一致：它不是“优化大师”，而是把 macOS 不愿暴露的硬件控制面做成可审计、可回退、可脚本化的系统工具。

## 1. 用户问题是什么

外接显示器在 macOS 上有三个长期痛点：

1. macOS 对第三方外接显示器的硬件控制很弱。亮度键、音量键、输入源切换、硬件对比度通常不走系统统一面板。
2. 多机共用一台显示器时，输入源切换非常频繁。用户希望用命令把显示器切到 `hdmi1`、`dp1` 或 `usb-c`，而不是摸显示器背后的按键。
3. 问题排查缺少真相源。用户看见“不能调亮度”时，不知道是显示器没开 DDC/CI、HDMI 端口不支持、转接坞拦了 DDC、DisplayLink 限制、电视不支持 DDC，还是工具没有识别出显示器。

这些痛点比“做一个菜单栏 App”更底层。GUI 可以后置，CLI 和诊断先行更符合 `smctl`。

## 2. 竞品和参考项目

### BetterDisplay

[BetterDisplay](https://betterdisplay.pro/) 是最完整的参照物，但它不是 `smctl` 应该直接复制的产品。官方页面和仓库描述覆盖了 flexible HiDPI scaling、XDR/HDR extra brightness、virtual screens、DDC control、extra dimming、PIP/streaming、EDID override 等能力。

它的 [Integration features, CLI](https://github.com/waydabber/BetterDisplay/wiki/Integration-features%2C-CLI) wiki 说明了它有多种集成方式：命令行、自定义 URL scheme、HTTP、通知、Shortcuts。CLI 层支持 `brightness`、`hardwareBrightness`、`softwareBrightness`、`volume`、`hardwareContrast`、`ddc`、`ddcAlt`、`rotation`、`resolution`、`refreshRate`、`placement`、`hdr`、`customEDID`、`EDIDReport`、`rawDPCD`、`DPCDReport`、`CECReport` 等参数。

对 `smctl` 的启示：

- CLI 和自动化需求真实存在。
- DDC 直通能力很有价值，尤其是亮度、输入源、音量、对比度。
- BetterDisplay 的范围过宽。`smctl` 第一阶段不应该碰虚拟屏、PIP、HDR/XDR 增亮、自定义 EDID、布局保护和 GUI 设置面。

### MonitorControl

[MonitorControl](https://github.com/MonitorControl/MonitorControl) 的核心价值很明确：控制外接显示器亮度和音量，并显示原生 OSD。它支持外接显示器 DDC、Apple/内置显示器原生协议、Gamma table 控制，以及对 AirPlay、Sidecar、DisplayLink、虚拟屏等场景的 shade/overlay fallback。

它的 README 同时给了一个重要边界：大多数现代 LCD 可以通过 USB-C、DisplayPort、HDMI、DVI、VGA 走 DDC/CI；但电视、DisplayLink、部分 Mac 的内置 HDMI、部分 Apple Silicon 组合会有例外。

对 `smctl` 的启示：

- DDC 成功率取决于显示器、连接方式和 Mac 端口，不应该把失败写成泛泛的 “not supported”。
- 软件调暗可以做 fallback，但它不是硬件控制。`smctl` 应该把硬件 DDC 和软件 dimming 分清楚。
- 诊断信息比单纯的 slider 更适合 CLI。

### Lunar

[Lunar](https://github.com/alin23/Lunar) 和 [lunar.fyi](https://lunar.fyi/) 都强调一件事：如果显示器支持 DDC/CI，它会改变硬件亮度，而不是用黑色遮罩模拟变暗。Lunar 也把输入源切换列为核心能力，官方页面直接把 `set brightness to 30%` 和 `switch input to HDMI 2` 作为 DDC 示例。

对 `smctl` 的启示：

- 输入源切换不是边缘功能。它是外接显示器“系统控制”的核心用例。
- “硬件亮度”和“软件遮罩”必须在输出里明确标注。用户关心颜色准确性、背光、功耗和显示器真实状态。

### m1ddc

[m1ddc](https://github.com/waydabber/m1ddc) 是一个很小的 Apple Silicon DDC/CI CLI。它适合脚本，也明确列出限制：不支持 M1 和入门款 M2 Mac 的内置 HDMI 端口，不支持 Intel Mac；更完整的方案建议看 BetterDisplay。

它的命令面覆盖：

- 亮度、对比度、RGB gain、音量、输入源的 set/get/change。
- 显示器列表。
- 多种显示器识别方式，例如 id、uuid、edid、seid、basic、ext、full。

对 `smctl` 的启示：

- `smctl display` 第一版可以从小 CLI 做起，不需要 GUI。
- 显示器身份不能只用名字。名字会重复，用户也会改。需要组合 `uuid`、EDID hash、vendor/model/serial、IORegistry 位置等信息。
- 输入源值需要别名。常见值如 DP1、DP2、HDMI1、HDMI2、USB-C 可以有默认映射，但必须允许显示器级 override，因为不同厂商会用不同编码。

### AppleSiliconDDC

[AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC) 是 Swift DDC library + CLI。CLI 命令包括 `detect`、`getvcp`、`setvcp`、`capabilities`。

它的 README 提醒了一个关键点：库只处理 DDC/CI 协议传输，不负责完整解释 MCCS 命令集；有些显示器只部分遵守 MCCS，读写验证可能需要单项验证或关闭验证。

对 `smctl` 的启示：

- DDC 传输成功不等于显示器的 MCCS 语义可靠。
- `set` 后尽量回读验证，但要把“不可靠回读”作为可表达状态，而不是一律视为失败。
- `doctor` 要报告 VCP 能力、读写结果、验证策略和异常字节，而不是只显示成功/失败。

### ddcutil

[ddcutil](https://www.ddcutil.com/commands/) 是 Linux 上成熟的 DDC/CI 工具。它的命令模型很值得参考：`detect`、`capabilities`、`getvcp`、`setvcp`、`vcpinfo`。它证明了“命令行 + 能力探测 + VCP 读写”是一条成熟产品路径。

`smctl` 不需要移植 ddcutil，但可以借鉴它的层次：先找显示器，再读 capabilities，再解释 VCP，再写入。

## 3. macOS 能力层

### CoreGraphics / Quartz Display Services

Apple 的 [Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services) 是公开 API 层。它可以访问 macOS Window Server 公开的显示器能力，例如列出活动显示器、读取和切换显示模式、配置镜像、gamma table、捕获显示器、监听屏幕更新等。

相关 API：

- [`CGGetActiveDisplayList`](https://developer.apple.com/documentation/coregraphics/cggetactivedisplaylist%28_%3A_%3A_%3A%29)：列出当前可绘制的 active displays。
- [`CGGetOnlineDisplayList`](https://developer.apple.com/documentation/coregraphics/cggetonlinedisplaylist%28_%3A_%3A_%3A%29)：列出 online displays，包含 active、mirrored 或 sleeping displays。
- [`CGDisplayCopyAllDisplayModes`](https://developer.apple.com/documentation/coregraphics/cgdisplaycopyalldisplaymodes%28_%3A_%3A%29)：读取显示器可用模式。
- [`CGDisplaySetDisplayMode`](https://developer.apple.com/documentation/coregraphics/cgdisplaysetdisplaymode%28_%3A_%3A_%3A%29)：同步切换显示模式。

这一层适合做：

- `display list` 的系统可见显示器列表。
- 分辨率、刷新率、rotation、mirroring、bounds、是否 main display 等只读状态。
- gamma table 级软件 dimming 的 fallback 评估。

这一层不适合直接做：

- 外接显示器硬件背光。
- 输入源切换。
- OSD 菜单里的硬件对比度、音量、色彩增益。

这些属于显示器硬件自己的 DDC/CI 控制面。

### IOKit / IODisplay

IOKit / IODisplay 能补齐显示器身份。`smctl display list` 需要的不只是 `CGDirectDisplayID`，还需要尽可能稳定的硬件指纹：vendor、product、serial、EDID、连接路径、transport、是否内置、是否镜像、是否 online。

这一层适合做：

- EDID 读取和 hash。
- 厂商、型号、序列号解析。
- IORegistry 路径和连接位置。
- 与 CoreGraphics display ID 的关联。

这一层决定用户能否写出稳定脚本。例如：

```console
$ smctl display brightness set 60 --display dell-u2723qe
```

如果只按显示器名字匹配，两个同型号显示器会撞。正确做法是暴露多个身份字段，并让 CLI 支持明确选择。

### DDC/CI + MCCS

DDC/CI 是外接显示器硬件控制的核心。MCCS/VCP 定义了常见控制项。典型 VCP 包括：

| 能力 | 常见语义 | 第一版建议 |
|---|---|---|
| `0x10` | luminance / brightness | 做 |
| `0x12` | contrast | 做 |
| `0x62` | audio speaker volume | 做 |
| `0x60` | input select | 做 |
| `0xD6` | power mode | 只读或延后 |
| RGB gain | 色彩增益 | 延后 |
| capabilities string | 支持项声明 | 只读必须做 |

DDC 的难点不是命令本身，而是边界：

- 有些显示器需要在 OSD 里开启 DDC/CI。
- 有些转接坞或线材不转发 DDC。
- DisplayLink 在 macOS 上经常走软件显示路径，不能假设有硬件 DDC。
- 电视通常不完整支持 DDC。
- 同一个 VCP 在不同显示器上取值范围可能不同。
- 输入源编码不完全统一。LG 等厂商可能需要 alternate addressing 或特殊值。
- 一些显示器 `set` 生效，但 `get` 回读不可靠。

这说明 `smctl display` 的第一能力不应该是“写亮度”，而应该是“解释为什么能写或不能写”。

### 私有 / 易碎层

BetterDisplay 里的很多能力明显碰到了更私有、更易碎的 macOS 显示栈，例如 CoreDisplay、DisplayServices、HDR/XDR、颜色模式、原生/默认分辨率编辑、自定义 EDID、软断开、虚拟屏等。

这些不是 `smctl display` 第一阶段该碰的范围。原因很直接：

- 它们离 `smctl` 的硬件控制定位更远。
- 它们容易和系统显示设置、Window Server、显示器排列、色彩配置发生复杂交互。
- 一旦写坏，用户体验损伤比调亮度大得多。
- BetterDisplay 已经是这个方向的强工具，`smctl` 没必要从最难的面切入。

### 软件调暗层

Gamma table 或 overlay 可以让屏幕“看起来更暗”，但它不是硬件亮度控制。它不会改变外接显示器背光，也不能解决输入源、音量、对比度这类硬件状态。

`smctl` 可以把它作为后备能力写进诊断结果，但不应该把它包装成 `hardwareBrightness`。如果将来做软件 dimming，命令输出必须明确显示：

```text
brightness: 40% (software fallback, hardware DDC unavailable)
```

## 4. 建议的产品范围

### V0：只读调研面

第一步只做 inventory 和 diagnosis，不做写入。这样可以快速建立真实硬件样本，也不会引入“写坏显示器状态”的风险。

建议命令：

```console
$ smctl display list --json
$ smctl display status
$ smctl display edid --display <id>
$ smctl display capabilities --display <id>
$ smctl display doctor
```

`display list --json` 应输出：

- `id`：`smctl` 自己生成的稳定短 ID。
- `name`：系统显示名。
- `vendor` / `model` / `serial`：从 EDID 或 IODisplay 来。
- `edidHash`：脚本最可靠的身份之一。
- `cgDisplayID`：CoreGraphics ID，仅作为运行时字段。
- `online` / `active` / `main` / `mirrored`。
- `bounds` / `scale` / `refreshRate` / `rotation`。
- `transport`：能识别时标注 HDMI、DisplayPort、USB-C、DisplayLink、AirPlay、Sidecar 等。
- `ddc`：`unknown`、`supported`、`unsupported`、`blocked`、`unverified`。

`display doctor` 应输出面向用户的根因提示：

- 显示器是内置屏：不走 DDC。
- 显示器是 DisplayLink/AirPlay/Sidecar：硬件 DDC 很可能不可用。
- 未读到 EDID：身份不稳定，先检查连接链路。
- DDC capabilities 读取失败：检查显示器 OSD 是否开启 DDC/CI，换直连线，绕过转接坞。
- capabilities 有亮度但 `getvcp 0x10` 失败：标成 `broken-read`，不要直接误判为不支持。

### V1：安全硬件控制

第二步再做低风险写入。建议只做外接显示器的硬件控制，不做系统显示模式写入。

建议命令：

```console
$ smctl display brightness get --display <id>
$ smctl display brightness set 60 --display <id>
$ smctl display contrast get --display <id>
$ smctl display contrast set 55 --display <id>
$ smctl display volume get --display <id>
$ smctl display volume set 20 --display <id>
$ smctl display input list --display <id>
$ smctl display input set hdmi1 --display <id>
```

写入原则：

- 写前先确认 display identity，避免名字撞车。
- 写前先确认 capabilities，除非用户显式 `--force-vcp`。
- 写后尽量回读验证。
- 回读失败时区分 `write-failed`、`write-sent-unverified`、`write-succeeded-verified`。
- 输入源切换前打印目标 VCP 值，`--json` 里保留原始值。
- 所有百分比都要映射到显示器实际 max，不假设一定是 0-100。

### V2：谨慎扩展

这些能力有价值，但不适合作为第一阶段：

- `display power off/on`：可能导致用户失去画面，且唤回路径依赖显示器。
- `display mode set`：分辨率、刷新率、HDR、rotation 写入会影响系统桌面状态。
- PIP/PBP/KVM：厂商差异太大，标准化困难。
- CEC：链路复杂，电视和显示器行为差异大。
- RGB gain / color preset：容易影响色彩工作流，且不同厂商语义差异明显。
- custom EDID / EDID override：高风险，第一阶段不做。
- virtual displays：偏桌面体验，不是 `smctl` 的核心。

## 5. 建议命令面

完整命令面可以这样收敛：

```console
$ smctl display list [--json]
$ smctl display status [--display <id>] [--json]
$ smctl display doctor [--display <id>] [--json]

$ smctl display edid --display <id> [--json|--raw]
$ smctl display capabilities --display <id> [--json|--raw]

$ smctl display brightness get --display <id> [--json]
$ smctl display brightness set <percent> --display <id> [--no-verify]

$ smctl display contrast get --display <id> [--json]
$ smctl display contrast set <percent> --display <id> [--no-verify]

$ smctl display volume get --display <id> [--json]
$ smctl display volume set <percent> --display <id> [--no-verify]

$ smctl display input list --display <id> [--json]
$ smctl display input get --display <id> [--json]
$ smctl display input set <name|vcp-value> --display <id> [--no-verify]
```

不要把 `display brightness set 60` 默认作用于“当前主显示器”。多显示器场景太容易误伤。可以支持 `--display main`，但交互输出要明确显示命中的显示器。

## 6. 配置模型

输入源别名和显示器身份应该放进 `/etc/smctl/config.toml` 或未来的 per-user 配置里。第一版可以只读，第二版再引入别名。

示例：

```toml
[[display.aliases]]
name = "desk-left"
edid_hash = "sha256:..."

[display.aliases.inputs]
dp1 = 15
dp2 = 16
hdmi1 = 17
hdmi2 = 18
usb_c = 27
```

为什么需要配置：

- 两台同型号显示器会有同名问题。
- 有些显示器没有可靠序列号。
- 输入源编码不完全标准。
- 用户希望脚本读起来像 `desk-left hdmi1`，而不是 `display 7 vcp 0x60 value 17`。

## 7. 安全和降级原则

`smctl` 现有风扇和电池功能已经有一个清晰原则：写硬件前先探测，写完验证，失败就明确降级。显示器控制也应沿用这套精神。

具体原则：

- **能力探测优先**：先读 display inventory、EDID、DDC capabilities，再决定是否暴露写命令。
- **没有静默写入**：写失败必须报错；回读不可靠也要显式标注。
- **不伪装 fallback**：软件 dimming 不叫硬件亮度。
- **不默认高风险写**：custom EDID、display mode、HDR/XDR、power off 不进第一阶段。
- **身份必须稳定**：CLI 写入不能只靠显示器名称。
- **端口限制要讲清楚**：尤其是 Apple Silicon 上内置 HDMI、DisplayLink、转接坞、电视 DDC 支持。
- **JSON 输出保留原始事实**：包括 VCP code、raw value、max value、capabilities string、transport、验证结果。

## 8. 实现路线建议

第一阶段实现时，不要先追求“所有显示器都能调亮度”。根本路径应该是：

1. 建立 `DisplayCore` 或同等模块，读取 CoreGraphics + IOKit inventory。
2. 给每台显示器生成稳定身份和 JSON 输出。
3. 接入 DDC 探测，只读 capabilities 和少量 VCP。
4. 做 `display doctor`，把失败原因分类。
5. 收集真实用户硬件样本。
6. 再开放 brightness/contrast/volume/input 写入。

实现层可以参考 AppleSiliconDDC 和 m1ddc 的 DDC 通路，但必须注意 license 和 API 边界。两者是 MIT，可学习结构；最终代码仍应按 `smctl` 的 Swift 模块风格重写，和现有 XPC/daemon 边界对齐。

是否需要 daemon 介入，要单独设计：

- 只读 inventory 和 DDC 探测可能可以由 CLI 直接做。
- 如果未来要做长期同步、多显示器策略、输入源自动切换、告警联动，就应该由 daemon 托管。
- 如果 DDC 写入不需要 root，CLI 直连会更简单；但 `smctl` 的统一策略面可能仍然需要 daemon 作为控制中心。

第一版可以允许 CLI 直接只读，设计上保留 daemon 接管的接口。

## 9. 设计问题清单

后续 design issue 应先回答这些问题：

- `smctl display` 是否 Apple Silicon first，还是同时考虑 Intel？
- DDC transport 在 Swift 里用哪条路径最稳？是否直接参考 AppleSiliconDDC 的 IOKit 方式？
- 显示器 identity 的优先级是什么？`edidHash`、serial、vendor/model、IORegistry path、CGDirectDisplayID 如何组合？
- 内置屏、Apple Studio Display、LG UltraFine 这类走 Apple/native protocol 的显示器怎么标注？
- DDC capabilities 读取失败时，如何区分 `unsupported`、`blocked`、`timeout`、`broken-read`？
- 输入源别名如何配置？默认值来自 MCCS，还是维护一组显示器/厂商 override？
- 写入验证失败但显示器确实生效时，CLI 默认报错还是 warning？
- `--no-verify` 是否允许；如果允许，输出应该如何让脚本知道状态不确定？
- daemon 和 CLI 谁拥有 DDC 写权限？未来 GUI 是否必须走 daemon？
- 是否需要采集匿名硬件兼容报告？如果做，必须沿用项目现有隐私原则，默认关闭。

## 10. 推荐结论

可以进入设计阶段，但第一张 issue 的标题应该是“display control surface”，不是“BetterDisplay clone”。

根本方案：先做 **read-only inventory + DDC capability probe + doctor**。这一层能让 `smctl` 建立显示器控制的事实基础，也能帮后续写入避开最危险的坑。等真实硬件矩阵清楚后，再做 `brightness`、`contrast`、`volume`、`input` 四类安全写入。

明确不做：虚拟屏、PIP、GUI、custom EDID、HDR/XDR 增亮、系统显示模式写入。它们可以留给 BetterDisplay。`smctl` 应该把自己守在 System Control：硬件状态、硬件控制、可脚本化诊断。

## 主要来源

- [BetterDisplay 官方网站](https://betterdisplay.pro/)
- [BetterDisplay GitHub 仓库](https://github.com/waydabber/BetterDisplay)
- [BetterDisplay Integration features, CLI wiki](https://github.com/waydabber/BetterDisplay/wiki/Integration-features%2C-CLI)
- [BetterDisplay free / Pro feature list](https://github.com/waydabber/BetterDisplay/wiki/List-of-free-and-Pro-features)
- [MonitorControl README](https://github.com/MonitorControl/MonitorControl)
- [Lunar README](https://github.com/alin23/Lunar)
- [Lunar 官方网站](https://lunar.fyi/)
- [m1ddc README](https://github.com/waydabber/m1ddc)
- [AppleSiliconDDC README](https://github.com/waydabber/AppleSiliconDDC)
- [ddcutil command overview](https://www.ddcutil.com/commands/)
- [Apple Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services)
- [Apple CGGetActiveDisplayList](https://developer.apple.com/documentation/coregraphics/cggetactivedisplaylist%28_%3A_%3A_%3A%29)
- [Apple CGGetOnlineDisplayList](https://developer.apple.com/documentation/coregraphics/cggetonlinedisplaylist%28_%3A_%3A_%3A%29)
- [Apple CGDisplayCopyAllDisplayModes](https://developer.apple.com/documentation/coregraphics/cgdisplaycopyalldisplaymodes%28_%3A_%3A%29)
- [Apple CGDisplaySetDisplayMode](https://developer.apple.com/documentation/coregraphics/cgdisplaysetdisplaymode%28_%3A_%3A_%3A%29)
