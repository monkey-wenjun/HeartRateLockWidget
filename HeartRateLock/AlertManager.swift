import Foundation
import UserNotifications
import CryptoKit

/// 异常报警：心率持续高于阈值时发送系统通知，并可执行外部脚本。
@MainActor
enum AlertManager {
    private static var hasRequestedAuthorization = false

    /// 在启动时请求通知权限（仅在首次需要时）
    static func requestNotificationAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.write("请求通知权限失败: \(error.localizedDescription)")
            } else {
                Log.write("通知权限: \(granted ? "已授予" : "被拒绝")")
            }
        }
    }

    /// 触发报警：发送通知、执行脚本、发送群消息
    static func trigger(heartRate: Int, threshold: Int = SharedConfig.alertHeartRateUpperThreshold) {
        if SharedConfig.alertNotifyEnabled {
            sendNotification(heartRate: heartRate, threshold: threshold)
        }
        if SharedConfig.alertRunScriptEnabled {
            runScript(heartRate: heartRate, threshold: threshold)
        }
        if SharedConfig.alertFeishuEnabled {
            sendPlatformMessage(heartRate: heartRate, threshold: threshold)
        }
        SharedConfig.alertLastTriggeredAt = Date()
    }

    private static func sendNotification(heartRate: Int, threshold: Int) {
        let direction = heartRate < threshold ? "低于" : "高于"
        let content = UNMutableNotificationContent()
        content.title = "心率异常"
        content.body = "心率已连续 \(SharedConfig.alertDurationMinutes) 分钟\(direction) \(threshold) BPM，当前 \(heartRate) BPM。"
        content.sound = .default

        let request = UNNotificationRequest(identifier: "heartrate-alert-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.write("发送通知失败: \(error.localizedDescription)")
            } else {
                Log.write("已发送心率异常通知（\(heartRate) BPM）")
            }
        }
    }

    /// 执行用户配置的脚本，支持 Shell 脚本与 Python 脚本，并传入当前心率。
    /// 环境变量 HEART_RATE 与命令行参数 $1 均为当前 BPM。
    private static func runScript(heartRate: Int, threshold: Int) {
        let scriptPath = SharedConfig.alertScriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scriptPath.isEmpty else {
            Log.write("未配置脚本路径，跳过执行")
            return
        }
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            Log.write("脚本文件不存在: \(scriptPath)")
            return
        }

        let task = Process()
        task.environment = (ProcessInfo.processInfo.environment as? [String: String]) ?? [:]
        task.environment?["HEART_RATE"] = "\(heartRate)"
        task.environment?["ALERT_THRESHOLD"] = "\(threshold)"
        task.environment?["ALERT_DURATION_MINUTES"] = "\(SharedConfig.alertDurationMinutes)"

        let lowercased = scriptPath.lowercased()
        if lowercased.hasSuffix(".py") {
            task.launchPath = "/usr/bin/python3"
            task.arguments = [scriptPath, "\(heartRate)"]
        } else {
            // 默认按 Shell 脚本执行（.sh 或无扩展名）
            task.launchPath = "/bin/bash"
            task.arguments = [scriptPath, "\(heartRate)"]
        }

        do {
            try task.run()
            Log.write("已执行脚本: \(scriptPath)（心率 \(heartRate) BPM）")
        } catch {
            Log.write("执行脚本失败: \(scriptPath), error: \(error.localizedDescription)")
        }
    }

    /// 手动测试群消息通道：使用当前平台配置发送一条测试消息。
    static func testPlatformMessage(heartRate: Int = SharedConfig.alertHeartRateUpperThreshold) {
        Log.write("正在手动测试群消息通道…")
        sendPlatformMessage(heartRate: heartRate, threshold: heartRate)
    }

    /// 通过群机器人 Webhook 发送消息，按所选平台处理签名与格式。
    private static func sendPlatformMessage(heartRate: Int, threshold: Int = SharedConfig.alertHeartRateUpperThreshold) {
        let webhookURLString = SharedConfig.alertFeishuWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !webhookURLString.isEmpty, let url = URL(string: webhookURLString) else {
            Log.write("群消息 Webhook URL 无效或未配置，跳过发送")
            return
        }

        let platform = SharedConfig.alertPlatform
        let message = renderPlatformMessage(heartRate: heartRate, threshold: threshold)
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let secret = SharedConfig.alertFeishuSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        var payload: [String: Any]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch platform {
        case .feishu:
            payload = [
                "msg_type": "text",
                "content": ["text": message]
            ]
            payload["timestamp"] = timestamp
            if !secret.isEmpty {
                payload["sign"] = hmacSign(timestamp: timestamp, secret: secret)
            }
        case .dingtalk:
            payload = [
                "msgtype": "text",
                "text": ["content": message]
            ]
            if var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var queryItems = urlComponents.queryItems ?? []
                queryItems.append(URLQueryItem(name: "timestamp", value: timestamp))
                if !secret.isEmpty {
                    queryItems.append(URLQueryItem(name: "sign", value: hmacSign(timestamp: timestamp, secret: secret)))
                }
                urlComponents.queryItems = queryItems
                if let signedURL = urlComponents.url {
                    request.url = signedURL
                }
            }
        case .wecom:
            payload = [
                "msgtype": "text",
                "text": ["content": message]
            ]
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            Log.write("群消息 JSON 编码失败")
            return
        }
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                Log.write("发送\(platform.displayName)消息失败: \(error.localizedDescription)")
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(statusCode) {
                Log.write("已发送\(platform.displayName)消息（HTTP \(statusCode)）")
            } else {
                let bodyString = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Log.write("发送\(platform.displayName)消息失败: HTTP \(statusCode), \(bodyString)")
            }
        }.resume()
    }

    /// 替换群消息模板中的占位符。
    /// 支持 {heartRate} / {hr}、{threshold}、{duration}
    private static func renderPlatformMessage(heartRate: Int, threshold: Int) -> String {
        let template = SharedConfig.alertFeishuMessageTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = template.isEmpty ? SharedConfig.Default.alertFeishuMessageTemplate : template
        let replacements: [String: String] = [
            "{heartRate}": "\(heartRate)",
            "{hr}": "\(heartRate)",
            "{threshold}": "\(threshold)",
            "{duration}": "\(SharedConfig.alertDurationMinutes)"
        ]
        for (placeholder, value) in replacements {
            message = message.replacingOccurrences(of: placeholder, with: value)
        }
        return message
    }

    /// 飞书/钉钉通用签名：Base64(HMAC-SHA256(timestamp + "\n" + secret))
    private static func hmacSign(timestamp: String, secret: String) -> String? {
        guard let secretData = secret.data(using: .utf8),
              let messageData = "\(timestamp)\n\(secret)".data(using: .utf8) else { return nil }
        let signature = HMAC<SHA256>.authenticationCode(for: messageData, using: SymmetricKey(data: secretData))
        return Data(signature).base64EncodedString()
    }
}
