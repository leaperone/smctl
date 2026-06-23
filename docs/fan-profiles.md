# 风扇曲线教程

smctl 的风扇 profile 是 `/etc/smctl/config.toml` 里的 TOML 策略，由 root daemon `smctld` 执行。它适合两类场景：macOS 自己的自动风扇策略过于保守，机器已经明显发热但风扇还在低转；或者你在无头 Mac 上需要一条可复现、可审计、可回退的风扇曲线。

正确做法是新增一个独立 profile，例如 `cooler`。不要把它和系统 `auto` 混在一起。`auto` 保留为随时回退的系统控制模式，`cooler` 只负责你的自定义曲线。

## 先看真实机器

不要直接复制别人的曲线。先看当前机器在真实负载下的温度、功耗和风扇状态：

```console
$ smctl fan status
$ smctl sensors --watch
$ smctl power status
```

如果你装了 `jq`，可以用 JSON 输出抓一个更紧凑的摘要：

```console
$ smctl sensors --json | jq -r '
  {
    tp_max: ([.temperatures[] | select(.key | startswith("Tp")) | .celsius] | max),
    ts_max: ([.temperatures[] | select(.key | startswith("Ts")) | .celsius] | max),
    tg_max: ([.temperatures[] | select(.key | startswith("Tg")) | .celsius] | max),
    fan: .fans[0].actualRPM,
    target: .fans[0].targetRPM,
    mode: .fans[0].mode,
    power: ([.power[] | select(.key == "PDTR") | .value] | first)
  }
  | "tp=\(.tp_max | floor)C ts=\(.ts_max | floor)C tg=\(.tg_max | floor)C fan=\(.fan) target=\(.target) mode=\(.mode) power=\(.power | floor)W"
'
```

连续跑几次，或在你的真实工作负载下跑一小段时间。你要看的不是某一次尖峰，而是模式：哪些传感器先升温，哪些传感器一直高，风扇目标转速有没有跟上，`smctl power status` 里有没有热压制或 CPU 降频。

## 认识温度传感器

Apple 没有公开 SMC 温度 key 的稳定语义。下面的前缀只能当经验规则，不能当官方接口定义：

- `Tp*` 通常是热点类传感器。它们反应快，Apple Silicon 在负载下超过 100C 并不罕见。系统 auto 太保守时，`Tp*` 应该作为风扇曲线的主输入。
- `Ts*` 通常更接近结构、外壳或邻近温度。它们和“手摸着热不热”更相关，但反应慢。
- `Tg*` 的含义更依赖机型。它可以作为辅助观察信号，但要以当前机器的读数为准。

一个常见错误是只用 `Ts*` 和 `Tg*` 做曲线，因为这些数字看起来更接近人的体感温度。这样会漏掉根因：芯片热点已经很高，但外壳和板级温度还没来得及升高。结果是风扇还没拉起来，`Tp*` 已经触发安全护栏。smctl 会把风扇强制交回系统 auto，并把 profile 写回 `auto`。这是正确保护，不是误报。

设计冷却曲线时，先从你机器上最热、最稳定的 `Tp*` key 里选几个。`Ts*` 和 `Tg*` 更适合用来观察效果或配置告警，除非你已经确认它们在你的机器上足够早地反映热负载。

## profile 是怎么执行的

一个 `[[fan.curves]]` 就是一条命名曲线。名字不要叫 `auto`、`quiet` 或 `full`：

- `auto` 是系统控制模式，不是自定义曲线。
- `quiet` 和 `full` 已经是 smctl 的内置 profile 名。
- 自定义曲线建议用明确名字，例如 `cooler`、`server` 或 `render`。

示例：

```toml
[[fan.curves]]
name = "cooler"
sensors = ["Tp3P", "Tp0E", "Tp06"]
points = [[75, 1000], [85, 1600], [95, 2600], [105, 4200], [110, "max"]]
hysteresis = 2
slew_rate = 800
```

daemon 每秒执行一次曲线：

1. 读取所有可用温度传感器。
2. 从 `sensors` 列表里选择本次曲线要看的传感器。
3. 如果 `sensors` 为空，就使用全部可读温度传感器。
4. 如果没有配置 `weights`，就取所选传感器里的最高温。冷却 profile 应该优先用这个默认逻辑。
5. 如果配置了 `weights`，就按权重算加权平均。只有正权重会生效。
6. 用 `points` 做线性插值，得到目标 RPM。
7. daemon 会把目标 RPM 限制在风扇上报的最小/最大转速内。`"max"` 会展开成每个风扇自己的最大转速。
8. `hysteresis` 控制温度死区，避免风扇在临界点来回抖动。
9. `slew_rate` 控制每秒最大 RPM 变化，避免转速突然跳变。

曲线启用后，`smctl fan status` 里风扇模式会显示 `manual`。这是正常现象。曲线本质上是 daemon 托管的手动目标转速，不是一次性的 `smctl fan set`。

## 推荐的 `cooler` profile

下面这条曲线适合这种机器：系统 auto 让风扇长期接近最低转速，但 `Tp*` 热点已经比较高。你必须先用 `smctl sensors` 确认这些 sensor key 在自己的机器上存在；不存在就换成你机器上实际出现的热点 key。

```toml
[fan]
profile = "cooler"

[[fan.curves]]
name = "cooler"
sensors = ["Tp3P", "Tp0E", "Tp06", "Tp02", "Tp09", "Tp05", "Tp01"]
points = [[75, 1000], [85, 1600], [95, 2600], [105, 4200], [110, "max"]]
hysteresis = 2
slew_rate = 800
```

