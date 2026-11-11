import SwiftUI

@MainActor
private enum SettingsDefaults {
    static let shared = UserDefaults(suiteName: "com.lightframe.TokenMeter") ?? .standard
}

struct TokenMeterSettingsView: View {
    @Bindable var limits: LimitMonitor
    @AppStorage(LimitPreference.codex, store: SettingsDefaults.shared) private var showCodexLimits = true
    @AppStorage(LimitPreference.claude, store: SettingsDefaults.shared) private var showClaudeLimits = true
    @AppStorage(LimitPreference.updates, store: SettingsDefaults.shared) private var checkForUpdates = true
    @State private var claudeError: String?
    @State private var showRemoveConfirmation = false

    private var isKorean: Bool { AppLanguage.isKorean }
    private var updateStatusLabel: String {
        guard limits.lastUpdateCheck != nil else {
            return isKorean ? "최신 공개 버전 확인" : "Check the latest published version"
        }
        return isKorean ? "최신 버전을 사용 중입니다" : "You're up to date"
    }

    var body: some View {
        Form {
            Section(isKorean ? "업데이트" : "Updates") {
                Toggle(isKorean ? "새 버전 자동 확인" : "Check for updates automatically", isOn: $checkForUpdates)
                HStack {
                    if limits.isCheckingUpdates {
                        ProgressView().controlSize(.small)
                    } else if let release = limits.release {
                        Label(isKorean ? "새 버전 \(release.version)" : "Version \(release.version) is available", systemImage: "arrow.down.circle")
                        Spacer()
                        Button(isKorean ? "다운로드" : "Download") { limits.openRelease() }
                    } else {
                        Text(limits.updateMessage ?? updateStatusLabel)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Button(isKorean ? "지금 확인" : "Check now") {
                        Task { await limits.checkForUpdates() }
                    }
                    .disabled(limits.isCheckingUpdates)
                }
            }

            Section(isKorean ? "Codex 한도" : "Codex limits") {
                Toggle(isKorean ? "메뉴 막대 창에 표시" : "Show in menu bar panel", isOn: $showCodexLimits)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(limits.codex == nil ? (isKorean ? "Codex 연결 상태 확인" : "Codex connection status") : (isKorean ? "Codex 계정 한도 연결됨" : "Connected to Codex account limits"))
                        if let message = limits.codexMessage {
                            Text(localized(message)).font(.caption).foregroundStyle(.secondary)
                        } else if let date = limits.codex?.updatedAt {
                            Text(isKorean ? "마지막 확인 \(date, style: .relative)" : "Checked \(date, style: .relative)")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(isKorean ? "Codex CLI의 로컬 계정 세션을 사용합니다." : "Uses the local account session from Codex CLI.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(isKorean ? "새로고침" : "Refresh") {
                        Task { await limits.refreshCodex() }
                    }
                    .disabled(limits.isCheckingCodex)
                }
            }

            Section(isKorean ? "Claude Code 한도" : "Claude Code limits") {
                Toggle(isKorean ? "메뉴 막대 창에 표시" : "Show in menu bar panel", isOn: $showClaudeLimits)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(limits.claudeBridgeInstalled
                             ? (isKorean ? "Claude Code 연결됨" : "Claude Code connected")
                             : (isKorean ? "상태줄 연결이 필요합니다" : "Status line connection required"))
                        Text(limits.claudeBridgeInstalled
                             ? (isKorean ? "Claude Code 세션이 실행되면 한도가 갱신됩니다." : "Limits update while a Claude Code session is running.")
                             : (isKorean ? "공식 상태줄 데이터로 세션·주간 한도를 읽습니다." : "Reads session and weekly limits from Claude Code's status line data."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if limits.claudeBridgeInstalled {
                        Button(isKorean ? "연결 해제" : "Disconnect", role: .destructive) {
                            showRemoveConfirmation = true
                        }
                    } else {
                        Button(isKorean ? "Claude Code 연결" : "Connect Claude Code") {
                            do {
                                try limits.configureClaudeBridge()
                                claudeError = nil
                            } catch {
                                claudeError = error.localizedDescription
                            }
                        }
                    }
                }
                if let claudeError {
                    Text(localized(claudeError)).font(.caption).foregroundStyle(.red)
                }
                if let snapshot = limits.claude {
                    Text(isKorean ? "마지막 데이터 \(snapshot.updatedAt, style: .relative)" : "Last data \(snapshot.updatedAt, style: .relative)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(isKorean ? "데이터 처리" : "Data access") {
                Text(isKorean
                     ? "Codex 한도는 Codex CLI app-server에서 읽습니다. Claude 한도는 Claude Code의 상태줄 입력을 이 Mac 안에 저장합니다. Token Meter는 세션 본문이나 인증 토큰을 저장하지 않습니다."
                     : "Codex limits come from the Codex CLI app-server. Claude limits are copied from Claude Code status line input and kept on this Mac. Token Meter does not store session transcripts or authentication tokens.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 10)
        .frame(width: 470, height: 560)
        .font(AppFont.regular(12))
        .onChange(of: checkForUpdates) { _, enabled in
            guard enabled else { return }
            Task { await limits.checkForUpdates() }
        }
        .onChange(of: showCodexLimits) { _, enabled in
            guard enabled else { return }
            Task { await limits.refreshCodex() }
        }
        .confirmationDialog(
            isKorean ? "Claude Code 설정에서 Token Meter 상태줄 연결을 제거할까요?" : "Remove the Token Meter status line from Claude Code settings?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(isKorean ? "연결 해제" : "Disconnect", role: .destructive) {
                do {
                    try limits.removeClaudeBridge()
                    claudeError = nil
                } catch {
                    claudeError = error.localizedDescription
                }
            }
            Button(isKorean ? "취소" : "Cancel", role: .cancel) {}
        } message: {
            Text(isKorean ? "연결 전에 사용하던 상태줄 설정은 그대로 복원됩니다." : "Your previous status line configuration will be restored.")
        }
    }

    private func localized(_ message: String) -> String {
        guard isKorean else {
            if message == "Codex CLI를 찾을 수 없습니다." { return "Codex CLI could not be found." }
            if message == "최신 버전을 확인할 수 없습니다." { return "Could not check for updates." }
            return message
        }
        return message
    }
}

struct UsageLimitsCompactView: View {
    let limits: LimitMonitor
    let isKorean: Bool
    @AppStorage(LimitPreference.codex, store: SettingsDefaults.shared) private var showCodex = true
    @AppStorage(LimitPreference.claude, store: SettingsDefaults.shared) private var showClaude = true

    private var visibleProviders: [(String, LimitSnapshot?, String?)] {
        var providers: [(String, LimitSnapshot?, String?)] = []
        if showCodex { providers.append(("Codex", limits.codex, limits.codexMessage)) }
        if showClaude { providers.append(("Claude", limits.claude, nil)) }
        return providers
    }

    var body: some View {
        if !visibleProviders.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(visibleProviders, id: \.0) { name, snapshot, message in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(name).font(AppFont.semibold(10))
                            Spacer()
                            if let snapshot {
                                Text(snapshot.updatedAt, style: .time)
                                    .font(AppFont.regular(9)).foregroundStyle(.tertiary)
                            }
                        }
                        if let snapshot, !snapshot.windows.isEmpty {
                            ForEach(snapshot.windows) { window in
                                quotaLine(window)
                            }
                        } else {
                            Text(emptyMessage(for: name, message: message))
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func quotaLine(_ window: LimitWindow) -> some View {
        HStack(spacing: 7) {
            Text(window.title).font(AppFont.medium(9)).foregroundStyle(.secondary)
                .frame(width: 25, alignment: .leading)
            GeometryReader { geometry in
                Capsule().fill(.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.45))
                            .frame(width: geometry.size.width * window.usedPercent / 100)
                    }
            }
            .frame(height: 4)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(AppFont.semibold(9).monospacedDigit())
                .frame(width: 29, alignment: .trailing)
            if let reset = window.resetsAt {
                Text(reset, style: .relative).font(AppFont.regular(8)).foregroundStyle(.tertiary)
                    .lineLimit(1).frame(width: 47, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func emptyMessage(for provider: String, message: String?) -> String {
        if provider == "Claude" && !limits.claudeBridgeInstalled {
            return isKorean ? "설정에서 Claude Code 연결" : "Connect Claude Code in Settings"
        }
        if let message, provider == "Codex" {
            if !isKorean && message == "Codex CLI를 찾을 수 없습니다." { return "Codex CLI not found" }
            if !isKorean && message == "Codex 계정 한도 정보를 사용할 수 없습니다." { return "Codex limits unavailable" }
            return message
        }
        if provider == "Claude" {
            return isKorean ? "Claude Code 세션에서 데이터 대기 중" : "Waiting for a Claude Code session"
        }
        return limits.isCheckingCodex
            ? (isKorean ? "Codex 한도 확인 중" : "Checking Codex limits")
            : (isKorean ? "Codex 한도 대기 중" : "Waiting for Codex limits")
    }
}
