import Foundation

public enum SharedConfig {
    /// 替换为你自己的 App Group，例如 "group.com.yourname.heartratelock"
    public static let appGroupIdentifier = "group.com.awen.heartratelock"
    /// Widget Extension 的 Bundle ID（共享文件放在它的容器里，需与 project.yml 中的 PRODUCT_BUNDLE_IDENTIFIER 一致）
    public static let widgetBundleIdentifier = "com.awen.HeartRateLock.widget"

    public enum Keys {
        public static let heartRate = "heartRate"
        public static let lastUpdated = "heartRateLastUpdated"
        public static let isConnected = "heartRateIsConnected"
        /// 心率历史样本（App Group 共享），元素为 ["t": 时间戳, "hr": BPM]，供曲线小组件读取
        public static let heartRateHistory = "heartRateHistory"
        /// 用户绑定设备的 UUID / 名称（存在标准 UserDefaults，不走 App Group）
        public static let boundDeviceUUID = "boundDeviceUUID"
        public static let boundDeviceName = "boundDeviceName"
        /// 设置项（存在标准 UserDefaults，由设置窗口读写；锁屏开关已移除，两种锁屏始终生效）
        public static let timeoutSeconds = "settingTimeoutSeconds"
        public static let lockRSSIThreshold = "settingLockRSSIThreshold"
        public static let idleLockSeconds = "settingIdleLockSeconds"
        public static let idleLockEnabled = "settingIdleLockEnabled"
        /// 空闲锁屏时间段限制：开关 + 时间段列表（[{"start": 分钟, "end": 分钟}]，从 0:00 起算）
        public static let idleLockScheduleEnabled = "settingIdleLockScheduleEnabled"
        public static let idleLockSchedule = "settingIdleLockSchedule"
        public static let weakSignalLockSeconds = "settingWeakSignalLockSeconds"
        public static let launchAtLogin = "settingLaunchAtLogin"
    }

    /// 设置项的出厂默认值
    public enum Default {
        public static let timeoutSeconds: Double = 10
        public static let lockRSSIThreshold: Int = -75
        public static let weakSignalLockSeconds: Int = 3
        public static let idleLockSeconds: Int = 10
    }

    /// 心率历史曲线：只保留最近一段时间的样本
    public enum History {
        /// 曲线展示/保留的时间窗口
        public static let windowSeconds: TimeInterval = 15 * 60
        /// 样本数上限（心率约 1Hz 推送，15 分钟约 900 条，留点余量）
        public static let maxSamples = 1200
    }

    // MARK: - 设置项（UserDefaults 持久化，设置窗口改后即时生效）

    /// 超过该秒数没收到心率就视为丢失，触发锁屏
    public static var timeoutSeconds: Double {
        get { UserDefaults.standard.object(forKey: Keys.timeoutSeconds) as? Double ?? Default.timeoutSeconds }
        set { UserDefaults.standard.set(newValue, forKey: Keys.timeoutSeconds) }
    }

