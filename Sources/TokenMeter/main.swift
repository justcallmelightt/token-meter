import AppKit
import SwiftUI

@main
struct TokenMeterApp: App {
    @NSApplicationDelegateAdaptor(TokenMeterDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

private final class MeterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private enum AppLanguage {
    static let key = "appLanguage"
    static let defaults = UserDefaults(suiteName: "com.lightframe.TokenMeter") ?? .standard

    static var isKorean: Bool {
        if let selectedLanguage = defaults.string(forKey: key) {
            return selectedLanguage == "ko"
        }
        return Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
    }
}

@MainActor
private final class TokenMeterDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let meter = TokenMeter()
    private var statusItem: NSStatusItem?
    private var panel: MeterPanel?
    private var titleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Token Meter")
        button.image?.isTemplate = true
        button.title = " " + meter.menuTitle
        button.target = self
        button.action = #selector(togglePanel)
        statusItem = item

        titleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTitle() }
        }
    }

    private func updateTitle() {
        statusItem?.button?.title = " " + meter.menuTitle
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
            return
        }

        if panel == nil {
            let window = MeterPanel(contentRect: NSRect(x: 0, y: 0, width: 316, height: 342),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            // The panel's rectangular shadow remains visible outside the rounded glass.
            window.hasShadow = false
            window.level = .popUpMenu
            window.collectionBehavior = [.transient, .moveToActiveSpace]
            window.delegate = self
            let hosting = NSHostingView(rootView: MeterView(meter: meter).frame(width: 316))
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.style = .regular
                glass.cornerRadius = 24
                glass.contentView = NSView()
                glass.alphaValue = 0.94

                let surface = NSView()
                surface.wantsLayer = true
                surface.layer?.cornerRadius = 24
                surface.layer?.masksToBounds = true
                glass.frame = surface.bounds
                glass.autoresizingMask = [.width, .height]
                hosting.frame = surface.bounds
                hosting.autoresizingMask = [.width, .height]
                surface.addSubview(glass)
                surface.addSubview(hosting)
                window.contentView = surface
            } else {
                let backdrop = NSVisualEffectView()
                backdrop.material = .popover
                backdrop.blendingMode = .behindWindow
                backdrop.state = .active
                hosting.frame = backdrop.bounds
                hosting.autoresizingMask = [.width, .height]
                backdrop.addSubview(hosting)
                window.contentView = backdrop
            }
            panel = window
        }

        guard let panel, let button = statusItem?.button, let buttonWindow = button.window else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let height = max(342, panel.contentView?.fittingSize.height ?? 342)
        panel.setContentSize(NSSize(width: 316, height: height))
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(buttonFrame.midX - 158, screenFrame.minX + 8), screenFrame.maxX - 324)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: buttonFrame.minY - 6))
        panel.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        panel?.orderOut(nil)
    }
}

struct Usage: Codable, Equatable, Sendable {
    var input = 0
    var output = 0
    var cached = 0

    var total: Int { input + output }

    static func - (lhs: Usage, rhs: Usage) -> Usage {
        Usage(input: max(0, lhs.input - rhs.input),
              output: max(0, lhs.output - rhs.output),
              cached: max(0, lhs.cached - rhs.cached))
    }

    mutating func add(_ other: Usage) {
        input += other.input
        output += other.output
        cached += other.cached
    }
}

struct ViewedUsage: Codable, Equatable {
    var today: Usage
    var allTime: Usage
    var viewedAt: Date

    func hasSameCounts(as other: ViewedUsage) -> Bool {
        today == other.today && allTime == other.allTime
    }
}

@Observable
@MainActor
final class TokenMeter {
    var today = Usage()
    var allTime = Usage()
    var sessionCount = 0
    var lastUpdated: Date?
    var error: String?
    var isLoading = false

    var menuTitle: String {
        if AppLanguage.isKorean {
            return today.total == 0 ? "토큰" : today.total.compact + " 오늘"
        }
        return today.total == 0 ? "Tokens" : today.total.compact + " today"
    }

    private static let viewedUsageKey = "lastViewedUsage.v1"
    private static let scanCacheKey = "scanCache.v1"
    private static let preferences = UserDefaults(suiteName: "com.lightframe.TokenMeter") ?? .standard
    @ObservationIgnored private var scanCache: ScanCache?

