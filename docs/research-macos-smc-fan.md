# macos-smc-fan 技术调研笔记（Apple Silicon 风扇解锁）

> 调研日期：2026-06-04。仓库：`agoodkind/macos-smc-fan`（MIT），Apple Silicon 风扇控制解锁的首个公开实现。
>
> 其研究方法：IDA Pro 反编译 `AppleSMC.kext`（~801 函数）与 `/usr/libexec/thermalmonitord`（~775 函数）的 arm64e stripped 二进制 + dtrace 运行时追踪。实测硬件：M1 Pro（`MacBookPro18,1`）、M4（`Mac16,6`）、M5（`Mac17,7`, macOS 26.4.1）。
>
> **核心前提：所有「解锁」知识来自逆向，未经 Apple 文档背书；M2/M3/Mac Studio/Mac Pro 未实测。**

## 1. Ftst 解锁序列的完整细节

### SMC key 全表（`Sources/SMCFanKit/FanKeys.swift`）

| Key 模板 | 类型 | 含义 |
|---|---|---|
| `FNum` | uint8 | 风扇数量 |
| `F%dAc` | float | 实际 RPM（只读） |
| `F%dTg` | float | 目标 RPM（**不受 min/max 约束**，可设 0 = 停转） |
| `F%dMn` | float | 推荐最小 RPM（仅指导值，非硬限制） |
| `F%dMx` | float | 推荐最大 RPM（仅指导值） |
| `F%dMd` / `F%dmd` | uint8 | 模式：`0=auto / 1=manual / 3=system`。**大小写随代际变化** |
| `Ftst` | uint8 | Force/Test 诊断标志（M5 上不存在） |

`%d` 为 0-based 风扇索引。

### 模式语义

- **0 = Auto**：系统管理，目标默认落到最小 RPM
- **1 = Manual**：用户通过 `F%dTg` 控制
- **2**：仅 T2/Legacy 出现的强制手动，Apple Silicon 未观察到
- **3 = System**：`AppleCLPC` 主动缓解态，**固件拒绝手动模式写入**（返回 `0x82 SmcBadCommand`）

关键洞察：**Mode 3 不是 daemon 主动「下发」的命令，而是 RTKit 固件在硬件控制器（AppleCLPC）处于缓解态时「上报」的状态**。daemon 只要在跑，硬件就报 3。

### 实际解锁序列（`FanControl.swift` → `unlockFanControlSync` / `enableManualMode`）

两阶段自发现策略：

1. **先直写**：`writeKey(modeKey, [1])`。成功即返回（M1、M5 实测走这条）。
2. **失败再回退 Ftst**（仅当探测到 `Ftst` 存在，否则抛 notFound）：
   - 写 `Ftst = 1`
   - 固定等待 0.5s
   - 重试循环：maxRetries=100、timeout=10s，每次失败 sleep 0.1s 后重试写 `modeKey=1`，直到成功或超时。
3. 解锁成功后写 `F%dTg` 设目标 RPM（4 字节小端 float）。

实测时序：写 `Ftst=1` 后读 `F0Md` 初始仍是 3，约 3–4 秒后转 0，重试 `F0Md=1` 通常 4–6 秒内成功。M4 Max 首个风扇解锁 ~5–6.5s，后续风扇切模式仅 ~20ms。

### 解锁后控制走哪些 key

风扇控制 = 模式 key（`F%dMd/md` = 1）+ 目标 key（`F%dTg` = RPM）。`Ftst` 本身不参与逐风扇控制，它只是**全局诊断闸门**，用来让 thermalmonitord「松手」。

## 2. thermalmonitord 拦截机制

### 它如何强制 System Mode

- `thermalmonitord` **不直接写 SMC key**。它通过 `IORegistryEntrySetCFProperty` 给 `AppleCLPC`（Closed Loop Power Controller）、`ApplePMGR` 写高层属性，下发「温度天花板/缓解目标」而非裸 RPM。
- 内部 `LifetimeServoController` 持续把 die 温度目标推给 `AppleCLPC`。只要它在推，硬件就处于缓解态、对外报 Mode 3，固件层拒绝手动模式写。

### 解锁如何绕过

写 `Ftst=1` 会**抑制 `LifetimeServoController` 断言温度目标**——reclaim 逻辑被挂起。`AppleCLPC` 在固件层先检查 `Ftst` 标志再决定是否强制 Mode 3。daemon 主循环照常跑（仍读传感器），只是不再覆盖风扇设置。

### 竞态 —— **存在，核心风险点**

- 只要 `Ftst≠1`，daemon 就会 reclaim。控制进程退出后**几秒内** `F0Md` 从 1 → 3。
- 轮询频率：空闲 ~4000ms，热负载下进 fast mode ~250ms。负载越高 reclaim 越快。
- **结论**：维持手动控制必须有**常驻特权进程持续保持 `Ftst=1`**，不是「设一次就完事」。

