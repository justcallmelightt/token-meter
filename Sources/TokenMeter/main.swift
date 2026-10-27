import SwiftUI

@main
struct TokenMeterApp: App {
    @State private var meter = TokenMeter()

    var body: some Scene {
        MenuBarExtra {
            MeterView(meter: meter)
                .frame(width: 316)
        } label: {
            Label {
                Text(meter.menuTitle).font(AppFont.regular(12))
            } icon: {
                Image(systemName: "circle.hexagongrid.fill")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct Usage: Equatable, Sendable {
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

@Observable
@MainActor
final class TokenMeter {
    var today = Usage()
    var allTime = Usage()
    var sessionCount = 0
    var lastUpdated: Date?
    var error: String?
    var isLoading = false

    var menuTitle: String { today.total == 0 ? "Tokens" : today.total.compact + " today" }

    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex/sessions", directoryHint: .isDirectory)

    init() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        let result = await Task.detached(priority: .utility) { [root] in
            Self.scan(root: root)
        }.value
        today = result.today
        allTime = result.allTime
        sessionCount = result.count
        error = result.error
        lastUpdated = Date()
        isLoading = false
    }

    nonisolated private static func scan(root: URL) -> (today: Usage, allTime: Usage, count: Int, error: String?) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else {
            return (Usage(), Usage(), 0, "Codex 기록 폴더를 찾을 수 없습니다.")
        }
        guard let files = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return (Usage(), Usage(), 0, "Codex 기록 폴더를 읽을 수 없습니다.")
        }

        var today = Usage()
        var allTime = Usage()
        var count = 0
        let calendar = Calendar.current
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var previous = Usage()
            var found = false

            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let record = try? JSONDecoder().decode(LogRecord.self, from: data),
                      record.payload.type == "token_count",
                      let current = record.payload.info?.totalTokenUsage else { continue }
                found = true
                let next = current.usage
                let delta = next.total < previous.total ? next : next - previous
                allTime.add(delta)
                if let timestamp = record.timestamp,
                   let date = formatter.date(from: timestamp),
                   calendar.isDateInToday(date) {
                    today.add(delta)
                }
                previous = next
            }
            if found { count += 1 }
        }
        return (today, allTime, count, nil)
    }
}

private struct LogRecord: Decodable {
    let timestamp: String?
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let info: Info?
    }
    struct Info: Decodable {
        let totalTokenUsage: TokenUsage?
        enum CodingKeys: String, CodingKey { case totalTokenUsage = "total_token_usage" }
    }
    struct TokenUsage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cachedInputTokens: Int?
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens", outputTokens = "output_tokens"
            case cachedInputTokens = "cached_input_tokens"
        }
        var usage: Usage {
            Usage(input: inputTokens, output: outputTokens, cached: cachedInputTokens ?? 0)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Token Meter").font(AppFont.semibold(14))
                    Text("Local Codex usage").font(AppFont.regular(11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await meter.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                    .font(AppFont.semibold(12))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PressStyle())
                .help("새로고침")
                .disabled(meter.isLoading)
            }
            .padding(.bottom, 20)

            Text("TODAY").font(AppFont.semibold(10))
                .tracking(1.6).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                RollingCounter(value: meter.today.total, size: 38, font: AppFont.semibold(38))
                    .tracking(-1.6)
                Text("tokens").font(AppFont.regular(13)).foregroundStyle(.secondary)
            }
            .padding(.top, 3)
            .padding(.bottom, 18)

            HStack(spacing: 8) {
                metric("Input", value: meter.today.input, tint: .indigo)
                metric("Output", value: meter.today.output, tint: .purple)
            }

            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1).padding(.vertical, 18)

            HStack {
                Text("전체 기록").foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    RollingCounter(value: meter.allTime.total, size: 12, font: AppFont.medium(12))
                    Text("tokens")
                }
            }
            .font(AppFont.regular(12))
            .padding(.bottom, 8)
            HStack {
                Text("오늘 캐시 입력").foregroundStyle(.secondary)
                Spacer()
                RollingCounter(value: meter.today.cached, size: 12, font: AppFont.medium(12))
            }
            .font(AppFont.regular(12))

            if let error = meter.error {
                Text(error).font(AppFont.regular(11)).foregroundStyle(.orange)
                    .padding(.top, 14)
            }

            HStack {
                Text("로컬 세션 \(meter.sessionCount)개")
                Spacer()
                if let date = meter.lastUpdated {
                    Text("업데이트 \(date, style: .time)")
                }
            }
            .font(AppFont.regular(10))
            .foregroundStyle(.tertiary)
            .padding(.top, 18)
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(colorScheme == .dark ? 0.18 : 0.6), lineWidth: 1)
                }
        }
    }

    private func metric(_ title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).foregroundStyle(.secondary)
            }
            .font(AppFont.regular(11))
            RollingCounter(value: value, size: 17, font: AppFont.semibold(17))
                .tracking(-0.4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
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
    private var digit: Int { Self.digit(in: value, at: power) }
    private var trackDigits: [Int] { [9] + Array(0...9) + Array(0...9) + [0] }

    init(value: Int, power: Int, size: CGFloat, font: Font) {
        self.value = value
        self.power = power
        self.size = size
        self.font = font
        _trackPosition = State(initialValue: Self.digit(in: value, at: power) + 1)
    }

    var body: some View {
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
