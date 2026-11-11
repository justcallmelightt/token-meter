import AppKit
import Foundation
import Observation

struct LimitWindow: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var usedPercent: Double
    var resetsAt: Date?
}

struct LimitSnapshot: Codable, Equatable, Sendable {
    var windows: [LimitWindow]
    var updatedAt: Date
}

struct ReleaseSnapshot: Codable, Equatable, Sendable {
    var version: String
    var url: URL
}

enum LimitPreference {
    static let codex = "showCodexLimits"
    static let claude = "showClaudeLimits"
    static let updates = "checkForUpdates"
}

@Observable
@MainActor
final class LimitMonitor {
    static let shared = LimitMonitor()

    var codex: LimitSnapshot?
    var claude: LimitSnapshot?
    var release: ReleaseSnapshot?
    var lastUpdateCheck: Date?
    var codexMessage: String?
    var updateMessage: String?
    var isCheckingUpdates = false
    var isCheckingCodex = false
    var claudeBridgeInstalled = false

    @ObservationIgnored private let defaults = UserDefaults(suiteName: "com.lightframe.TokenMeter") ?? .standard
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var lastUpdateAttempt: Date?

    private init() {
        if let data = defaults.data(forKey: "codexLimitSnapshot.v1") {
            codex = try? JSONDecoder().decode(LimitSnapshot.self, from: data)
        }
        if let data = defaults.data(forKey: "claudeLimitSnapshot.v1") {
            claude = try? JSONDecoder().decode(LimitSnapshot.self, from: data)
        }
        lastUpdateCheck = defaults.object(forKey: "lastUpdateCheck.v1") as? Date
        lastUpdateAttempt = defaults.object(forKey: "lastUpdateAttempt.v1") as? Date
        claudeBridgeInstalled = ClaudeStatuslineBridge.isInstalled()
        if claudeBridgeInstalled { try? ClaudeStatuslineBridge.install() }
        refreshClaudeSnapshot()
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if enabled(LimitPreference.codex) {
                    await refreshCodex()
                }
                refreshClaudeSnapshot()
                if enabled(LimitPreference.updates), shouldCheckForUpdates {
                    await checkForUpdates()
                }
                try? await Task.sleep(for: .seconds(180))
            }
        }
    }

    func refreshVisibleProviders() async {
        if enabled(LimitPreference.codex) {
            await refreshCodex()
        }
        refreshClaudeSnapshot()
    }

    func refreshCodex() async {
        guard !isCheckingCodex else { return }
        isCheckingCodex = true
        defer { isCheckingCodex = false }
        do {
            let snapshot = try await CodexRateLimitReader.read()
            codex = snapshot
            codexMessage = nil
            if let data = try? JSONEncoder().encode(snapshot) {
                defaults.set(data, forKey: "codexLimitSnapshot.v1")
            }
        } catch {
            codexMessage = error.localizedDescription
        }
    }

    func refreshClaudeSnapshot() {
        claudeBridgeInstalled = ClaudeStatuslineBridge.isInstalled()
        guard let data = try? Data(contentsOf: ClaudeStatuslineBridge.snapshotURL),
              let snapshot = try? JSONDecoder().decode(LimitSnapshot.self, from: data) else { return }
        claude = snapshot
        defaults.set(data, forKey: "claudeLimitSnapshot.v1")
    }

    func configureClaudeBridge() throws {
        try ClaudeStatuslineBridge.install()
        claudeBridgeInstalled = true
    }

    func removeClaudeBridge() throws {
        try ClaudeStatuslineBridge.remove()
        claudeBridgeInstalled = false
        claude = nil
        defaults.removeObject(forKey: "claudeLimitSnapshot.v1")
    }

    func checkForUpdates() async {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer {
            isCheckingUpdates = false
            lastUpdateAttempt = Date()
            defaults.set(lastUpdateAttempt, forKey: "lastUpdateAttempt.v1")
        }
        release = nil
        updateMessage = nil
        do {
            let endpoint = URL(string: "https://api.github.com/repos/justcallmelightt/token-meter/releases/latest")!
            var request = URLRequest(url: endpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("TokenMeter/0.2", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw ProviderError.remoteUnavailable
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let urlString = json["html_url"] as? String,
                  let url = URL(string: urlString) else { throw ProviderError.invalidResponse }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
            release = Self.isNewer(latest, than: current) ? ReleaseSnapshot(version: tag, url: url) : nil
            lastUpdateCheck = Date()
            defaults.set(lastUpdateCheck, forKey: "lastUpdateCheck.v1")
        } catch {
            updateMessage = error.localizedDescription
        }
    }

    func openRelease() {
        guard let release else { return }
        NSWorkspace.shared.open(release.url)
    }

    private var shouldCheckForUpdates: Bool {
        guard let last = lastUpdateAttempt else { return true }
        return Date().timeIntervalSince(last) > 6 * 60 * 60
    }

    private func enabled(_ key: String) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    private static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let left = parts(lhs), right = parts(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

private enum ProviderError: LocalizedError {
    case cliNotFound
    case remoteUnavailable
    case invalidResponse
    case noLimits
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound: return "Codex CLI를 찾을 수 없습니다."
        case .remoteUnavailable: return "최신 버전을 확인할 수 없습니다."
        case .invalidResponse: return "서비스 응답을 읽을 수 없습니다."
        case .noLimits: return "Codex 계정 한도 정보를 사용할 수 없습니다."
        case .rpc(let message): return message
        }
    }
}

private enum CodexRateLimitReader {
    static func read() async throws -> LimitSnapshot {
        try await Task.detached(priority: .utility) { try readSynchronously() }.value
    }

    private static func readSynchronously() throws -> LimitSnapshot {
        guard let executable = findCodex() else { throw ProviderError.cliNotFound }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let messages = [
            ["method": "initialize", "id": 0, "params": ["clientInfo": ["name": "token_meter", "title": "Token Meter", "version": "0.2.0"]]] as [String: Any],
            ["method": "initialized", "params": [:]] as [String: Any],
            ["method": "account/rateLimits/read", "id": 2, "params": [:]] as [String: Any]
        ]
        for message in messages {
            var data = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
            data.append(0x0A)
            input.fileHandleForWriting.write(data)
        }
        try? input.fileHandleForWriting.close()

        let responseData = output.fileHandleForReading.readDataToEndOfFile()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        for line in String(decoding: responseData, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (envelope["id"] as? Int) == 2 else { continue }
            if let error = envelope["error"] as? [String: Any] {
                throw ProviderError.rpc(error["message"] as? String ?? "Codex 한도를 읽지 못했습니다.")
            }
            guard let result = envelope["result"] as? [String: Any] else { throw ProviderError.noLimits }
            let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
            let sources = buckets.map { $0.keys.sorted().compactMap { $0 == "codex" || $0 == "codex_other" ? $0 : nil }.compactMap { buckets?[$0] } }
                ?? (result["rateLimits"] as? [String: Any]).map { [$0] }
                ?? []
            let windows = sources.flatMap { bucket -> [LimitWindow] in
                ["primary", "secondary"].compactMap { key in
                    guard let window = bucket[key] as? [String: Any],
                          let percent = (window["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
                    let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
                    let name = minutes.map(Self.windowName(minutes:)) ?? key.capitalized
                    let reset = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    let limitID = bucket["limitId"] as? String ?? "codex"
                    return LimitWindow(id: "\(limitID)-\(key)", title: name,
                                       usedPercent: min(max(percent, 0), 100), resetsAt: reset)
                }
            }
            guard !windows.isEmpty else { throw ProviderError.noLimits }
            return LimitSnapshot(windows: windows, updatedAt: Date())
        }
        throw ProviderError.noLimits
    }

    private static func findCodex() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func windowName(minutes: Int) -> String {
        if minutes == 300 { return "5h" }
        if minutes == 10_080 { return "7d" }
        if minutes >= 60 && minutes.isMultiple(of: 60) { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

enum ClaudeStatuslineBridge {
    private struct Backup: Codable {
        var hadStatusLine: Bool
        var previousStatusLine: Data?
        var command: String
    }

    static var snapshotURL: URL { supportDirectory.appending(path: "claude-limits.json") }
    private static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Token Meter", directoryHint: .isDirectory)
    }
    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json")
    }
    private static var scriptURL: URL { supportDirectory.appending(path: "claude-statusline.sh") }
    private static var originalCommandURL: URL { supportDirectory.appending(path: "claude-statusline-original-command") }
    private static var backupURL: URL { supportDirectory.appending(path: "claude-statusline-backup.json") }

    static func captureStatuslineInput() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return }
        let windows = ["five_hour", "seven_day"].compactMap { key -> LimitWindow? in
            guard let item = limits[key] as? [String: Any],
                  let percent = (item["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (item["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return LimitWindow(id: key, title: key == "five_hour" ? "5h" : "7d",
                               usedPercent: min(max(percent, 0), 100), resetsAt: reset)
        }
        guard !windows.isEmpty,
              let encoded = try? JSONEncoder().encode(LimitSnapshot(windows: windows, updatedAt: Date())) else { return }
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
        try? encoded.write(to: snapshotURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
    }

    static func isInstalled() -> Bool {
        guard let root = try? readSettings(),
              let status = root["statusLine"] as? [String: Any],
              let command = status["command"] as? String else { return false }
        return command == scriptURL.path || command == shellQuote(scriptURL.path)
            || command == "\"\(scriptURL.path)\""
    }

    static func install() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root = try readSettings()
        let previous = root["statusLine"]
        if let status = previous as? [String: Any],
           let command = status["command"] as? String,
           command == scriptURL.path || command == shellQuote(scriptURL.path) {
            try writeBridgeScript()
            return
        }
        let originalCommand = (previous as? [String: Any])?["command"] as? String ?? ""
        let previousData = previous.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
        let installedCommand = shellQuote(scriptURL.path)
        let backup = Backup(hadStatusLine: previous != nil, previousStatusLine: previousData, command: installedCommand)
        let encoder = JSONEncoder()
        try encoder.encode(backup).write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        try Data(originalCommand.utf8).write(to: originalCommandURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalCommandURL.path)
        try writeBridgeScript()

        var status = previous as? [String: Any] ?? [:]
        status["type"] = "command"
        status["command"] = installedCommand
        root["statusLine"] = status
        try writeSettings(root)
    }

    static func remove() throws {
        guard let data = try? Data(contentsOf: backupURL),
              let backup = try? JSONDecoder().decode(Backup.self, from: data) else { return }
        var root = try readSettings()
        guard let current = root["statusLine"] as? [String: Any],
              current["command"] as? String == backup.command else { throw ProviderError.rpc("Claude Code의 상태줄 설정이 변경되어 자동으로 되돌리지 않았습니다.") }
        if backup.hadStatusLine, let previousData = backup.previousStatusLine {
            root["statusLine"] = try JSONSerialization.jsonObject(with: previousData, options: [.fragmentsAllowed])
        } else {
            root.removeValue(forKey: "statusLine")
        }
        try writeSettings(root)
        for url in [backupURL, originalCommandURL, scriptURL, snapshotURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func writeBridgeScript() throws {
        guard let executable = Bundle.main.executableURL?.path else { throw ProviderError.invalidResponse }
        let script = """
        #!/bin/sh
        input=$(/bin/cat)
        printf '%s' "$input" | \(shellQuote(executable)) --claude-usage-bridge
        if [ -s \(shellQuote(originalCommandURL.path)) ]; then
          original=$(/bin/cat \(shellQuote(originalCommandURL.path)))
          printf '%s' "$input" | /bin/zsh -lc "$original"
        fi
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.rpc("Claude Code 설정 파일의 JSON 형식을 확인해주세요.")
        }
        return root
    }

    private static func writeSettings(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let currentPermissions = (try? FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions]) as? NSNumber
        try data.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: currentPermissions ?? NSNumber(value: 0o600)],
            ofItemAtPath: settingsURL.path
        )
    }
}
