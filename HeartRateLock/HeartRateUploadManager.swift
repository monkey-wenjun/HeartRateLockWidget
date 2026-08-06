import Foundation

/// 心率上报：把蓝牙读到的心率 POST 到用户配置的 API。
/// 请求格式与示例一致：
///   POST {apiURL}
///   Authorization: Bearer {token}（可选）
///   Content-Type: application/json
///   {"heart_rate": 67, "timestamp": 1785994000000, "device_id": "...", "source": "bluetooth"}
@MainActor
final class HeartRateUploadManager {
    static let shared = HeartRateUploadManager()

    /// 上次成功上报的时间（节流：心率约 1Hz 推送，按配置间隔合并）
    private var lastUploadAt: Date?

    private init() {}

    /// 收到新心率时调用；开关关闭、URL 未配置或未到间隔时静默跳过。
    /// 返回 true 表示本次实际发起了请求（测试按钮也用它区分结果）。
    @discardableResult
    func upload(heartRate: Int, deviceID: String? = nil, force: Bool = false) -> Bool {
        guard SharedConfig.reportEnabled || force else { return false }

        let urlString = SharedConfig.reportAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            Log.write("心率上报跳过：API 地址无效或未配置")
            return false
        }

        if !force {
            let interval = TimeInterval(max(1, SharedConfig.reportIntervalSeconds))
            if let last = lastUploadAt, Date().timeIntervalSince(last) < interval {
                return false
            }
        }

        let payload: [String: Any] = [
            "heart_rate": heartRate,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "device_id": deviceID ?? UserDefaults.standard.string(forKey: SharedConfig.Keys.boundDeviceName) ?? "bluetooth-device",
            "source": "bluetooth"
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            Log.write("心率上报失败：JSON 编码错误")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = SharedConfig.reportAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.timeoutInterval = 15

        let taskDescription = force ? "测试" : "上报"
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                if (error as? URLError)?.code == .timedOut {
                    Log.write("心率\(taskDescription)超时，收到下一条心率时会自动重试")
                }
                Log.write("心率\(taskDescription)失败: \(error.localizedDescription)")
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(statusCode) {
                if !force {
                    Task { @MainActor [weak self] in
                        self?.lastUploadAt = Date()
                    }
                }
                Log.write("心率\(taskDescription)成功（HTTP \(statusCode)）")
            } else {
                let bodyString = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Log.write("心率\(taskDescription)失败: HTTP \(statusCode), \(bodyString)")
            }
        }.resume()
        return true
    }
}
