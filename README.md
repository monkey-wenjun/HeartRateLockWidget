# HeartRateLockWidget（不跳就锁）

macOS 状态栏工具 + 桌面小组件：绑定 BLE 心率设备（如华为手表）并订阅心率，心率丢失、设备信号变弱（人走远）或键鼠空闲时自动锁定屏幕。

## 项目结构

```
HeartRateLockWidget/
├── HeartRateLock/                  # macOS 状态栏后台 App（显示名：不跳就锁）
│   ├── HeartRateLockApp.swift          # 应用入口（无 Dock 图标）、状态栏菜单、设置/关于窗口、开机自启
│   ├── BLEHeartRateManager.swift       # CoreBluetooth 扫描/绑定/连接/心率订阅/弱信号与空闲判定
│   ├── LockScreenManager.swift         # 触发 macOS 锁屏 + 文件日志（~/Library/Logs/HeartRateLock.log）
│   └── KeepAwakeManager.swift          # IOKit 电源断言，手表在线时保持屏幕常亮
├── HeartRateWidget/                # 桌面/通知中心小组件（WidgetBundle 内含两个 Widget）
│   ├── HeartRateWidget.swift           # 「实时心率」：当前心率数值 + 更新时间
│   ├── HeartRateCurveWidget.swift      # 「心率曲线」：最近 15 分钟心率变化曲线
│   └── HeartRateWidgetBundle.swift     # Widget 入口
├── HeartRateLockShared/            # App 与 Widget 共享代码
│   └── SharedConfig.swift              # App Group、UserDefaults Key、设置项、跨进程共享存储
├── project.yml                     # XcodeGen 项目模板（含占位符）
├── setup.sh                        # 一键配置脚本（填入 Bundle ID / Team / App Group）
└── build.sh                        # 一键编译安装脚本（xcodegen + xcodebuild + 安装到 /Applications）
```

## 核心逻辑

1. **扫描与绑定**
   - 后台 App 全量扫描周围 BLE 设备，状态栏菜单的「选择设备」实时列出（按信号强度排序，15 秒未出现即移除）。
   - 用户点击设备完成绑定；绑定信息持久化，下次启动自动重连（`retrievePeripherals`），掉线自动重试，连不上则回到扫描。
   - 连接后订阅标准心率服务 `0x180D` 的心率测量特征 `0x2A37`，并读取 GAP 设备名（`0x2A00`）校正显示名。
   - 把最新心率、连接状态、历史样本写入跨进程共享文件（见下文「数据共享」）。

2. **自动锁屏（三种触发，均可在设置中调整）**
   - **心率超时**：超过 `timeoutSeconds`（默认 10 秒）无任何存活信号（连接成功/读到 RSSI/收到心率）即锁屏。
   - **弱信号**：绑定设备 RSSI 连续 `weakSignalLockSeconds`（默认 3 秒）低于 `lockRSSIThreshold`（默认 -75 dBm），视为走远，锁屏。
   - **键鼠空闲（兜底）**：仅在手表失联（无存活信号）时生效；键鼠全局空闲超过 `idleLockSeconds`（默认 10 秒）锁屏。可设「只在指定时间段内生效」（支持多段、跨午夜），只限制空闲锁屏，信号弱/心率超时锁屏任何时候都生效。
   - 锁屏按可靠性依次尝试：
     1. `login.framework` 私有接口 `SACLockScreenImmediate`（新版 macOS 首选）
     2. 旧路径 `CGSession -suspend`
     3. 兜底 `pmset displaysleepnow` 熄屏（需系统设置中「唤醒时需要密码」设为立即才等效锁屏）

3. **手表在线时保持屏幕常亮**（默认开启）
   - 手表信号存活期间，通过 `IOPMAssertionCreateWithName` 持有防熄屏断言（等效 `caffeinate -d`），键鼠再空闲系统也不会自动熄屏/锁屏；手表失联或关闭开关即释放，恢复正常休眠。App 退出时断言由系统自动回收。

4. **开机自动启动**（默认开启）
   - 通过 `SMAppService.mainApp` 注册/注销登录项（macOS 13+）。