## 3. 代际差异（M1–M5）

| 代际 | 模式 key | Ftst | 解锁方式 | 实测 |
|---|---|---|---|---|
| **M1** Pro | `F%dMd`（大写） | 存在 | **直写即可**，无需 Ftst | ✅ |
| M2 | ? | ? | ? | ❌ 未测 |
| M3 | 疑似走 M4 路径（`AppleDieTempController`） | ? | ? | ❌ 未测 |
| **M4** Max | `F%dMd`（大写） | 存在 | Mode 3 默认锁，需 **Ftst 解锁回退** | ✅ |
| **M5** Max | `F%dmd`（**小写**） | **不存在**（读返回 `0x84 SmcNotFound`） | **直写即可** | ✅ |

### 「芯片→key 表」维护成本 —— **几乎为零，因为它运行时探测，不维护静态表**

这是该项目最值得借鉴的设计决策（`HardwareConfig.swift` → `detectHardwareKeys`）：

- 依次试小写/大写模式 key，谁能读到 size>0 用谁；
- 读 `Ftst`，能读到就标记可用。

配置只有两个字段：`modeKeyFormat`、`ftstAvailable`。**不查芯片型号表**——通过 readKey 探针自动适配。新代际只要不引入第三种命名，这套探测继续工作。这推翻了 README 初稿里「维护芯片→key 表是成本大头」的担忧（至少对风扇控制 key 而言；私有温度传感器 key 仍可能需要表）。

## 4. 安全与风险（最关键的一节）

### 诊断模式副作用

`Ftst=1` 期间 `thermalmonitord` **不主动管理散热**。手动把风扇设太低又跑重载有热损风险。原项目明确警告「可能损坏硬件 / 干扰 macOS 散热管理」。

### 恢复 auto 的正确方式（`SMCFanHelper.swift` → `smcSetFanAuto`）

1. 写目标风扇 `modeKey = 0`
2. **仅当没有其他风扇仍处于手动**且 `ftstAvailable` 时：先读 `Ftst`，**若当前为 1 才写 `Ftst=0`**（幂等保证）
3. 若还有别的风扇在手动，绝不重置 Ftst——**Ftst 是全局闸门，必须等「最后一个手动风扇」退出才关**
4. `Ftst=0` 后 daemon 重新接管，模式回 3

### 异常退出（crash）后风扇会怎样 —— 原项目标注「**未实测**」

- 场景：helper 在 `Ftst=1` 状态崩溃，没来得及清 0。原项目 Edge Cases 标为 Untested。
- 两道安全网（**推断，非实测**）：
  1. **Sleep/wake 重置**：RTKit 固件在睡眠状态转换时自动把 `Ftst` 清 0。一次睡眠唤醒即可脱离卡死的手动态；唤醒后手动控制丢失，需监听 `NSWorkspace.didWakeNotification` 重跑解锁。
  2. **固件级独立热保护**：基于 `AppleSMC` 内 `_claimSystemShutdownEvents` 等推断——即使 thermalmonitord 被杀，RTKit 固件大概率仍独立执行温度上限、降频、紧急关机。这是 Apple 敢暴露 Ftst 闸门的根本原因。
- 作者明确说「未通过在热负载下杀 daemon 来验证」。

> **smctl 设计输入**：绝不能假设固件兜底一定生效。常驻 helper 必须有崩溃保护——退出/信号处理里 best-effort 写 `Ftst=0` 并还原模式；考虑 watchdog/心跳，丢失心跳后主动恢复 auto。thermalmonitord 的 250ms reclaim 本身也是 Apple 设计的 crash recovery（进程崩了它会重新接管）——**「降级为系统控制」天然安全，这对 README 里的优雅降级设计是利好**。

## 5. 架构（XPC + 特权 helper）

```
smcfan (CLI, 非特权) ──XPC──► SMCFanHelper (root 特权 daemon) ──IOKit──► AppleSMC
```

- Swift 6.0，SPM 分层：`SMCKit`（IOKit 调用、80 字节 struct、格式转换）、`SMCFanKit`（key 常量、硬件探测、FanController、FanArbitrator）、`SMCFanProtocol`（XPC 协议）、`SMCFanXPCClient`、CLI、Helper、installer。
- 安装：`SMAppService` 系统级注册特权 daemon 到 `/Library/PrivilegedHelperTools/`。

### XPC 协议

`smcOpen / smcClose / smcReadKey / smcWriteKey / smcGetFanCount / smcGetFanInfo / smcSetFanRPM(_:rpm:priority:) / smcSetFanAuto(_:priority:) / smcEnumerateKeys / smcRegisterClient / smcGetOwnership`。RPM/Auto 带 `priority` 参数，配合 `FanArbitrator` 做多客户端仲裁（优先级 + TTL）。

