import SwiftUI
import ServiceManagement
import UserNotifications

/// 开机自动启动（登录项），macOS 13+ 用 SMAppService 管理
enum LaunchAtLoginManager {
    /// 按当前设置注册/注销登录项；App 启动和开关变化时都要调用
    static func apply() {
        do {
            if SharedConfig.launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                    Log.write("已注册开机自动启动")
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    Log.write("已取消开机自动启动")
                }
            }
        } catch {
            Log.write("开机自动启动设置失败: \(error.localizedDescription)")
        }
    }
}

@main
struct HeartRateLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // 主界面不展示窗口，保持后台运行；设置窗口由 AppDelegate 手动管理
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// 设置窗口：左侧边栏 + 右侧内容（参考 ClipVault 风格）
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(minWidth: 700, minHeight: 520)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(selectedTab == tab ? .white : .primary)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 170)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(selectedTab.title)
                    .font(.title2).bold()
                switch selectedTab {
                case .general:
                    GeneralSettingsView()
                case .lockScreen:
                    LockScreenSettingsView()
                case .abnormalAlert:
                    AbnormalAlertSettingsView()
                case .heartRateReport:
                    HeartRateReportSettingsView()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case lockScreen
    case abnormalAlert
    case heartRateReport

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .lockScreen: return "锁屏"
        case .abnormalAlert: return "异常报警"
        case .heartRateReport: return "心率上报"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .lockScreen: return "lock.fill"
        case .abnormalAlert: return "exclamationmark.triangle.fill"
        case .heartRateReport: return "arrow.up.circle.fill"
        }
    }
}

// MARK: - 通用设置