    var currentUsage: ViewedUsage {
        ViewedUsage(today: today, allTime: allTime, viewedAt: Date())
    }

    func lastViewedUsage() -> ViewedUsage? {
        guard let data = Self.preferences.data(forKey: Self.viewedUsageKey) else { return nil }
        return try? JSONDecoder().decode(ViewedUsage.self, from: data)
    }

    func rememberViewedUsage(_ usage: ViewedUsage) {
        guard let data = try? JSONEncoder().encode(usage) else { return }
        Self.preferences.set(data, forKey: Self.viewedUsageKey)
    }

    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex/sessions", directoryHint: .isDirectory)

    init() {
        if let data = Self.preferences.data(forKey: Self.scanCacheKey) {
            scanCache = try? JSONDecoder().decode(ScanCache.self, from: data)
        }
        if let scanCache {
            let isToday = Calendar.current.isDateInToday(scanCache.dayStart)
            for file in scanCache.files.values {
                allTime.add(file.allTime)
                if isToday { today.add(file.today) }
                if file.latest != nil { sessionCount += 1 }
            }
            lastUpdated = Date()
        }
        Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refresh() async {
        if isLoading {
            while isLoading {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return
        }
        isLoading = true
        let previousCache = scanCache
        let result = await Task.detached(priority: .utility) { [root] in
            UsageScanner.scan(root: root, previous: previousCache)
        }.value
        if let newCache = result.cache {
            if newCache != scanCache, let data = try? JSONEncoder().encode(newCache) {
                Self.preferences.set(data, forKey: Self.scanCacheKey)
            }
            scanCache = newCache
        }
        today = result.today
        allTime = result.allTime
        sessionCount = result.count
        error = result.error
        lastUpdated = Date()
        isLoading = false
    }
}

private extension Int {
    var compact: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fk", Double(self) / 1_000) }
        return formatted()
    }
}

private struct MeterView: View {
    let meter: TokenMeter
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppLanguage.key, store: AppLanguage.defaults) private var selectedLanguage = ""
    @State private var displayed: ViewedUsage?
    @State private var settled: ViewedUsage?
    @State private var isOpen = false
    @State private var acceptingUpdates = false
    @State private var openingID = 0

    private var isKorean: Bool { AppLanguage.isKorean }

    var body: some View {
        Group {
            if let displayed {
                content(displayed)
            } else {
                ProgressView(isKorean ? "기록 읽는 중" : "Loading records")
                    .font(AppFont.regular(12))
                    .frame(maxWidth: .infinity)
                    .frame(height: 248)
            }
        }
        .onAppear {
            if NSApplication.shared.keyWindow?.isVisible == true {
                openPresentation()
            }
        }
        .onDisappear {
            closePresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard (notification.object as? NSWindow)?.isVisible == true else { return }
            openPresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            closePresentation()
        }
        .onChange(of: meter.lastUpdated) { _, _ in
            guard isOpen && acceptingUpdates else { return }
            showCurrentUsage(for: openingID)
        }
    }

    @MainActor
    private func openPresentation() {
        guard !isOpen else { return }
        isOpen = true
        acceptingUpdates = false
        openingID += 1
        if var previous = meter.lastViewedUsage() {
            if !Calendar.current.isDateInToday(previous.viewedAt) {
                previous.today = Usage()
                previous.viewedAt = Date()
            }
            displayed = previous
            settled = previous
        } else if meter.lastUpdated != nil, meter.error == nil {
            let latestKnown = meter.currentUsage
            displayed = latestKnown
            settled = latestKnown
        }
        let currentOpening = openingID
        Task { await preparePresentation(for: currentOpening) }
    }

    @MainActor
    private func closePresentation() {
        guard isOpen else { return }
        isOpen = false
        acceptingUpdates = false
        openingID += 1
        if meter.error == nil, let settled {
            meter.rememberViewedUsage(settled)
        }
        displayed = nil
        settled = nil
    }

