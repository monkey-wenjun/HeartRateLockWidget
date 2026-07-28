import Foundation
import IOKit.pwr_mgt

/// 防熄屏管理：手表信号在线时持有系统断言，阻止显示器自动休眠/锁屏。
@MainActor
enum KeepAwakeManager {
    private static var assertionID: IOPMAssertionID = 0

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            guard assertionID == 0 else { return }
            let result = IOPMAssertionCreateWithDescription(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                "HeartRateLock keep awake" as CFString,
                nil,
                nil,
                nil,
                0,
                kIOPMAssertionTimeoutActionRelease as CFString,
                &assertionID
            )
            if result == kIOReturnSuccess {
                Log.write("已创建防熄屏断言")
            } else {
                Log.write("创建防熄屏断言失败: \(result)")
            }
        } else {
            guard assertionID != 0 else { return }
            let result = IOPMAssertionRelease(assertionID)
            assertionID = 0
            if result == kIOReturnSuccess {
                Log.write("已释放防熄屏断言")
            } else {
                Log.write("释放防熄屏断言失败: \(result)")
            }
        }
    }
}
