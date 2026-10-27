import Foundation

struct ScanCache: Codable, Equatable, Sendable {
    var dayStart: Date
    var files: [String: FileUsage]
}

struct FileUsage: Codable, Equatable, Sendable {
    var size: UInt64
    var readOffset: UInt64
    var modifiedAt: Date?
    var fileID: UInt64?
    var latest: Usage?
    var allTime: Usage
    var today: Usage
}

struct ScanResult: Sendable {
    var today: Usage
    var allTime: Usage
    var count: Int
    var error: String?
    var cache: ScanCache?
}

enum UsageScanner {
    private static let chunkSize = 256 * 1024
    private static let tokenCountMarker = Data("\"token_count\"".utf8)

    static func scan(root: URL, previous: ScanCache?) -> ScanResult {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else {
            return ScanResult(today: Usage(), allTime: Usage(), count: 0,
                              error: "Codex 기록 폴더를 찾을 수 없습니다.", cache: nil)
        }
        guard let enumerator = manager.enumerator(at: root,
                                                  includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return ScanResult(today: Usage(), allTime: Usage(), count: 0,
                              error: "Codex 기록 폴더를 읽을 수 없습니다.", cache: nil)
        }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let sameDay = previous.map { calendar.isDate($0.dayStart, inSameDayAs: dayStart) } ?? false
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        var files: [String: FileUsage] = [:]
        var today = Usage()
        var allTime = Usage()
        var count = 0

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let fileSize = values.fileSize else { continue }
            let size = UInt64(fileSize)
            let fileID = (try? manager.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?
                .uint64Value
            let key = String(url.path.dropFirst(root.path.count + 1))
            let old = previous?.files[key]

            let entry: FileUsage
            if let old, old.fileID == fileID, size >= old.size,
               (size > old.size || old.modifiedAt == values.contentModificationDate) {
                var reused = old
                if !sameDay { reused.today = Usage() }
                if size > old.readOffset {
                    do {
                        try appendNewLines(from: url, into: &reused, size: size,
                                           dayStart: dayStart, formatter: formatter,
                                           fallbackFormatter: fallbackFormatter)
                    } catch { continue }
                }
                reused.size = size
                reused.modifiedAt = values.contentModificationDate
                entry = reused
            } else {
                guard let scanned = try? scanFromEnd(url: url, size: size,
                                                    modifiedAt: values.contentModificationDate,
                                                    fileID: fileID, dayStart: dayStart,
                                                    formatter: formatter,
                                                    fallbackFormatter: fallbackFormatter) else { continue }
                entry = scanned
            }

            files[key] = entry
            allTime.add(entry.allTime)
            today.add(entry.today)
            if entry.latest != nil { count += 1 }
        }

        return ScanResult(today: today, allTime: allTime, count: count,
                          error: nil, cache: ScanCache(dayStart: dayStart, files: files))
    }

    private static func scanFromEnd(url: URL, size: UInt64, modifiedAt: Date?, fileID: UInt64?,
                                    dayStart: Date, formatter: ISO8601DateFormatter,
                                    fallbackFormatter: ISO8601DateFormatter) throws -> FileUsage {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var position = size
        var incompletePrefix = Data()
        var lastCompleteLineEnd: UInt64?
        var latest: Usage?
        var newerToday: Usage?
        var today = Usage()

        while position > 0 {
            let amount = min(UInt64(chunkSize), position)
            position -= amount
            try handle.seek(toOffset: position)
            let chunk = try handle.read(upToCount: Int(amount)) ?? Data()
            if lastCompleteLineEnd == nil, let lastNewline = chunk.lastIndex(of: 10) {
                lastCompleteLineEnd = position + UInt64(lastNewline) + 1
            }

            var joined = chunk
            joined.append(incompletePrefix)
            let lines = joined.split(separator: 10, omittingEmptySubsequences: false)
            if position > 0 { incompletePrefix = Data(lines[0]) }

            let firstCompleteIndex = position == 0 ? 0 : 1
            for index in stride(from: lines.count - 1, through: firstCompleteIndex, by: -1) {
                guard let event = tokenEvent(in: Data(lines[index]), formatter: formatter,
                                             fallbackFormatter: fallbackFormatter) else { continue }
                if latest == nil { latest = event.usage }
                if let newerToday { today.add(delta(from: event.usage, to: newerToday)) }
                if let date = event.date, date >= dayStart {
                    newerToday = event.usage
                } else {
                    return FileUsage(size: size, readOffset: lastCompleteLineEnd ?? 0,
                                     modifiedAt: modifiedAt, fileID: fileID,
                                     latest: latest, allTime: latest ?? Usage(), today: today)
                }
            }
        }

        if let newerToday { today.add(newerToday) }
        return FileUsage(size: size, readOffset: lastCompleteLineEnd ?? 0,
                         modifiedAt: modifiedAt, fileID: fileID,
                         latest: latest, allTime: latest ?? Usage(), today: today)
    }

    private static func appendNewLines(from url: URL, into entry: inout FileUsage, size: UInt64,
                                       dayStart: Date, formatter: ISO8601DateFormatter,
                                       fallbackFormatter: ISO8601DateFormatter) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.readOffset)

        var pending = Data()
        var readOffset = entry.readOffset
        while readOffset + UInt64(pending.count) < size {
            let remaining = size - readOffset - UInt64(pending.count)
            let chunk = try handle.read(upToCount: Int(min(UInt64(chunkSize), remaining))) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)

            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                let consumed = pending.distance(from: pending.startIndex, to: newline) + 1
                pending.removeFirst(consumed)
                readOffset += UInt64(consumed)

                guard let event = tokenEvent(in: line, formatter: formatter,
                                             fallbackFormatter: fallbackFormatter) else { continue }
                let difference = entry.latest.map { delta(from: $0, to: event.usage) } ?? event.usage
                entry.allTime.add(difference)
                if let date = event.date, date >= dayStart {
                    entry.today.add(difference)
                }
                entry.latest = event.usage
            }
        }
        entry.readOffset = readOffset
    }

    private static func delta(from previous: Usage, to current: Usage) -> Usage {
        current.total < previous.total ? current : current - previous
    }

    private static func tokenEvent(in line: Data, formatter: ISO8601DateFormatter,
                                   fallbackFormatter: ISO8601DateFormatter) -> (usage: Usage, date: Date?)? {
        guard line.range(of: tokenCountMarker) != nil,
              let record = try? JSONDecoder().decode(LogRecord.self, from: line),
              record.payload.type == "token_count",
              let usage = record.payload.info?.totalTokenUsage?.usage else { return nil }
        let date = record.timestamp.flatMap { formatter.date(from: $0) ?? fallbackFormatter.date(from: $0) }
        return (usage, date)
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