    @MainActor
    private func preparePresentation(for opening: Int) async {
        await meter.refresh()
        guard isOpen && openingID == opening else { return }

        let latest = meter.currentUsage
        guard meter.error == nil else {
            displayed = latest
            acceptingUpdates = true
            return
        }

        var previous = settled ?? meter.lastViewedUsage() ?? latest
        if !Calendar.current.isDate(previous.viewedAt, inSameDayAs: latest.viewedAt) {
            previous.today = Usage()
            previous.viewedAt = latest.viewedAt
        }
        displayed = previous
        settled = previous

        if previous.hasSameCounts(as: latest) {
            acceptingUpdates = true
            meter.rememberViewedUsage(previous)
            return
        }

        // Let the previous value render before the wheels receive the new target.
        try? await Task.sleep(for: .milliseconds(90))
        guard isOpen && openingID == opening else { return }
        acceptingUpdates = true
        showCurrentUsage(for: opening)
    }

    @MainActor
    private func showCurrentUsage(for opening: Int) {
        guard meter.error == nil else { return }
        let latest = meter.currentUsage
        guard let displayed, !displayed.hasSameCounts(as: latest) else { return }
        self.displayed = latest

        Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard isOpen, openingID == opening,
                  let displayed = self.displayed,
                  displayed.hasSameCounts(as: latest) else { return }
            settled = latest
            meter.rememberViewedUsage(latest)
        }
    }

    private func content(_ shown: ViewedUsage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(colorScheme == .dark ? Color(white: 0.11) : .white)
                    .frame(width: 36, height: 36)
                    .background(colorScheme == .dark ? Color(white: 0.88) : Color(white: 0.18),
                                in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Token Meter").font(AppFont.semibold(14))
                    Text(isKorean ? "로컬 Codex 사용량" : "Local Codex usage")
                        .font(AppFont.regular(11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    selectedLanguage = isKorean ? "en" : "ko"
                } label: {
                    Text(isKorean ? "EN" : "한")
                        .font(AppFont.semibold(11))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PressStyle())
                .help(isKorean ? "영어로 보기" : "한국어로 보기")
                Button { Task { await meter.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                    .font(AppFont.semibold(12))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PressStyle())
                .help(isKorean ? "새로고침" : "Refresh")
                .disabled(meter.isLoading)
            }
            .padding(.bottom, 20)

            Text(isKorean ? "오늘" : "TODAY").font(AppFont.semibold(10))
                .tracking(1.6).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                RollingCounter(value: shown.today.total, size: 38, font: AppFont.semibold(38))
                    .tracking(-1.6)
                Text(isKorean ? "토큰" : "tokens").font(AppFont.regular(13)).foregroundStyle(.secondary)
            }
            .padding(.top, 3)
            .padding(.bottom, 18)

            HStack(spacing: 8) {
                metric(isKorean ? "입력" : "Input", value: shown.today.input)
                metric(isKorean ? "출력" : "Output", value: shown.today.output)
            }

            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1).padding(.vertical, 18)

            HStack {
                Text(isKorean ? "전체 기록" : "All-time").foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    RollingCounter(value: shown.allTime.total, size: 12, font: AppFont.medium(12))
                    Text(isKorean ? "토큰" : "tokens")
                }
            }
            .font(AppFont.regular(12))
            .padding(.bottom, 8)
            HStack {
                Text(isKorean ? "오늘 캐시 입력" : "Today's cached input").foregroundStyle(.secondary)
                Spacer()
                RollingCounter(value: shown.today.cached, size: 12, font: AppFont.medium(12))
            }
            .font(AppFont.regular(12))

            if let error = meter.error {
                Text(localizedError(error)).font(AppFont.regular(11)).foregroundStyle(.orange)
                    .padding(.top, 14)
            }

            HStack {
                Text(isKorean ? "로컬 세션 \(meter.sessionCount)개" : "\(meter.sessionCount) local sessions")
                Spacer()
                if let date = meter.lastUpdated {
                    Text(isKorean ? "업데이트 \(date, style: .time)" : "Updated \(date, style: .time)")
                }
            }
            .font(AppFont.regular(10))
            .foregroundStyle(.tertiary)
            .padding(.top, 18)
        }
        .padding(20)
        .modifier(MeterGlassSurface(colorScheme: colorScheme))
    }

    private func localizedError(_ error: String) -> String {
        guard !isKorean else { return error }
        switch error {
        case "Codex 기록 폴더를 찾을 수 없습니다.":
            return "The Codex sessions folder could not be found."
        case "Codex 기록 폴더를 읽을 수 없습니다.":
            return "The Codex sessions folder could not be read."
        default:
            return error
        }
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Circle().fill(.primary.opacity(0.48)).frame(width: 6, height: 6)
                Text(title).foregroundStyle(.secondary)
            }
            .font(AppFont.regular(11))
            RollingCounter(value: value, size: 17, font: AppFont.semibold(17))
                .tracking(-0.4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(.primary.opacity(colorScheme == .dark ? 0.06 : 0.045),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MeterGlassSurface: ViewModifier {
    let colorScheme: ColorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(LinearGradient(
                            colors: [.clear, .clear, .black.opacity(colorScheme == .dark ? 0.16 : 0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(.white.opacity(colorScheme == .dark ? 0.22 : 0.32), lineWidth: 1)
                }
        } else {
            content.background {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.regularMaterial)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(.white.opacity(colorScheme == .dark ? 0.18 : 0.6), lineWidth: 1)
                    }
            }
        }
    }
}

private struct RollingCounter: View {
    let value: Int
    let size: CGFloat
    let font: Font

    private var digitCount: Int { max(1, String(max(0, value)).count) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array((0..<digitCount).reversed()), id: \.self) { power in
                DigitWheel(value: value, power: power, size: size, font: font)
                if power > 0 && power.isMultiple(of: 3) {
                    Text(",").font(font)
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(max(0, value).formatted())
    }
}

private struct DigitWheel: View {
    let value: Int
    let power: Int
    let size: CGFloat
    let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trackPosition: Int
    @State private var animationGeneration = 0

    private var rowHeight: CGFloat { size * 1.16 }
    private var trackDigits: [Int] { [9] + Array(0...9) + Array(0...9) + [0] }

    init(value: Int, power: Int, size: CGFloat, font: Font) {
        self.value = value
        self.power = power
        self.size = size
        self.font = font
        _trackPosition = State(initialValue: Self.digit(in: value, at: power) + 1)
    }

    var body: some View {
        Group {
            if reduceMotion {
                Text(String(Self.digit(in: value, at: power)))
                    .font(font)
                    .frame(width: size * 0.64, height: rowHeight)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: value)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(trackDigits.enumerated()), id: \.offset) { row in
                        Text(String(row.element))
                            .font(font)
                            .frame(width: size * 0.64, height: rowHeight)
                            .fixedSize()
                    }
                }
                .offset(y: -CGFloat(trackPosition) * rowHeight)
                .frame(width: size * 0.64, height: rowHeight, alignment: .top)
                .clipped()
            }
        }
        .accessibilityHidden(true)
        .onChange(of: value) { oldValue, newValue in
            let oldDigit = Self.digit(in: oldValue, at: power)
            let newDigit = Self.digit(in: newValue, at: power)
            guard oldDigit != newDigit else { return }

            if reduceMotion {
                trackPosition = newDigit + 1
                return
            }

            let movingForward = newValue >= oldValue
            var destination = newDigit + 1
            if movingForward && newDigit < oldDigit {
                destination += 10
            } else if !movingForward && newDigit > oldDigit {
                destination -= 10
            }

            animationGeneration += 1
            let generation = animationGeneration
            withAnimation(.spring(response: 0.34, dampingFraction: 1), completionCriteria: .logicallyComplete) {
                trackPosition = destination
            } completion: {
                guard generation == animationGeneration,
                      destination < 1 || destination > 10 else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    trackPosition = newDigit + 1
                }
            }
        }
    }

    private static func digit(in value: Int, at power: Int) -> Int {
        let place = (0..<power).reduce(1) { partial, _ in partial * 10 }
        return (max(0, value) / place) % 10
    }
}

private enum AppFont {
    static func regular(_ size: CGFloat) -> Font { .custom("Pretendard-Regular", size: size) }
    static func medium(_ size: CGFloat) -> Font { .custom("Pretendard-Medium", size: size) }
    static func semibold(_ size: CGFloat) -> Font { .custom("Pretendard-SemiBold", size: size) }
}

private struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 8))
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.94 : 1))
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 1), value: configuration.isPressed)
    }
}
