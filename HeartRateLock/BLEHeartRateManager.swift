import Foundation
@preconcurrency import CoreBluetooth
import CoreGraphics
import WidgetKit

/// 扫描到的 BLE 设备，用于列表展示和用户绑定
struct DiscoveredDevice: Identifiable {
    let id: UUID
    let name: String
    var rssi: Int
    var lastSeenAt: Date
}

/// 负责扫描、绑定并连接 BLE 设备，订阅标准心率特征（0x2A37）
@MainActor
// Swift 6：用 @preconcurrency 标记 CoreBluetooth 协议遵循，允许 MainActor 隔离的
// 委托方法满足非隔离的协议要求，避免数据竞争警告。
final class BLEHeartRateManager: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate, ObservableObject {
    static let shared = BLEHeartRateManager()

    private var centralManager: CBCentralManager!

    /// 已发现设备列表（按 RSSI 由强到弱排序）
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    /// 设备 UUID -> 外设对象，供连接使用
    private var peripherals: [UUID: CBPeripheral] = [:]

    /// 当前绑定/连接中的外设
    private var activePeripheral: CBPeripheral?

    /// 最后一次收到"存活信号"的时间（连接成功 / 读到 RSSI / 收到心率）
    private var lastAliveAt: Date?
    /// 首次发起连接的时间（设备一直连不上时作为超时起算点）
    private var connectAttemptAt: Date?
    /// 是否已因超时锁过屏（恢复存活前不重复锁）
    private var didLockForTimeout = false
    /// 是否已因空闲锁过屏（有键鼠活动前不重复锁）
    private var didLockForIdle = false

    /// 扫描选项：允许重复发现，便于持续更新 RSSI
    private let scanOptions: [String: Any] = [
        CBCentralManagerScanOptionAllowDuplicatesKey: true
    ]

    /// 标准心率服务 / 心率测量特征
    private let heartRateServiceUUID = CBUUID(string: "0x180D")
    private let heartRateMeasurementUUID = CBUUID(string: "0x2A37")
    /// 标准 GAP 服务 / 设备名特征，用于连接后读取真实设备名
    private let gapServiceUUID = CBUUID(string: "0x1800")
    private let deviceNameUUID = CBUUID(string: "0x2A00")

    @Published var currentHeartRate: Int?
    @Published var isReceiving: Bool = false
    /// 当前绑定的设备名（用于菜单展示）
    @Published private(set) var boundDeviceName: String?
    /// 绑定设备当前的信号强度（dBm），用于菜单展示和弱信号锁屏
    @Published private(set) var currentRSSI: Int?

    /// 信号连续低于阈值的秒数
    private var weakSignalSeconds = 0
    /// 是否已因弱信号锁过屏（信号恢复前不重复锁）
    private var didLockForWeakSignal = false

    /// 上一次请求 WidgetKit 刷新小组件的时间（节流用）
    private var lastWidgetReloadAt: Date = .distantPast

    private var timeoutTimer: Timer?

    /// 心率持续高于报警阈值：首次超过阈值的时间
    private var heartRateExceededAt: Date?
    /// 当前持续超标区间内是否已经触发过报警（恢复低于阈值后重置）
    private var didTriggerAlert = false

    override private init() {
        super.init()
        boundDeviceName = UserDefaults.standard.string(forKey: SharedConfig.Keys.boundDeviceName)
        centralManager = CBCentralManager(delegate: self, queue: .main)
        startTimeoutTimer()
    }

    // MARK: - Public API

    /// 用户从列表选择设备后调用：绑定并连接
    func bind(deviceID: UUID) {
        guard let peripheral = peripherals[deviceID] else { return }
        bind(peripheral: peripheral)
    }

    /// 解除绑定并断开连接
    func unbind() {
        if let peripheral = activePeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        activePeripheral = nil
        boundDeviceName = nil
        UserDefaults.standard.removeObject(forKey: SharedConfig.Keys.boundDeviceUUID)
        UserDefaults.standard.removeObject(forKey: SharedConfig.Keys.boundDeviceName)
        SharedConfig.clearHeartRateHistory()
        persistConnected(false)
        isReceiving = false
        currentHeartRate = nil
        currentRSSI = nil
        weakSignalSeconds = 0
        didLockForWeakSignal = false
        lastAliveAt = nil
        connectAttemptAt = nil
        didLockForTimeout = false
        heartRateExceededAt = nil
        didTriggerAlert = false
        KeepAwakeManager.setEnabled(false)
        startScanning()
    }