### 权限模型

- **读写不对称在固件层**：读写同走 `IOServiceOpen`（connection type 0）+ `IOConnectCallStructMethod` selector 2。区别来自 SMC 每-key 属性字节：bit7=可读、bit6=可写、bit0=私有写。传感器 key 多为 `0x80`/`0x90`，风扇控制 key 为 `0xC0`/`0xC1`。
- **读**（cmd 5）：任意非特权进程可读，无需 root。
- **写**（cmd 6）：受限 key 非 root 返回 `kIOReturnNotPrivileged`；特权 helper 安装要求 **Developer ID 签名**（付费开发者账号，自签名无效）。

### XPC 安全校验 —— 当前实现偏弱（smctl 必须改进）

`shouldAcceptNewConnection` **无条件 return true**：没有校验调用方代码签名、entitlement 或 audit token。任何本地进程都能驱动 root helper 写风扇。

> smctl 应补上 `SecCodeCopyGuestWithAttributes` + audit token 校验调用方签名/Team ID。

### IOKit 通信细节（`Sources/SMCKit`）

- Service `AppleSMC`，connection type 0，selector 2，struct 80 字节。
- 命令：`9`=读 key info、`5`=读值、`6`=写值。
- 80 字节 `SMCParamStruct` 布局：`key@0`, `vers@4`, `pLimitData@8`, `keyInfo@28`（dataSize 在 offset 28）, `result@40`, `status@41`, `data8@42`（命令字节）, `data32@44`, `bytes@48-79`。**纯 Swift 即可，无需 C bridging**——注意用 `MemoryLayout.stride` 而非 `.size`（KeyInfo size=9/stride=12）。
- 数据格式：Legacy/Intel = `fpe2`（2 字节 14.2 定点，大端）；Apple Silicon = 4 字节 IEEE754 float 小端。跨平台需双格式检测。
- SMC 错误码：`0x82 SmcBadCommand`（Mode 3 拒绝手动写）、`0x84 SmcNotFound`（key 不存在，可用于探测）、`0x87 SmcKeySizeMismatch`（写 `F0Tg` 偶发但值仍生效）。

## 6. 可复用性评估（面向 smctl）

| 模块 | 复用价值 | 难度 | 说明 |
|---|---|---|---|
| research.md 知识本身（解锁序列、key 表、模式语义、reclaim 行为） | **极高** | — | MIT，可直接作设计依据；领域内唯一公开的 AS 逆向成果 |
| 运行时探测策略（探 key 大小写 + Ftst 存在性，不维护芯片表） | **极高** | 低 | 几十行逻辑，最该照抄 |
| 两阶段解锁（direct → Ftst 回退 + 0.5s/0.1s/10s 重试参数） | 高 | 低 | 参数即经验值 |
| 80 字节 SMCParamStruct + IOKit 调用 | 高 | 中 | Swift 平移；Rust 需 `#[repr(C)]` 精确对齐 + IOKit FFI，offset 逐字节核对 |
| fpe2 / float 双格式转换 | 高 | 低 | 纯算术 |
| XPC + 特权 helper（SMAppService） | 中 | **高** | Swift 原生顺；**Rust 做 XPC 极痛**（无成熟 binding，得写 Swift/ObjC 薄壳或 launchd + Unix socket 自造 IPC + 自做签名校验）→ **Rust 路线最大障碍** |
| FanArbitrator（多客户端优先级 + TTL 仲裁） | 中 | 中 | 单客户端场景可省 |
| crash 安全 / sleep-wake 恢复 | 高（安全关键） | 中 | 原项目 crash 兜底标 Untested，smctl 应做得更扎实 |

**结论**：核心 SMC 层独立重实现划算且难度可控。**特权/IPC 层强烈建议 Swift**（SMAppService + XPC + 签名校验生态成熟）；纯 Rust 路线的主要工程量在 IPC 与代码签名校验，且要从头补上原项目缺失的 XPC 调用方校验。

## 关键文件路径速查（macos-smc-fan 仓库内）

- `docs/research.md` — 完整逆向研究叙述
- `docs/testing.md` — M4/M5 实测数据
- `Sources/SMCFanKit/FanKeys.swift` — key 常量
- `Sources/SMCFanKit/HardwareConfig.swift` — `detectHardwareKeys` 运行时探测
- `Sources/SMCFanKit/FanControl.swift` — `unlockFanControlSync` / `enableManualMode` / `resetFanControl`
- `Sources/SMCFanKit/FanArbitrator.swift` — 优先级+TTL 仲裁
- `Sources/Helper/SMCFanHelper.swift` — XPC listener、Ftst reset 条件逻辑
- `Sources/Common/SMCProtocol.swift` — XPC 协议
- `Sources/SMCKit/SMCTypes.swift` / `SMCConnection.swift` — 80 字节 struct 与 IOKit 调用