5. **数据共享（App ↔ Widget）**
   - 不走 App Group UserDefaults：主 App 非沙盒、`UserDefaults(suiteName:)` 会落到别的文件且组容器路径会被 TCC 拦截。
   - 实际方案：共享 plist 文件放在 **Widget 自己的容器**内（`~/Library/Containers/<widget bundle id>/Data/Library/Application Support/HeartRateLockShared.plist`），Widget 沙盒读自己容器天然允许，主 App 直接写该路径。
   - 心率历史保留最近 15 分钟（上限 1200 条），供曲线小组件读取；解除绑定时清空。

6. **小组件**
   - 「实时心率」和「心率曲线」两个 Widget，均支持 `.systemSmall` / `.systemMedium`。
   - 主 App 收到心率时主动 `WidgetCenter.reloadAllTimelines()`（10 秒节流），Widget 侧再请求 1 秒后刷新兜底；实际刷新频率由系统调度决定。

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

3. **编译安装**（无需打开 Xcode）：
   ```bash
   ./build.sh
   ```
   生成 Release 版并安装到 `/Applications/不跳就锁.app`（会先退出旧进程），然后 `open /Applications/不跳就锁.app` 启动。

   或者用 Xcode 开发调试：
   ```bash
   open HeartRateLockWidget.xcodeproj
   ```
   - 在 `HeartRateLock` 和 `HeartRateWidget` target 的 **Signing & Capabilities** 中选择你的 Team。
   - 确保 Apple Developer 账号中已注册 App Group（见 setup.sh 输出）。
   - 先运行 `HeartRateLock` target，状态栏会出现 `♥ --` 图标；再运行 `HeartRateWidget` extension 添加小组件。

## 权限说明

首次运行会请求：

- **蓝牙权限**：扫描心率设备广播必需（`NSBluetoothAlwaysUsageDescription`）。
- 主 App **未开沙盒**（需调用锁屏命令和私有 framework）；Widget 在沙盒中运行。

## 绑定你的手表

状态栏菜单 →「选择设备」会实时列出周围 BLE 设备（按信号强度排序），点击即可绑定；「解除绑定」可重新选择。

注意：

- 手表的 MAC 地址**无法用于过滤**，macOS 出于隐私只暴露随机生成的 `CBPeripheral.identifier`。
- 很多设备广播里不带名字（显示「未知设备」），把手表贴近 Mac，列表里信号最强的那个通常就是它；绑定后 App 会通过 GAP 服务读出真实设备名，便于确认。
- 设备必须支持标准 BLE 心率服务 `0x180D`。绑定后若日志提示「没有标准心率服务」，说明该设备不对外开放心率（部分华为手表型号如此，只走华为运动健康的私有协议）。

## 设置

状态栏菜单 →「设置…」可调整（改动即时生效）：

- **通用**：开机自动启动；手表在线时保持屏幕常亮。
- **信号弱锁屏**：RSSI 阈值（-90 ~ -40 dBm）、连续弱信号秒数（1~15）。
- **心率超时锁屏**：超时秒数（5~60）。
- **空闲锁屏**：开关、键鼠空闲秒数（5~300）、生效时间段（可添加多段，支持跨午夜）。

建议先戴着设备在正常位置观察菜单里显示的实时 RSSI，再走到期望触发锁屏的距离看一眼，把阈值设在两者之间。

## 日志

运行日志写在 `~/Library/Logs/HeartRateLock.log`（同时输出 NSLog），超过 1MB 从头重写。锁屏行为、连接状态变化都可以在这里回看。

## 已知限制

- WidgetKit 无法常驻扫描蓝牙，心率刷新频率受系统调度限制；**实时性由后台 App 保证**，小组件只是显示层。
- 锁屏动作由后台 App 执行，不是小组件。
- 锁屏依赖 `login.framework` 私有接口 `SACLockScreenImmediate`，未来 macOS 版本可能移除，届时自动回退到 `CGSession -suspend` 或 `pmset displaysleepnow`。