这些点的含义：

- `75C -> 1000 RPM`：芯片只是偏热时保持最低转速，不制造无意义噪音。
- `85C -> 1600 RPM`：热点开始明显升高时提前介入。
- `95C -> 2600 RPM`：持续负载下开始真正带走热量，但不直接拉满。
- `105C -> 4200 RPM`：接近热点高位时快速加强冷却。
- `110C -> max`：接近热点硬上限时不再保留余量。
- `hysteresis = 2`：温度小幅波动时不频繁调整目标转速。
- `slew_rate = 800`：允许风扇足够快地跟上热点变化，但不会瞬间大跳。

保留原有 `[safety]`。不要通过提高安全阈值来掩盖曲线太慢的问题。根本方案是更早从正确传感器提速，让安全护栏只做最后兜底。

```toml
[safety]
temp_ceiling = 100.0
allow_below_minimum = false
```

`allow_below_minimum` 是给 `smctl fan set --force` 这类低于风扇最低转速的实验用的。冷却 profile 不应该依赖它。

## 写入和启用

编辑 `/etc/smctl/config.toml` 需要 root 权限。把 `cooler` profile 加进去时，保留现有 `[battery]`、`[safety]`、`[update]`、`[sentry]` 和 `[[alert]]` 配置。

手动改完文件后，重启 daemon 让它重新读取 TOML：

```console
$ sudo smctl daemon restart
```

当前 CLI 暂时没有公开 `daemon reload` 命令，所以手改配置后要重启 daemon。daemon 重启会先把硬件交回安全默认状态，再按新配置启动。

然后验证：

```console
$ smctl fan status
Fans
  profile: cooler
  Fan 0: actual 2355 RPM, target 2358 RPM, min 1000 RPM, max 4900 RPM, mode manual
```

如果曲线已经存在，只是切换 profile，可以直接用 CLI：

```console
$ smctl fan profile cooler
$ smctl fan profile auto
```

`auto` 会把风扇交回系统控制，并把配置持久化回 `auto`。

## 验证曲线是否正常

先看三个点：profile 名、目标转速、热点温度。

```console
$ smctl fan status
$ smctl power status
```

再跑一个短采样：

```console
$ for i in {1..10}; do
    smctl sensors --json | jq -r '
      {
        tp_max: ([.temperatures[] | select(.key | startswith("Tp")) | .celsius] | max),
        ts_max: ([.temperatures[] | select(.key | startswith("Ts")) | .celsius] | max),
        tg_max: ([.temperatures[] | select(.key | startswith("Tg")) | .celsius] | max),
        fan: .fans[0].actualRPM,
        target: .fans[0].targetRPM,
        mode: .fans[0].mode,
        power: ([.power[] | select(.key == "PDTR") | .value] | first)
      }
      | "tp=\(.tp_max | floor)C ts=\(.ts_max | floor)C tg=\(.tg_max | floor)C fan=\(.fan) target=\(.target) mode=\(.mode) power=\(.power | floor)W"
    '
    sleep 1
  done
```

正常启用后的输出类似这样：

```text
tp=92C ts=67C tg=66C fan=2357 target=2358 mode=manual power=29W
```

这里的 `mode=manual` 是预期结果。只要 `profile: cooler` 还在，说明 daemon 正在按曲线托管风扇。

## 排障

### profile 自动变回 `auto`

这通常是安全护栏触发了。先查日志：

```console
$ smctl daemon logs --last 5m | grep 'Fan safety'
```

常见根因：

- 曲线只看了较慢的 `Ts*` 或 `Tg*`，热点已经过高，风扇还没来得及拉起来。
- `sensors = [...]` 里的 key 在当前机器上不存在。
- 机器启用 profile 前已经接近或超过热点硬上限。
- 手动风扇控制期间温度传感器不可读。

根本修法是把曲线输入改成当前机器上最热、最有用的 `Tp*`，并让曲线更早提速。不要先调高安全阈值。

### 目标转速一直接近最低值

先确认传感器名：

```console
$ smctl sensors --json | jq -r '.temperatures[] | "\(.key) \(.celsius)"'
```

如果 `sensors = [...]` 里的 key 没出现在输出里，曲线就没有有效输入。换成你机器真实存在的 key。

如果 key 存在但目标转速仍然太低，说明你的曲线点太晚。降低中段温度点，或者提高中段 RPM。不要用固定 `fan set` 长期顶着跑；那会丢掉曲线和安全策略的意义。

### 风扇太吵

不要换一整套复杂曲线。保留同一批传感器，把中段略微上移或降低中段 RPM。例如把 `[95, 2600]` 改成 `[97, 2300]`。高温段仍然要保守一些，让安全护栏不需要承担日常冷却工作。

### 机器还是热

反过来做：更早拉转速。例如把 `[95, 2600]` 改成 `[92, 2800]`。如果某个 `Tp*` 明显比你当前列表里的传感器更热，把它加入 `sensors`。

### daemon 报 config parse error

看 daemon 状态：

```console
$ smctl daemon status
```

TOML 很严格。最常见错误是把 `max` 写成裸字；这里必须写成 TOML 字符串 `"max"`。另一个常见错误是 `points` 里的数组少逗号。

## 保持简单

风扇曲线的根本目标很简单：看对传感器，更早降温。不要写很多细碎点，不要用脚本动态改配置，不要长期固定 RPM。五个点、一组真实热点传感器、一个明确 profile，加上 smctl 自带安全护栏，通常就够了。