    // MARK: - Binding

    private func bind(peripheral: CBPeripheral) {
        if let old = activePeripheral, old != peripheral {
            centralManager.cancelPeripheralConnection(old)
        }
        activePeripheral = peripheral
        boundDeviceName = peripheral.name ?? "未知设备"
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: SharedConfig.Keys.boundDeviceUUID)
        UserDefaults.standard.set(boundDeviceName, forKey: SharedConfig.Keys.boundDeviceName)
        Log.write("绑定设备: \(boundDeviceName ?? "未知") (\(peripheral.identifier.uuidString))")

        // 连上后停止扫描，省电且减少日志噪音
        centralManager.stopScan()
        connectActivePeripheral()
    }

    private func connectActivePeripheral() {
        guard let peripheral = activePeripheral else { return }
        peripheral.delegate = self
        // 只在首次发起时记录，重连失败重试不重置超时起算点
        if connectAttemptAt == nil {
            connectAttemptAt = Date()
        }
        centralManager.connect(peripheral, options: nil)
    }

    // MARK: - Timer

    private func startTimeoutTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkTimeout()
                self?.checkIdleLock()
                self?.updateKeepAwake()
            }
        }
    }

    /// 兜底锁屏：仅在手表失联（超过 timeoutSeconds 无存活信号）时，
    /// 键盘、鼠标全局空闲超过设定秒数才锁；手表信号正常时键鼠空闲不锁
    private func checkIdleLock() {
        guard SharedConfig.idleLockEnabled, SharedConfig.isIdleLockInSchedule() else {
            didLockForIdle = false
            return
        }
        // 手表信号正常时不做空闲锁屏
        if let alive = lastAliveAt, Date().timeIntervalSince(alive) <= SharedConfig.timeoutSeconds {
            didLockForIdle = false
            return
        }
        // 取各类输入事件中"最近一次活动"距今的最短间隔，作为系统空闲时长
        let eventTypes: [CGEventType] = [
            .keyDown, .flagsChanged,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel
        ]
        let idle = eventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0

        if idle >= TimeInterval(SharedConfig.idleLockSeconds) {
            if !didLockForIdle {
                Log.write("键鼠空闲 \(Int(idle)) 秒，触发锁屏（兜底）")
                didLockForIdle = true
                LockScreenManager.lockScreen()
            }
        } else {
            didLockForIdle = false
        }
    }

    /// 保持唤醒：开关开启且手表信号存活（与空闲锁屏同一判定）期间，
    /// 持有防熄屏断言（等效 caffeinate -d），键鼠再空闲系统也不会自动熄屏锁屏；
    /// 信号丢失或开关关闭即释放，恢复系统正常休眠
    private func updateKeepAwake() {
        let alive = lastAliveAt.map { Date().timeIntervalSince($0) <= SharedConfig.timeoutSeconds } ?? false
        KeepAwakeManager.setEnabled(SharedConfig.keepAwakeEnabled && alive)
    }

    private func checkTimeout() {
        // 连接状态下顺带每秒读一次信号强度
        if let peripheral = activePeripheral, peripheral.state == .connected {
            peripheral.readRSSI()
        }

        // 未绑定设备不参与锁屏
        guard activePeripheral != nil else { return }
        // 起算点：最后一次存活信号；从未存活过则从首次发起连接算起
        guard let reference = lastAliveAt ?? connectAttemptAt else { return }
        if Date().timeIntervalSince(reference) > SharedConfig.timeoutSeconds, !didLockForTimeout {
            Log.write("超过 \(Int(SharedConfig.timeoutSeconds)) 秒无存活信号，触发锁屏")
            didLockForTimeout = true
            isReceiving = false
            persistConnected(false)
            LockScreenManager.lockScreen()
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateDescription: String
        switch central.state {
        case .poweredOn:          stateDescription = "poweredOn"
        case .poweredOff:         stateDescription = "poweredOff"
        case .unauthorized:       stateDescription = "unauthorized"
        case .unsupported:        stateDescription = "unsupported"
        case .resetting:          stateDescription = "resetting"
        case .unknown:            stateDescription = "unknown"
        @unknown default:         stateDescription = "unknown(\(central.state.rawValue))"
        }
        Log.write("蓝牙状态变化: \(stateDescription)")

        switch central.state {
        case .poweredOn:
            // 有绑定记录则优先重连，否则开始扫描
            if tryReconnectBoundPeripheral() == false {
                startScanning()
            }
        default:
            central.stopScan()
        }
    }

    /// 尝试恢复上次绑定的设备，返回是否找到了可重连的外设
    @discardableResult
    private func tryReconnectBoundPeripheral() -> Bool {
        guard let uuidString = UserDefaults.standard.string(forKey: SharedConfig.Keys.boundDeviceUUID),
              let uuid = UUID(uuidString: uuidString) else { return false }
        let found = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        guard let peripheral = found.first else {
            Log.write("未找到上次绑定的设备，开始扫描: \(uuidString)")
            return false
        }
        Log.write("恢复绑定设备: \(peripheral.name ?? "未知")")
        activePeripheral = peripheral
        connectActivePeripheral()
        return true
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let deviceName = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "未知设备"

        // 已绑定设备后无需维护列表
        guard activePeripheral == nil else { return }

        peripherals[peripheral.identifier] = peripheral
        if let index = discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            discoveredDevices[index].rssi = RSSI.intValue
            discoveredDevices[index].lastSeenAt = Date()
        } else {
            discoveredDevices.append(DiscoveredDevice(
                id: peripheral.identifier,
                name: deviceName,
                rssi: RSSI.intValue,
                lastSeenAt: Date()
            ))
        }
        // 丢弃 15 秒没再出现的设备，按信号强度排序
        let cutoff = Date().addingTimeInterval(-15)
        discoveredDevices.removeAll { $0.lastSeenAt < cutoff }
        discoveredDevices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Log.write("已连接: \(peripheral.name ?? "未知")")
        connectAttemptAt = nil
        lastAliveAt = Date()
        didLockForTimeout = false
        peripheral.discoverServices([heartRateServiceUUID, gapServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Log.write("连接失败: \(peripheral.name ?? "未知"), error: \(error?.localizedDescription ?? "无")")
        isReceiving = false
        persistConnected(false)
        retryOrScan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Log.write("已断开: \(peripheral.name ?? "未知"), error: \(error?.localizedDescription ?? "无")")
        isReceiving = false
        persistConnected(false)
        currentRSSI = nil
        weakSignalSeconds = 0
        didLockForWeakSignal = false
        retryOrScan()
    }

    /// 绑定设备掉线后：优先重连，找不到则重新扫描
    private func retryOrScan() {
        guard activePeripheral != nil else {
            startScanning()
            return
        }
        if tryReconnectBoundPeripheral() == false {
            startScanning()
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Log.write("服务发现失败: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        var foundHeartRate = false
        for service in services {
            switch service.uuid {
            case heartRateServiceUUID:
                foundHeartRate = true
                peripheral.discoverCharacteristics([heartRateMeasurementUUID], for: service)
            case gapServiceUUID:
                peripheral.discoverCharacteristics([deviceNameUUID], for: service)
            default:
                break
            }
        }
        if !foundHeartRate {
            Log.write("\(peripheral.name ?? "未知") 没有标准心率服务 0x180D，该设备无法提供心率")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            Log.write("特征发现失败: \(error.localizedDescription)")
            return
        }
        switch service.uuid {
        case heartRateServiceUUID:
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == heartRateMeasurementUUID }) else {
                Log.write("未找到心率测量特征 0x2A37")
                return
            }
            peripheral.setNotifyValue(true, for: characteristic)
            Log.write("已订阅心率通知: \(peripheral.name ?? "未知")")
        case gapServiceUUID:
            if let nameChar = service.characteristics?.first(where: { $0.uuid == deviceNameUUID }) {
                peripheral.readValue(for: nameChar)
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case heartRateMeasurementUUID:
            if let hr = parseHeartRateMeasurement(data) {
                handleNewHeartRate(hr)
            }
        case deviceNameUUID:
            // 连接后读到真实设备名，替换掉广播里的"未知设备"
            if let name = String(data: data, encoding: .utf8), !name.isEmpty, name != boundDeviceName {
                Log.write("读到设备真实名称: \(name)")
                boundDeviceName = name
                UserDefaults.standard.set(name, forKey: SharedConfig.Keys.boundDeviceName)
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let rssi = RSSI.intValue
        // 127 表示无效读数
        guard rssi != 127 else { return }
        currentRSSI = rssi
        // 读到 RSSI 说明链路活着
        lastAliveAt = Date()
        didLockForTimeout = false

        if rssi < SharedConfig.lockRSSIThreshold {
            weakSignalSeconds += 1
            if weakSignalSeconds >= SharedConfig.weakSignalLockSeconds, !didLockForWeakSignal {
                Log.write("信号持续偏弱（\(rssi) dBm），触发锁屏")
                didLockForWeakSignal = true
                LockScreenManager.lockScreen()
            }
        } else {
            weakSignalSeconds = 0
            didLockForWeakSignal = false
        }
    }

    // MARK: - Scanning

    private func startScanning() {
        guard centralManager.state == .poweredOn else {
            Log.write("跳过扫描，蓝牙未开启: \(centralManager.state.rawValue)")
            return
        }
        centralManager.scanForPeripherals(withServices: nil, options: scanOptions)
        Log.write("开始全量扫描 BLE 广播")
    }

    // MARK: - Heart Rate Parsing

    private func handleNewHeartRate(_ hr: Int) {
        guard hr > 0, hr < 255 else { return }
        currentHeartRate = hr
        isReceiving = true
        lastAliveAt = Date()
        didLockForTimeout = false
        persistHeartRate(hr)
        persistConnected(true)
        checkAbnormalAlert(heartRate: hr)
    }

    /// 异常报警：当心率持续高于设定阈值并达到设定分钟数时，发送通知并执行脚本。
    private func checkAbnormalAlert(heartRate: Int) {
        guard SharedConfig.alertEnabled else {
            heartRateExceededAt = nil
            didTriggerAlert = false
            return
        }

        let threshold = SharedConfig.alertHeartRateThreshold
        let durationSeconds = TimeInterval(SharedConfig.alertDurationMinutes * 60)

        if heartRate > threshold {
            if heartRateExceededAt == nil {
                heartRateExceededAt = Date()
                didTriggerAlert = false
            }
            guard let exceededAt = heartRateExceededAt else { return }
            let elapsed = Date().timeIntervalSince(exceededAt)
            if elapsed >= durationSeconds, !didTriggerAlert {
                didTriggerAlert = true
                Log.write("心率持续高于 \(threshold) BPM 已达 \(Int(elapsed / 60)) 分钟，触发异常报警")
                AlertManager.trigger(heartRate: heartRate)
            }
        } else {
            // 心率恢复阈值以下，重置计时
            if heartRateExceededAt != nil {
                Log.write("心率已恢复到 \(threshold) BPM 以下，重置异常报警计时")
            }
            heartRateExceededAt = nil
            didTriggerAlert = false
        }
    }

    /// 标准 Heart Rate Measurement（0x2A37）格式：
    /// byte0: flags，bit0 表示心率是 uint8 还是 uint16
    private func parseHeartRateMeasurement(_ data: Data) -> Int? {
        guard !data.isEmpty else { return nil }
        let flags = data[0]
        let isUInt16 = (flags & 0x01) != 0
        if isUInt16, data.count >= 3 {
            return Int(data[1]) | (Int(data[2]) << 8)
        } else if data.count >= 2 {
            return Int(data[1])
        }
        return nil
    }

    // MARK: - Persistence

    private func persistHeartRate(_ hr: Int) {
        SharedStore.set(hr, forKey: SharedConfig.Keys.heartRate)
        SharedStore.set(Date().timeIntervalSince1970, forKey: SharedConfig.Keys.lastUpdated)
        SharedConfig.appendHeartRateSample(hr)
        reloadWidgets()
    }

    /// 主动通知 WidgetKit 刷新小组件，让数值尽量接近实时。
    /// 系统对刷新有调度预算，这里再自带 10 秒节流，避免每秒空转。
    private func reloadWidgets() {
        let now = Date()
        guard now.timeIntervalSince(lastWidgetReloadAt) >= 10 else { return }
        lastWidgetReloadAt = now
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func persistConnected(_ connected: Bool) {
        SharedStore.set(connected, forKey: SharedConfig.Keys.isConnected)
    }
}