    /// 绑定设备信号低于该 RSSI（dBm）视为走远，触发锁屏。
    /// 参考：贴身旁约 -40~-55，隔一两堵墙可能到 -80 以下。
    public static var lockRSSIThreshold: Int {
        get { UserDefaults.standard.object(forKey: Keys.lockRSSIThreshold) as? Int ?? Default.lockRSSIThreshold }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lockRSSIThreshold) }
    }

    /// 信号需连续低于阈值多少秒才锁屏（RSSI 抖动大，防止误锁）
    public static var weakSignalLockSeconds: Int {
        get { UserDefaults.standard.object(forKey: Keys.weakSignalLockSeconds) as? Int ?? Default.weakSignalLockSeconds }
        set { UserDefaults.standard.set(newValue, forKey: Keys.weakSignalLockSeconds) }
    }

    /// 键鼠空闲多少秒后锁屏（兜底逻辑）
    public static var idleLockSeconds: Int {
        get { UserDefaults.standard.object(forKey: Keys.idleLockSeconds) as? Int ?? Default.idleLockSeconds }
        set { UserDefaults.standard.set(newValue, forKey: Keys.idleLockSeconds) }
    }

    /// 空闲锁屏开关，默认开启
    public static var idleLockEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.idleLockEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.idleLockEnabled) }
    }

    // MARK: - 空闲锁屏时间段

    /// 一个生效时间段，单位均为 0:00 起算的分钟数；start > end 表示跨午夜（如 22:00~02:00）
    public struct IdleTimeRange: Equatable {
        public var startMinutes: Int
        public var endMinutes: Int
        public init(startMinutes: Int, endMinutes: Int) {
            self.startMinutes = startMinutes
            self.endMinutes = endMinutes
        }
    }

    /// 是否只在指定时间段内启用空闲锁屏，默认关闭（全天生效）
    public static var idleLockScheduleEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.idleLockScheduleEnabled) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: Keys.idleLockScheduleEnabled) }
    }

    /// 生效时间段列表
    public static var idleLockSchedule: [IdleTimeRange] {
        get {
            let raw = UserDefaults.standard.array(forKey: Keys.idleLockSchedule) as? [[String: Int]] ?? []
            return raw.compactMap { dict in
                guard let start = dict["start"], let end = dict["end"] else { return nil }
                return IdleTimeRange(startMinutes: start, endMinutes: end)
            }
        }
        set {
            let raw = newValue.map { ["start": $0.startMinutes, "end": $0.endMinutes] }
            UserDefaults.standard.set(raw, forKey: Keys.idleLockSchedule)
        }
    }

    /// 当前时刻是否在空闲锁屏的生效时间段内（未开启限制或列表为空时视为始终生效）
    public static func isIdleLockInSchedule(now: Date = Date()) -> Bool {
        guard idleLockScheduleEnabled, !idleLockSchedule.isEmpty else { return true }
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return idleLockSchedule.contains { range in
            if range.startMinutes <= range.endMinutes {
                return minutes >= range.startMinutes && minutes < range.endMinutes
            }
            // 跨午夜：如 22:00~02:00
            return minutes >= range.startMinutes || minutes < range.endMinutes
        }
    }

    /// 开机自动启动开关，默认开启
    public static var launchAtLogin: Bool {
        get { UserDefaults.standard.object(forKey: Keys.launchAtLogin) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.launchAtLogin) }
    }

    // MARK: - 心率历史（App Group 共享，曲线小组件读取）

    /// 追加一条心率样本，并裁剪到时间窗口和数量上限内
    public static func appendHeartRateSample(_ hr: Int, at date: Date = Date()) {
        var history = SharedStore.object(forKey: Keys.heartRateHistory) as? [[String: Double]] ?? []
        history.append(["t": date.timeIntervalSince1970, "hr": Double(hr)])
        let cutoff = date.timeIntervalSince1970 - History.windowSeconds
        history = history.filter { ($0["t"] ?? 0) >= cutoff }
        if history.count > History.maxSamples {
            history = Array(history.suffix(History.maxSamples))
        }
        SharedStore.set(history, forKey: Keys.heartRateHistory)
    }

    /// 读取时间窗口内的历史样本，按时间升序
    public static func heartRateHistory(now: Date = Date()) -> [(date: Date, hr: Int)] {
        let cutoff = now.timeIntervalSince1970 - History.windowSeconds
        let history = SharedStore.object(forKey: Keys.heartRateHistory) as? [[String: Double]] ?? []
        return history.compactMap { sample in
            guard let t = sample["t"], let hr = sample["hr"], t >= cutoff else { return nil }
            return (Date(timeIntervalSince1970: t), Int(hr))
        }
    }

    /// 清空历史（解除绑定时调用）
    public static func clearHeartRateHistory() {
        SharedStore.removeObject(forKey: Keys.heartRateHistory)
    }
}

/// 跨进程共享存储（心率、连接状态、历史曲线）。
/// 共享文件放在 Widget 自己的容器里：
/// - 沙盒 Widget 读自己的容器，sandbox 天然允许，不经过 TCC；
/// - 主 App（非沙盒）直接写该路径（App Group / UserDefaults(suiteName:) 在非沙盒进程
///   会落到别的文件，且组容器路径会被 TCC AppData 策略拦截 Widget 的读取，均不可用）。
public enum SharedStore {
    private static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    private static let plistURL: URL = {
        if isSandboxed {
            // Widget：自己容器内的 Application Support
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return dir.appendingPathComponent("HeartRateLockShared.plist")
        }
        // 主 App：写 Widget 容器内的同一个文件
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(SharedConfig.widgetBundleIdentifier)/Data/Library/Application Support/HeartRateLockShared.plist"
            )
    }()

    public static func object(forKey key: String) -> Any? {
        (NSDictionary(contentsOf: plistURL) as? [String: Any])?[key]
    }

    public static func set(_ value: Any?, forKey key: String) {
        var dict = (NSDictionary(contentsOf: plistURL) as? [String: Any]) ?? [:]
        dict[key] = value
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        (dict as NSDictionary).write(to: plistURL, atomically: true)
    }

    public static func removeObject(forKey key: String) {
        set(nil, forKey: key)
    }

    public static func bool(forKey key: String) -> Bool {
        object(forKey: key) as? Bool ?? false
    }
}
