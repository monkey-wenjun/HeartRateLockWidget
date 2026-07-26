import SwiftUI
import ServiceManagement

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

/// 设置窗口：锁屏触发条件，改动存 UserDefaults 即时生效
struct SettingsView: View {
    @AppStorage(SharedConfig.Keys.lockRSSIThreshold) private var lockRSSIThreshold = SharedConfig.Default.lockRSSIThreshold
    @AppStorage(SharedConfig.Keys.weakSignalLockSeconds) private var weakSignalLockSeconds = SharedConfig.Default.weakSignalLockSeconds
    @AppStorage(SharedConfig.Keys.timeoutSeconds) private var timeoutSeconds = SharedConfig.Default.timeoutSeconds
    @AppStorage(SharedConfig.Keys.idleLockSeconds) private var idleLockSeconds = SharedConfig.Default.idleLockSeconds
    @AppStorage(SharedConfig.Keys.idleLockEnabled) private var idleLockEnabled = true
    @AppStorage(SharedConfig.Keys.idleLockScheduleEnabled) private var idleLockScheduleEnabled = false
    /// 生效时间段列表，改动即写入 SharedConfig
    @State private var idleRanges: [SharedConfig.IdleTimeRange] = []
    @AppStorage(SharedConfig.Keys.launchAtLogin) private var launchAtLogin = true

    var body: some View {
        Form {
            Section("通用") {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        LaunchAtLoginManager.apply()
                    }
            }

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

            Section("空闲锁屏（键鼠不动时兜底）") {
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
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460, height: 500)
        .onAppear {
            idleRanges = SharedConfig.idleLockSchedule
        }
    }

    /// 把"0:00 起算的分钟数"绑定成 DatePicker 用的时间
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, ObservableObject {
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

        // 启动蓝牙扫描
        _ = BLEHeartRateManager.shared
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

/// 关于窗口：作者信息
struct AboutView: View {
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
        }
        .padding(20)
        .frame(width: 280)
    }
}
