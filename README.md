# HeartRateLockWidget

macOS 状态栏工具 + 桌面/侧边小组件，绑定 BLE 心率设备（如华为手表）并订阅心率，心率丢失或设备信号变弱（人走远）时自动锁定屏幕。

## 为什么用心率？三体里的"摇篮系统"

市面上已有一些基于蓝牙信号强度（RSSI）的锁屏方案，比如 [BLEUnlock](https://github.com/ts1/BLEUnlock)，它通过扫描随身 BLE 设备的信号强弱来判断人是否离开。这个思路简单，但本质问题是：**它只判断"设备在不在附近"，不判断"人还在不在"**。设备放在桌上充电、身体遮挡、或者办公区蓝牙干扰，都可能导致误触发。

这个项目的核心区别是：**用心率这种"生命体征"来做存在判定**。心率是只有戴在活人手腕上才会持续产生的信号——心跳在，人就在；心跳中断，才意味着人真的走远或摘下手表。

这让我想到《三体》里的"摇篮系统"：

> 面壁者雷迪亚兹为了实施水星核弹威慑计划，佩戴了一块实时监测心跳、血压、体温的黑色腕表，并持续向外发送抑制信号。只要他活着，信号就不停；一旦他死亡或失去生命体征，信号中断，水星氢弹就会引爆，导致水星坠入太阳，最终毁灭整个太阳系。
>
> - 手表持续发信号 = 摇篮不停摇晃 → 氢弹休眠、锁死；
> - 雷迪亚兹死亡 → 信号中断 = 摇篮停摇 → 氢弹瞬间全部引爆。

在四位面壁者中，**雷迪亚兹（2号）是唯一当众展示摇篮手表的人**。听证会上，他举起左手亮出这块表，威胁只要自己被杀，水星核弹就会毁灭全人类，各国代表只能放他返回委内瑞拉。

HeartRateLockWidget 就是一个微缩版的摇篮系统：Mac 持续监听我的心率广播，**心跳在，屏幕就亮着；心跳中断，屏幕立刻锁定**。只不过它威慑的不是三体人，而是我自己的安全意识。

## 项目结构

```
HeartRateLockWidget/
├── HeartRateLock/              # macOS 状态栏后台 App
│   ├── HeartRateLockApp.swift      # 应用入口（无 Dock 图标）、状态栏菜单、设置窗口
│   ├── BLEHeartRateManager.swift   # CoreBluetooth 扫描/绑定/连接/心率订阅/弱信号判定
│   └── LockScreenManager.swift     # 触发 macOS 锁屏
├── HeartRateWidget/            # 桌面/侧边小组件
│   ├── HeartRateWidget.swift       # Widget 视图 + 时间线刷新
│   └── HeartRateWidgetBundle.swift # Widget 入口
├── HeartRateLockShared/        # App 与 Widget 共享代码
│   └── SharedConfig.swift          # App Group、UserDefaults Key、设置项
├── project.yml                 # XcodeGen 项目模板
└── setup.sh                    # 一键配置脚本
```

## 核心逻辑

1. **扫描与绑定**
   - 后台 App 全量扫描周围 BLE 设备，状态栏菜单的「选择设备」实时列出（按信号强度排序）。
   - 用户点击设备完成绑定；绑定信息持久化，下次启动自动重连，掉线自动重试。
   - 连接后订阅标准心率服务 `0x180D` 的心率测量特征 `0x2A37`，并读取 GAP 设备名（`0x2A00`）校正显示名。
   - 把最新心率写入 **App Group 共享 UserDefaults**。

2. **自动锁屏（均可在设置中开关/调整）**
   - **心率超时**：超过 `timeoutSeconds`（默认 10 秒）未收到心率即视为丢失，锁屏。
   - **弱信号**：绑定设备 RSSI 连续 `weakSignalLockSeconds`（默认 3 秒）低于 `lockRSSIThreshold`（默认 -75 dBm），视为走远，锁屏。
   - 锁屏调用 `/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession -suspend`。

3. **小组件展示数据**
   - 从 App Group 读取心率，支持 `.systemSmall` / `.systemMedium`。
   - 时间线每秒请求刷新（实际刷新频率由系统调度决定）。

## 还加了哪些功能

### 空闲锁屏兜底

万一哪天没戴手表，应用还内置了键鼠空闲检测。通过 `CGEventSource.secondsSinceLastEventType` 读取键盘、鼠标最后一次活动时间，超过设定秒数也锁屏。这个兜底还可以设置只在指定时间段生效，比如只在工作时间开启。

### 开机自启

用 `SMAppService.mainApp.register()` 注册登录项，实现开机自动启动，不需要在「系统设置 > 通用 > 登录项」里手动添加。

### 设置面板

状态栏点击「设置…」可以调整：

- 信号弱锁屏阈值（-90 ~ -40 dBm）
- 连续弱信号秒数
- 心率超时秒数
- 键鼠空闲锁屏秒数及时段
- 开机自启开关

## 环境要求

- macOS 14.0+
- Xcode 15+（必须有完整 Xcode.app，Command Line Tools 不足以构建 Widget Extension）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：
  ```bash
  brew install xcodegen
  ```

## 快速开始

1. **克隆/复制项目**到本地。

2. **运行配置脚本**，输入你自己的 Bundle ID、Team ID 和 App Group：
   ```bash
   cd HeartRateLockWidget
   chmod +x setup.sh
   ./setup.sh
   ```
   示例输入：
   - Bundle ID 前缀：`com.yourname`
   - Team ID：`ABCD123456`（或回车留空，稍后 Xcode 里选）
   - App Group：`group.com.yourname.heartratelock`

3. **用 Xcode 打开生成的项目**：
   ```bash
   open HeartRateLockWidget.xcodeproj
   ```

4. **配置签名与 App Group**
   - 选中 `HeartRateLockWidget` 项目，分别进入 `HeartRateLock` 和 `HeartRateWidget` target。
   - 在 **Signing & Capabilities** 中选择你的 Apple ID / Team。
   - 确保 **App Groups** capability 已启用，且 Group ID 与脚本输入一致。
   - 如果 Team 是个人账号，需先在 [Apple Developer](https://developer.apple.com) 注册该 App Group。

5. **运行**
   - 先运行 `HeartRateLock` target，状态栏会出现 `♥ --` 图标。
   - 再运行 `HeartRateWidget` extension，系统会提示你把小组件添加到桌面/通知中心。

## 权限说明

首次运行会请求：

- **蓝牙权限**：扫描华为手表心率广播必需。
- **锁屏/辅助功能权限**：触发 `CGSession -suspend` 锁屏必需。如果系统提示，请在 **系统设置 > 隐私与安全性 > 辅助功能** 中允许 `HeartRateLock`。

## 绑定你的手表

状态栏菜单 →「选择设备」会实时列出周围 BLE 设备（按信号强度排序），点击即可绑定；「解除绑定」可重新选择。

注意：

- 手表的 MAC 地址（如 `B0:FE:E5:D2:3D:E1`）**无法用于过滤**，macOS 出于隐私只暴露随机生成的 `CBPeripheral.identifier`。
- 很多设备广播里不带名字（显示「未知设备」），把手表贴近 Mac，列表里信号最强的那个通常就是它；绑定后 App 会通过 GAP 服务读出真实设备名，便于确认。
- 设备必须支持标准 BLE 心率服务 `0x180D`。绑定后若日志提示「没有标准心率服务」，说明该设备不对外开放心率（部分华为手表型号如此，只走华为运动健康的私有协议）。

## 设置

状态栏菜单 →「设置…」可调整：

- **信号弱锁屏**：开关、RSSI 阈值（-90 ~ -40 dBm）、连续弱信号秒数。
- **心率超时锁屏**：开关、超时秒数。
- **键鼠空闲锁屏**：开关、空闲秒数、生效时段。
- **开机自启**：开关。

建议先戴着设备在正常位置观察菜单里显示的实时 RSSI，再走到期望触发锁屏的距离看一眼，把阈值设在两者之间。

## 还能怎么玩：真正的"摇篮系统"应该更进一步

现在的逻辑是"心率没了 → 锁屏"，这其实只是一个开始。如果你真想把它做成三体世界里那种"生命体征即威慑"的系统，可以基于这个开源方案继续加戏。

比如一个更严肃的状态组合：**手表明明还戴在手上，蓝牙信号也不弱，但心率突然停止了**。这意味着什么？大概率不是人走开了，而是心脏不跳了。这种情况下再锁屏就显得不够有仪式感，你可以触发一些更有"摇篮系统"味道的自动化：

- **自动提交代码**：检测到心率归零且信号正常，立刻执行 `git add -A && git commit -m "chore: 最后的提交" && git push`，确保代码不丢失，做一个负责任的程序员。
- **自动发消息**：给同事群发一条 Slack/飞书消息："我去参加黑暗森林战役了，需求下次迭代再说。"
- **删库但不跑路**：既然人都没了，服务器留着也没意义。可以设计一个"温柔删库"流程——先备份到对象存储，再清空数据库，最后注销所有云账号。真正做到"删库不跑路"，因为已经跑不动了。
- **触发遗嘱脚本**：打开提前写好的 `last_will.sh`，把比特币私钥、未完成的 side project、暗恋对象的名字一并分发出去。

当然，这些功能建议只作为彩蛋存在，默认不要开启。毕竟心脏停跳不一定是真的心脏停跳，也可能是手表没电了、蓝牙断流了，或者你只是把手表摘下来放在了桌上。真触发一次"自动提交代码"还可以接受，要是误触发"删库"，那你可能就要先一步去见雷迪亚兹了。

## 已知限制

- WidgetKit 无法常驻扫描蓝牙，心率刷新频率受系统调度限制；**实时性由后台 App 保证**，小组件只是显示层。
- 锁屏动作由后台 App 执行，不是小组件。
- 沙盒 App 调用 `CGSession -suspend` 在部分系统版本可能需要辅助功能权限。