private struct GeneralSettingsView: View {
    @AppStorage(SharedConfig.Keys.launchAtLogin) private var launchAtLogin = true
    @AppStorage(SharedConfig.Keys.keepAwakeEnabled) private var keepAwakeEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        LaunchAtLoginManager.apply()
                    }
                Toggle("手表在线时保持屏幕常亮", isOn: $keepAwakeEnabled)
            } footer: {
                Text("开启后，只要手表信号在线，即使键鼠一直空闲，系统也不会自动熄屏/锁屏（等效 caffeinate -d）；手表失联后恢复正常休眠")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 锁屏设置

private struct LockScreenSettingsView: View {
    @AppStorage(SharedConfig.Keys.lockRSSIThreshold) private var lockRSSIThreshold = SharedConfig.Default.lockRSSIThreshold
    @AppStorage(SharedConfig.Keys.weakSignalLockSeconds) private var weakSignalLockSeconds = SharedConfig.Default.weakSignalLockSeconds
    @AppStorage(SharedConfig.Keys.timeoutSeconds) private var timeoutSeconds = SharedConfig.Default.timeoutSeconds
    @AppStorage(SharedConfig.Keys.idleLockSeconds) private var idleLockSeconds = SharedConfig.Default.idleLockSeconds
    @AppStorage(SharedConfig.Keys.idleLockEnabled) private var idleLockEnabled = true
    @AppStorage(SharedConfig.Keys.idleLockScheduleEnabled) private var idleLockScheduleEnabled = false
    @State private var idleRanges: [SharedConfig.IdleTimeRange] = []

    var body: some View {
        Form {
            Section("信号弱锁屏（人走远时）") {
                HStack {
                    Text("锁屏阈值")
                    Slider(
                        value: Binding(
                            get: { Double(lockRSSIThreshold) },
                            set: { lockRSSIThreshold = Int($0) }
                        ),
                        in: -90 ... -40,
                        step: 1
                    )
                    Text("\(lockRSSIThreshold) dBm")
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                Stepper("连续弱信号 \(weakSignalLockSeconds) 秒后锁屏", value: $weakSignalLockSeconds, in: 1...15)
            }

            Section("心率超时锁屏（设备失联时）") {
                Stepper("超过 \(Int(timeoutSeconds)) 秒未收到心率锁屏", value: $timeoutSeconds, in: 5...60, step: 5)
            }

            Section {
                Toggle("键鼠空闲时锁屏", isOn: $idleLockEnabled)
                Stepper("键鼠空闲 \(idleLockSeconds) 秒后锁屏", value: $idleLockSeconds, in: 5...300, step: 5)
                    .disabled(!idleLockEnabled)
                Toggle("只在指定时间段内生效", isOn: $idleLockScheduleEnabled)
                    .disabled(!idleLockEnabled)
                if idleLockScheduleEnabled {
                    ForEach(Array(idleRanges.indices), id: \.self) { index in
                        HStack {
                            DatePicker("", selection: rangeTimeBinding(index, \.startMinutes), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Text("~")
                            DatePicker("", selection: rangeTimeBinding(index, \.endMinutes), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Spacer()
                            Button {
                                idleRanges.remove(at: index)
                                SharedConfig.idleLockSchedule = idleRanges
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("添加时间段") {
                        idleRanges.append(SharedConfig.IdleTimeRange(startMinutes: 12 * 60, endMinutes: 14 * 60))
                        SharedConfig.idleLockSchedule = idleRanges
                    }
                }
            } header: {
                Text("空闲锁屏（键鼠不动时兜底）")
            } footer: {
                Text("仅在手表失联（无信号）时生效；手表信号正常时，键鼠空闲不会锁屏")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            idleRanges = SharedConfig.idleLockSchedule
        }
    }

    private func rangeTimeBinding(_ index: Int, _ keyPath: WritableKeyPath<SharedConfig.IdleTimeRange, Int>) -> Binding<Date> {
        Binding(
            get: {
                guard idleRanges.indices.contains(index) else { return Date() }
                let minutes = idleRanges[index][keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { newValue in
                guard idleRanges.indices.contains(index) else { return }
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                idleRanges[index][keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                SharedConfig.idleLockSchedule = idleRanges
            }
        )
    }
}

// MARK: - 异常报警设置

private struct AbnormalAlertSettingsView: View {
    @AppStorage(SharedConfig.Keys.alertEnabled) private var alertEnabled = false
    @AppStorage(SharedConfig.Keys.alertHeartRateLowerThreshold) private var alertHeartRateLowerThreshold = SharedConfig.Default.alertHeartRateLowerThreshold
    @AppStorage(SharedConfig.Keys.alertHeartRateLowerThresholdEnabled) private var alertHeartRateLowerThresholdEnabled = false
    @AppStorage(SharedConfig.Keys.alertHeartRateUpperThreshold) private var alertHeartRateUpperThreshold = SharedConfig.Default.alertHeartRateUpperThreshold
    @AppStorage(SharedConfig.Keys.alertHeartRateUpperThresholdEnabled) private var alertHeartRateUpperThresholdEnabled = true
    @AppStorage(SharedConfig.Keys.alertSignalThresholdEnabled) private var alertSignalThresholdEnabled = false
    @AppStorage(SharedConfig.Keys.alertSignalThreshold) private var alertSignalThreshold = SharedConfig.Default.alertSignalThreshold
    @AppStorage(SharedConfig.Keys.alertMissingHeartRateAsZero) private var alertMissingHeartRateAsZero = true
    @AppStorage(SharedConfig.Keys.alertDurationMinutes) private var alertDurationMinutes = SharedConfig.Default.alertDurationMinutes
    @AppStorage(SharedConfig.Keys.alertNotifyEnabled) private var alertNotifyEnabled = true
    @AppStorage(SharedConfig.Keys.alertRunScriptEnabled) private var alertRunScriptEnabled = false
    @AppStorage(SharedConfig.Keys.alertScriptPath) private var alertScriptPath = ""
    @AppStorage(SharedConfig.Keys.alertFeishuEnabled) private var alertFeishuEnabled = false
    @AppStorage(SharedConfig.Keys.alertPlatform) private var alertPlatformRawValue = SharedConfig.AlertPlatform.feishu.rawValue
    @AppStorage(SharedConfig.Keys.alertFeishuWebhookURL) private var alertFeishuWebhookURL = ""
    @AppStorage(SharedConfig.Keys.alertFeishuSecret) private var alertFeishuSecret = ""
    @AppStorage(SharedConfig.Keys.alertFeishuMessageTemplate) private var alertFeishuMessageTemplate = SharedConfig.Default.alertFeishuMessageTemplate

    private var alertPlatform: Binding<SharedConfig.AlertPlatform> {
        Binding(
            get: { SharedConfig.AlertPlatform(rawValue: alertPlatformRawValue) ?? .feishu },
            set: { alertPlatformRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("开启异常报警", isOn: $alertEnabled)
            } footer: {
                Text("开启后，当触发条件持续满足设定时长时，会按下方选项发送通知、执行脚本或发送群消息。")
            }

            Group {
                Section {
                    Toggle("心率低于", isOn: $alertHeartRateLowerThresholdEnabled)

                    if alertHeartRateLowerThresholdEnabled {
                        HStack {
                            Spacer()
                            TextField("", value: $alertHeartRateLowerThreshold, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                                .multilineTextAlignment(.trailing)
                            Text("BPM 时报警")
                        }
                        .onChange(of: alertHeartRateLowerThreshold) { _, newValue in
                            if newValue < 0 { alertHeartRateLowerThreshold = 0 }
                            else if newValue > 220 { alertHeartRateLowerThreshold = 220 }
                        }
                    }

                    Toggle("心率高于", isOn: $alertHeartRateUpperThresholdEnabled)

                    if alertHeartRateUpperThresholdEnabled {
                        HStack {
                            Spacer()
                            TextField("", value: $alertHeartRateUpperThreshold, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                                .multilineTextAlignment(.trailing)
                            Text("BPM 时报警")
                        }
                        .onChange(of: alertHeartRateUpperThreshold) { _, newValue in
                            if newValue < 0 { alertHeartRateUpperThreshold = 0 }
                            else if newValue > 220 { alertHeartRateUpperThreshold = 220 }
                        }
                    }

                    Toggle("同时要求信号弱于阈值", isOn: $alertSignalThresholdEnabled)

                    if alertSignalThresholdEnabled {
                        HStack {
                            Text("信号阈值")
                            Slider(
                                value: Binding(
                                    get: { Double(alertSignalThreshold) },
                                    set: { alertSignalThreshold = Int($0) }
                                ),
                                in: -90 ... -40,
                                step: 1
                            )
                            Text("\(alertSignalThreshold) dBm")
                                .monospacedDigit()
                                .frame(width: 64, alignment: .trailing)
                        }
                    }

                    Toggle("心率缺失但信号存活时视为 0 BPM", isOn: $alertMissingHeartRateAsZero)

                    HStack {
                        Text("持续")
                        Spacer()
                        TextField("", value: $alertDurationMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                        Text("分钟")
                    }
                    .onChange(of: alertDurationMinutes) { _, newValue in
                        if newValue < 1 { alertDurationMinutes = 1 }
                        else if newValue > 60 { alertDurationMinutes = 60 }
                    }
                } header: {
                    Text("触发条件")
                } footer: {
                    Text("心率下限/上限条件满足任一即可，若启用信号阈值则需同时满足信号条件，并持续指定时长才会触发报警。")
                }

                Section {
                    Toggle("发送系统通知", isOn: $alertNotifyEnabled)
                    Toggle("执行脚本", isOn: $alertRunScriptEnabled)

                    if alertRunScriptEnabled {
                        HStack {
                            TextField("脚本路径", text: $alertScriptPath)
                            Button("选择…") {
                                chooseScript()
                            }
                        }
                        Text("支持 Shell 脚本（.sh）与 Python 脚本（.py）。脚本会通过环境变量 HEART_RATE 与命令行参数 $1 收到当前心率。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("发送到", isOn: $alertFeishuEnabled)

                    if alertFeishuEnabled {
                        Picker("平台", selection: alertPlatform) {
                            ForEach(SharedConfig.AlertPlatform.allCases) { platform in
                                Text(platform.displayName).tag(platform)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        SecureField(webhookPlaceholder, text: $alertFeishuWebhookURL)
                            .textFieldStyle(.roundedBorder)

                        if alertPlatform.wrappedValue != .wecom {
                            SecureField(secretPlaceholder, text: $alertFeishuSecret)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("消息模板")
                                .font(.system(size: 13))
                            TextEditor(text: $alertFeishuMessageTemplate)
                                .font(.system(size: 13))
                                .frame(height: 60)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                )
                            Text("可用占位符：{heartRate} 当前心率、{threshold} 阈值、{duration} 持续分钟。留空将使用默认模板。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button("测试") {
                            AlertManager.testPlatformMessage()
                        }
                    }
                } header: {
                    Text("报警动作")
                }
            }
            .disabled(!alertEnabled)
        }
        .formStyle(.grouped)
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            alertScriptPath = url.path
        }
    }

    private var webhookPlaceholder: String {
        switch alertPlatform.wrappedValue {
        case .feishu: return "飞书机器人 Webhook"
        case .dingtalk: return "钉钉机器人 Webhook"
        case .wecom: return "企业微信机器人 Webhook"
        }
    }

    private var secretPlaceholder: String {
        switch alertPlatform.wrappedValue {
        case .feishu: return "飞书机器人密钥（可选）"
        case .dingtalk: return "钉钉机器人密钥（可选）"
        case .wecom: return ""
        }
    }
}

// MARK: - 心率上报设置

private struct HeartRateReportSettingsView: View {
    @AppStorage(SharedConfig.Keys.reportEnabled) private var reportEnabled = false
    @AppStorage(SharedConfig.Keys.reportAPIURL) private var reportAPIURL = ""
    @AppStorage(SharedConfig.Keys.reportAPIToken) private var reportAPIToken = ""
    @AppStorage(SharedConfig.Keys.reportIntervalSeconds) private var reportIntervalSeconds = SharedConfig.Default.reportIntervalSeconds
    @State private var isTesting = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Section {
                Toggle("上报心率到 API", isOn: $reportEnabled)
            } footer: {
                Text("开启后，蓝牙收到心率时按设定的间隔 POST 到下方 API 地址。关闭后不会发送任何请求。")
            }

            Group {
                Section {
                    HStack {
                        Text("API 地址")
                            .frame(width: 80, alignment: .trailing)
                        TextField("https://example.com/api/v1/heart-rate/realtime", text: $reportAPIURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Bearer Token")
                            .frame(width: 80, alignment: .trailing)
                        SecureField("", text: $reportAPIToken)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("最小上报间隔")
                            .frame(width: 80, alignment: .trailing)
                        TextField("1", text: intervalMinutesBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Text("分钟")
                    }
                } header: {
                    Text("接口配置")
            } footer: {
                Text("请求体：{\"heart_rate\": 67, \"timestamp\": 毫秒时间戳, \"device_id\": \"绑定的设备名\", \"source\": \"bluetooth\"}。间隔用于节流，避免心率频繁推送把接口打爆。")
            }

                Section {
                    HStack {
                        Button("发送测试数据") {
                            sendTest()
                        }
                        .disabled(isTesting || !reportEnabled)

                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else if let testResult {
                            Text(testResult)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    Text("测试会立即发送一条心率 67 的样本到接口，用于验证地址与 Token 是否正确。")
                }
            }
            .disabled(!reportEnabled)
        }
        .formStyle(.grouped)
    }

    /// 秒 -> 分钟 的文本绑定，支持手动输入
    private var intervalMinutesBinding: Binding<String> {
        Binding(
            get: { String(max(1, reportIntervalSeconds / 60)) },
            set: { newValue in
                let minutes = Int(newValue.filter(\.isNumber)) ?? 1
                reportIntervalSeconds = max(1, minutes) * 60
            }
        )
    }

    private func sendTest() {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil
        let sent = HeartRateUploadManager.shared.upload(
            heartRate: 67,
            deviceID: UserDefaults.standard.string(forKey: SharedConfig.Keys.boundDeviceName),
            force: true
        )
        if !sent {
            isTesting = false
            testResult = "未发送：请检查 API 地址"
            return
        }
        // 请求已在后台发出，稍等片刻后看日志；这里只提示已发起
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            isTesting = false
            testResult = "已发送，结果见日志（~/Library/Logs/HeartRateLock.log）"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    private var statusItem: NSStatusItem?

    /// 记录各菜单项对应的设备 UUID
    private var deviceMenuItemIDs: [NSMenuItem: UUID] = [:]

    private var boundInfoItem: NSMenuItem?
    private var deviceMenu: NSMenu?
    private var unbindItem: NSMenuItem?

    /// 手动管理的设置窗口（菜单栏 App 没有主窗口，showSettingsWindow: 响应链不可靠）
    private var settingsWindow: NSWindow?
    /// 关于窗口
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标，作为状态栏后台工具运行
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()

        // 按设置注册/注销开机自动启动
        LaunchAtLoginManager.apply()

        // 注册通知中心代理，并提前请求通知权限
        UNUserNotificationCenter.current().delegate = self
        AlertManager.requestNotificationAuthorizationIfNeeded()

        // 启动蓝牙扫描
        _ = BLEHeartRateManager.shared

        // 启动后异步检查更新（每天最多一次），失败静默
        Task.detached {
            await UpdateChecker.shared.checkForUpdatesIfNeeded()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // App 在前台时也显示横幅/播放声音
        completionHandler([.banner, .sound])
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        button.title = "♥ --"

        let menu = NSMenu()
        menu.delegate = self

        // 当前绑定状态（不可点击）
        let boundInfo = NSMenuItem(title: "未绑定设备", action: nil, keyEquivalent: "")
        boundInfo.isEnabled = false
        menu.addItem(boundInfo)
        boundInfoItem = boundInfo

        // 选择设备子菜单
        let deviceItem = NSMenuItem(title: "选择设备", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "选择设备")
        deviceItem.submenu = submenu
        menu.addItem(deviceItem)
        deviceMenu = submenu

        // 解除绑定
        let unbind = NSMenuItem(title: "解除绑定", action: #selector(unbindDevice), keyEquivalent: "")
        unbind.target = self
        menu.addItem(unbind)
        unbindItem = unbind

        menu.addItem(.separator())

        // 设置
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // 关于
        let aboutItem = NSMenuItem(title: "关于…", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // 检查更新
        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 不跳就锁",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu

        // 定时刷新状态栏显示
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusItem()
            }
        }
    }

    private func updateStatusItem() {
        let manager = BLEHeartRateManager.shared
        let hr = manager.currentHeartRate
        let receiving = manager.isReceiving

        if receiving, let hr = hr {
            statusItem?.button?.title = "♥ \(hr)"
        } else {
            statusItem?.button?.title = "♥ --"
        }
    }

    // MARK: - NSMenuDelegate：每次打开菜单时刷新设备列表

    func menuWillOpen(_ menu: NSMenu) {
        let manager = BLEHeartRateManager.shared

        // 绑定状态
        if let name = manager.boundDeviceName {
            let rssiText = manager.currentRSSI.map { "\($0) dBm" } ?? "--"
            let hrText = manager.isReceiving ? "心率 \(manager.currentHeartRate ?? 0)" : "等待心率…"
            boundInfoItem?.title = "已绑定: \(name)（\(hrText)，信号 \(rssiText)）"
        } else {
            boundInfoItem?.title = "未绑定设备"
        }
        unbindItem?.isHidden = manager.boundDeviceName == nil

        // 设备列表
        deviceMenuItemIDs.removeAll()
        deviceMenu?.removeAllItems()

        guard let deviceMenu else { return }
        if manager.boundDeviceName != nil {
            let item = NSMenuItem(title: "已绑定设备，扫描已停止", action: nil, keyEquivalent: "")
            item.isEnabled = false
            deviceMenu.addItem(item)
            return
        }
        if manager.discoveredDevices.isEmpty {
            let item = NSMenuItem(title: "扫描中，暂无设备…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            deviceMenu.addItem(item)
            return
        }
        for device in manager.discoveredDevices {
            let item = NSMenuItem(
                title: "\(device.name)（\(device.rssi) dBm）",
                action: #selector(selectDevice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            deviceMenuItemIDs[item] = device.id
            deviceMenu.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let id = deviceMenuItemIDs[sender] else { return }
        BLEHeartRateManager.shared.bind(deviceID: id)
    }

    @objc private func unbindDevice() {
        BLEHeartRateManager.shared.unbind()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "不跳就锁 设置"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 700, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openAbout() {
        if aboutWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            window.title = "关于 不跳就锁"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            aboutWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func checkForUpdates() {
        Task.detached {
            await UpdateChecker.shared.checkForUpdatesManually()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

/// 关于窗口：作者信息 + 版本 + 检查更新
struct AboutView: View {
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.system(size: 40))
                .foregroundColor(.red)
            Text("不跳就锁")
                .font(.title2.bold())
            Text("手表心率消失就锁屏")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("版本 \(UpdateChecker.shared.currentVersion)")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            HStack {
                Text("作者")
                    .foregroundColor(.secondary)
                Spacer()
                Text("阿文")
            }
            HStack {
                Text("博客")
                    .foregroundColor(.secondary)
                Spacer()
                Link("https://www.awen.me", destination: URL(string: "https://www.awen.me")!)
            }
            HStack {
                Text("邮箱")
                    .foregroundColor(.secondary)
                Spacer()
                Link("hi@awen.me", destination: URL(string: "mailto:hi@awen.me")!)
            }

            Button {
                guard !isChecking else { return }
                isChecking = true
                Task {
                    await UpdateChecker.shared.checkForUpdatesManually()
                    isChecking = false
                }
            } label: {
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Text("检查更新")
                }
            }
            .disabled(isChecking)
        }
        .padding(20)
        .frame(width: 280)
    }
}
