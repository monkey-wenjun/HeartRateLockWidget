import Foundation
import AppKit

/// GitHub Release 最新版本信息
struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlUrl: String
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case body
    }

    var version: String {
        tagName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
    }
}

enum UpdateCheckResult: Sendable {
    case noUpdate
    case updateAvailable(GitHubRelease)
    case error(Error)
}

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let repoOwner = "monkey-wenjun"
    private let repoName = "HeartRateLockWidget"
    private let checkInterval: TimeInterval = 24 * 60 * 60
    private let lastCheckKey = "lastUpdateCheckDate"
    private let skipVersionKey = "skippedUpdateVersion"

    private init() {}

    /// 当前安装的版本号
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }

    /// 启动时自动检查，每天最多一次；失败静默。
    func checkForUpdatesIfNeeded() async {
        guard shouldCheckAutomatically() else { return }
        let result = await performCheck()
        await handle(result: result, manual: false)
    }

    /// 用户手动触发检查（菜单或关于窗口）
    func checkForUpdatesManually() async {
        let result = await performCheck()
        await handle(result: result, manual: true)
    }

    private func shouldCheckAutomatically() -> Bool {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        return Date().timeIntervalSince(last) >= checkInterval
    }

    private func performCheck() async -> UpdateCheckResult {
        do {
            let release = try await fetchLatestRelease()
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)

            let skipped = UserDefaults.standard.string(forKey: skipVersionKey)
            guard release.version != skipped else { return .noUpdate }

            if isVersion(release.version, greaterThan: currentVersion) {
                return .updateAvailable(release)
            } else {
                return .noUpdate
            }
        } catch {
            return .error(error)
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else {
            throw NSError(domain: "UpdateChecker", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "服务器返回 HTTP \(statusCode)"])
        }

        let decoder = JSONDecoder()
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    private func isVersion(_ version: String, greaterThan other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending
    }

    private func handle(result: UpdateCheckResult, manual: Bool) async {
        switch result {
        case .noUpdate:
            if manual { showNoUpdateAlert() }
        case .updateAvailable(let release):
            showUpdateAlert(release: release)
        case .error(let error):
            Log.write("检查更新失败: \(error.localizedDescription)")
            if manual { showErrorAlert(error: error) }
        }
    }

    // MARK: - Alerts

    private func showUpdateAlert(release: GitHubRelease) {
        let alert = NSAlert()
        alert.messageText = "发现新版本"
        let notes = (release.body ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmedNotes = String(notes.prefix(500))
        alert.informativeText = "当前版本：\(currentVersion)\n最新版本：\(release.version)\n\n\(trimmedNotes)"
        alert.alertStyle = NSAlert.Style.informational
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "跳过此版本")
        alert.addButton(withTitle: "稍后")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: release.htmlUrl)!)
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(release.version, forKey: skipVersionKey)
        default:
            break
        }
    }

    private func showNoUpdateAlert() {
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "当前版本 \(currentVersion) 已是最新。"
        alert.alertStyle = NSAlert.Style.informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    private func showErrorAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "检查更新失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = NSAlert.Style.warning
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
}
