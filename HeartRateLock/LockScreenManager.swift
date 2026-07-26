import Foundation
import AppKit

/// 简单文件日志：同时写 NSLog 和本地文件，锁屏后也能回看。
/// 文件位置：~/Library/Logs/HeartRateLock.log
enum Log {
    private static let logFileURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent("HeartRateLock.log")
    }()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// 超过 1MB 从头重写，避免无限增长
    private static let maxFileSize: UInt64 = 1_000_000

    static func write(_ message: String) {
        NSLog("%@", message)
        let line = "[\(timestampFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            let offset = (try? handle.seekToEnd()) ?? 0
            if offset > maxFileSize {
                try? handle.truncate(atOffset: 0)
            }
            try? handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
    }
}

enum LockScreenManager {
    private static let lockCommand = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"

    /// 触发 macOS 锁屏，按可靠性依次尝试多种方式
    static func lockScreen() {
        // 1. login.framework 的 SACLockScreenImmediate：新版 macOS 移除了 CGSession，
        //    这个私有接口是目前仍可用的直接锁屏方式。
        if lockViaPrivateFramework() {
            Log.write("已触发锁屏（SACLockScreenImmediate）")
            return
        }

        // 2. 旧系统路径：CGSession -suspend
        if FileManager.default.fileExists(atPath: lockCommand) {
            let task = Process()
            task.launchPath = lockCommand
            task.arguments = ["-suspend"]
            do {
                try task.run()
                Log.write("已触发锁屏（CGSession）")
            } catch {
                Log.write("CGSession 锁屏失败: \(error.localizedDescription)")
            }
            return
        }

        // 3. 兜底：熄灭显示器。系统设置里"唤醒时需要密码"设为立即时等效锁屏。
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["displaysleepnow"]
        do {
            try task.run()
            Log.write("已触发熄屏（pmset displaysleepnow；需在系统设置中将唤醒密码设为立即才等效锁屏）")
        } catch {
            Log.write("所有锁屏方式均失败: \(error.localizedDescription)")
        }
    }

    private static func lockViaPrivateFramework() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY) else {
            Log.write("无法加载 login.framework")
            return false
        }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            Log.write("login.framework 中找不到 SACLockScreenImmediate")
            return false
        }
        typealias LockFunction = @convention(c) () -> Void
        let lock = unsafeBitCast(symbol, to: LockFunction.self)
        lock()
        // 注意不 dlclose：login.framework 加载后需常驻
        return true
    }
}
