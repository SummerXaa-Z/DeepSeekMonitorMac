import Foundation

// Claude Code 用量解析：纯本地读 ~/.claude/projects/**/*.jsonl（会话 transcript），
// 零网络、零凭据。
//
// 与 Codex 的两个关键差异：
// 1. usage 是该条 assistant 消息的单次值（非累计），不做差分；
//    但同一条消息会随流式输出写多行（model+usage 相同、uuid 不同），
//    必须按 (message.id, requestId) 去重，否则量级翻倍。
// 2. 消息带 model 字段，可按模型分桶（Opus/Sonnet/Haiku/Fable…）。
//
// 文件扫描沿用 CodexUsage 的策略：全树枚举 + mtime 过滤 + 8MB chunk 流式
// 读 + (size, mtime) 内存缓存。去重集合按文件维度保存在缓存里，跨文件重复
// （罕见，仅 session 续写复制时出现）不处理。

struct ClaudeDayUsage: Equatable, Identifiable {
    let date: String                  // "YYYY-MM-DD"
    var inputTokens: Int = 0          // 非缓存输入
    var cacheCreationTokens: Int = 0  // 缓存写入
    var cacheReadTokens: Int = 0      // 缓存读取
    var outputTokens: Int = 0
    var messageCount: Int = 0         // 去重后的 API 请求数
    var sessionCount: Int = 0
    // 其中后端是 DeepSeek 的 token（cc 路由到 deepseek-* 模型）。这部分与
    // DeepSeek 官方源重叠，总览全源合计时要从 Claude 侧扣掉避免双算。
    var deepseekBackendTokens: Int = 0

    var id: String { date }
    var totalTokens: Int { inputTokens + cacheCreationTokens + cacheReadTokens + outputTokens }
    // 缓存读取占全部输入的比例
    var cacheHitRate: Double? {
        let allInput = inputTokens + cacheCreationTokens + cacheReadTokens
        guard allInput > 0 else { return nil }
        return Double(cacheReadTokens) / Double(allInput) * 100
    }
}

struct ClaudeModelUsage: Equatable, Identifiable {
    let model: String                 // 展示名（去掉 claude- 前缀与日期后缀）
    var totalTokens: Int = 0
    var outputTokens: Int = 0
    var messageCount: Int = 0
    var id: String { model }
}

struct ClaudeProjectUsage: Equatable, Identifiable {
    let project: String               // cwd 目录名
    var totalTokens: Int = 0
    var messageCount: Int = 0
    var id: String { project }
}

struct ClaudeHourUsage: Equatable, Identifiable {
    let hour: Int                     // 0-23（本地时区）
    let totalTokens: Int
    var id: Int { hour }
}

// 本周（最近 7 天）vs 上周（8-14 天前）合计；上周为 0 时环比无基期，返回 nil
struct ClaudeWeekCompare: Equatable {
    let thisTotalTokens: Int
    let lastTotalTokens: Int
    let thisOutputTokens: Int
    let lastOutputTokens: Int
    let thisMessageCount: Int
    let lastMessageCount: Int

    var totalChange: Double? { Self.change(thisTotalTokens, lastTotalTokens) }
    var outputChange: Double? { Self.change(thisOutputTokens, lastOutputTokens) }
    var messageChange: Double? { Self.change(thisMessageCount, lastMessageCount) }

    static let empty = ClaudeWeekCompare(thisTotalTokens: 0, lastTotalTokens: 0,
                                         thisOutputTokens: 0, lastOutputTokens: 0,
                                         thisMessageCount: 0, lastMessageCount: 0)

    private static func change(_ cur: Int, _ prev: Int) -> Double? {
        guard prev > 0 else { return nil }
        return (Double(cur) - Double(prev)) / Double(prev) * 100
    }
}

struct ClaudeUsageResult: Equatable {
    let days: [ClaudeDayUsage]        // 最近 7 天，缺失日补零，升序
    let models: [ClaudeModelUsage]    // 7 天窗口内按模型聚合，按量降序
    let projects: [ClaudeProjectUsage] // 7 天窗口内按项目聚合，按量降序
    let todayHours: [ClaudeHourUsage] // 今日 24 小时分布，缺失补零
    let weekCompare: ClaudeWeekCompare // 本周 vs 上周环比
    var today: ClaudeDayUsage? { days.last }
    var weekTotal: Int { days.reduce(0) { $0 + $1.totalTokens } }
    var weekMessages: Int { days.reduce(0) { $0 + $1.messageCount } }
    var weekSessions: Int { days.reduce(0) { $0 + $1.sessionCount } }
    // cc 路由到 DeepSeek 后端的 token（与 DeepSeek 官方源重叠）
    var todayDeepseekBackend: Int { today?.deepseekBackendTokens ?? 0 }
}

enum ClaudeUsage {
    static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: projectsDir.path)
    }

    // MARK: - JSONL 行解码（只取需要的字段）

    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let cwd: String?
        let message: Message?
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let inputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let outputTokens: Int?
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case outputTokens = "output_tokens"
            }
        }
    }

    // MARK: - 单文件扫描结果与缓存

    private struct Tally: Equatable {
        var input = 0, cacheCreate = 0, cacheRead = 0, output = 0, messages = 0
        var deepseekBackend = 0   // 后端为 deepseek-* 的 token（仅 perDay 用）
    }

    private struct FileSummary {
        let size: UInt64
        let mtime: Date
        let perDay: [String: Tally]
        let perDayModel: [String: [String: Tally]]
        let perDayProject: [String: [String: Tally]]
        let perDayHour: [String: [Int: Int]]   // day → hour → totalTokens
    }

    private static var cache: [String: FileSummary] = [:]
    private static let cacheLock = NSLock()

    // MARK: - 入口

    static func load(projectsDirectory: URL = projectsDir, now: Date = Date()) -> ClaudeUsageResult {
        let fm = FileManager.default
        var dayMap: [String: ClaudeDayUsage] = [:]
        let window: Set<String> = Set((0..<7).map { DateUtil.key(DateUtil.addDays(now, -$0)) })
        let lastWeek: Set<String> = Set((7..<14).map { DateUtil.key(DateUtil.addDays(now, -$0)) })
        for key in window { dayMap[key] = ClaudeDayUsage(date: key) }
        // 扫 14 天：本周展示 + 上周做环比基期
        let windowStart = Calendar.current.startOfDay(for: DateUtil.addDays(now, -13))

        var modelMap: [String: ClaudeModelUsage] = [:]
        var projectMap: [String: ClaudeProjectUsage] = [:]
        var hourMap: [Int: Int] = [:]
        var lastTotal = 0, lastOutput = 0, lastMessages = 0
        let todayKey = DateUtil.key(now)

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: projectsDirectory, includingPropertiesForKeys: keys) else {
            return ClaudeUsageResult(days: dayMap.values.sorted { $0.date < $1.date },
                                     models: [], projects: [], todayHours: [],
                                     weekCompare: .empty)
        }

        for case let file as URL in walker where file.pathExtension == "jsonl" {
            guard let attrs = try? file.resourceValues(forKeys: Set(keys)),
                  attrs.isRegularFile == true,
                  let mtime = attrs.contentModificationDate, mtime >= windowStart else { continue }

            let summary = summarize(file)
            // 上周只累计三项合计，不进 days/models/projects（它们保持 7 天口径）
            for (date, t) in summary.perDay where lastWeek.contains(date) {
                lastTotal += t.input + t.cacheCreate + t.cacheRead + t.output
                lastOutput += t.output
                lastMessages += t.messages
            }
            var counted = false
            for (date, t) in summary.perDay where window.contains(date) {
                var d = dayMap[date] ?? ClaudeDayUsage(date: date)
                d.inputTokens += t.input
                d.cacheCreationTokens += t.cacheCreate
                d.cacheReadTokens += t.cacheRead
                d.outputTokens += t.output
                d.messageCount += t.messages
                d.deepseekBackendTokens += t.deepseekBackend
                d.sessionCount += 1
                dayMap[date] = d
                counted = true
            }
            guard counted else { continue }
            for (date, models) in summary.perDayModel where window.contains(date) {
                for (model, t) in models {
                    var m = modelMap[model] ?? ClaudeModelUsage(model: model)
                    m.totalTokens += t.input + t.cacheCreate + t.cacheRead + t.output
                    m.outputTokens += t.output
                    m.messageCount += t.messages
                    modelMap[model] = m
                }
            }
            for (date, projects) in summary.perDayProject where window.contains(date) {
                for (project, t) in projects {
                    var p = projectMap[project] ?? ClaudeProjectUsage(project: project)
                    p.totalTokens += t.input + t.cacheCreate + t.cacheRead + t.output
                    p.messageCount += t.messages
                    projectMap[project] = p
                }
            }
            if let hours = summary.perDayHour[todayKey] {
                for (h, tokens) in hours { hourMap[h, default: 0] += tokens }
            }
        }

        let days = dayMap.values.sorted { $0.date < $1.date }
        let models = modelMap.values.sorted { $0.totalTokens > $1.totalTokens }
        let projects = projectMap.values.sorted { $0.totalTokens > $1.totalTokens }
        let todayHours = (0..<24).map { ClaudeHourUsage(hour: $0, totalTokens: hourMap[$0] ?? 0) }
        let compare = ClaudeWeekCompare(
            thisTotalTokens: days.reduce(0) { $0 + $1.totalTokens },
            lastTotalTokens: lastTotal,
            thisOutputTokens: days.reduce(0) { $0 + $1.outputTokens },
            lastOutputTokens: lastOutput,
            thisMessageCount: days.reduce(0) { $0 + $1.messageCount },
            lastMessageCount: lastMessages)
        return ClaudeUsageResult(days: days, models: models, projects: projects,
                                 todayHours: todayHours, weekCompare: compare)
    }

    // MARK: - 单文件流式扫描（带缓存）

    private static func summarize(_ file: URL) -> FileSummary {
        let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let size = UInt64(attrs?.fileSize ?? 0)
        let mtime = attrs?.contentModificationDate ?? .distantPast

        cacheLock.lock()
        let hit = cache[file.path]
        cacheLock.unlock()
        if let hit, hit.size == size, hit.mtime == mtime { return hit }

        let summary = scan(file, size: size, mtime: mtime)
        cacheLock.lock()
        cache[file.path] = summary
        cacheLock.unlock()
        return summary
    }

    private static func scan(_ file: URL, size: UInt64, mtime: Date) -> FileSummary {
        let empty = FileSummary(size: size, mtime: mtime, perDay: [:], perDayModel: [:],
                                perDayProject: [:], perDayHour: [:])
        guard let handle = try? FileHandle(forReadingFrom: file) else { return empty }
        defer { try? handle.close() }

        let marker = Data("\"usage\"".utf8)
        let newline = UInt8(ascii: "\n")
        let chunkSize = 8 * 1024 * 1024
        let decoder = JSONDecoder()

        var perDay: [String: Tally] = [:]
        var perDayModel: [String: [String: Tally]] = [:]
        var perDayProject: [String: [String: Tally]] = [:]
        var perDayHour: [String: [Int: Int]] = [:]
        var seen = Set<String>()      // (message.id|requestId) 去重，文件内
        var carry = Data()

        var reachedEnd = false
        while !reachedEnd {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            var data: Data
            if chunk.isEmpty {
                // JSONL 写入过程里最后一行不一定立刻带换行；EOF 时把完整残留行当作一行消费。
                // 若它确实仍是不完整 JSON，下面的 decode 自然失败并安全跳过。
                guard !carry.isEmpty else { break }
                data = carry
                data.append(newline)
                carry = Data()
                reachedEnd = true
            } else if carry.isEmpty {
                data = chunk
            } else {
                data = carry + chunk
                carry = Data()
            }

            var lineStart = data.startIndex
            while lineStart < data.endIndex {
                guard let nl = data[lineStart...].firstIndex(of: newline) else {
                    carry = data[lineStart...]
                    break
                }
                let line = data[lineStart..<nl]
                lineStart = data.index(after: nl)
                guard line.range(of: marker) != nil,
                      let row = try? decoder.decode(Line.self, from: line),
                      row.type == "assistant",
                      let usage = row.message?.usage,
                      let ts = row.timestamp.flatMap({ ISO8601DateFormatter.claude.date(from: $0) })
                else { continue }

                // 流式输出会把同一条消息写多行，按 (message.id, requestId) 只记一次
                let key = "\(row.message?.id ?? "")|\(row.requestId ?? "")"
                if key != "|" {
                    guard seen.insert(key).inserted else { continue }
                }

                let rawModel = row.message?.model ?? ""
                let isDeepseek = rawModel.hasPrefix("deepseek")
                let msgTotal = (usage.inputTokens ?? 0) + (usage.cacheCreationInputTokens ?? 0)
                    + (usage.cacheReadInputTokens ?? 0) + (usage.outputTokens ?? 0)

                let day = DateUtil.key(ts)
                var t = perDay[day] ?? Tally()
                t.input += usage.inputTokens ?? 0
                t.cacheCreate += usage.cacheCreationInputTokens ?? 0
                t.cacheRead += usage.cacheReadInputTokens ?? 0
                t.output += usage.outputTokens ?? 0
                t.messages += 1
                if isDeepseek { t.deepseekBackend += msgTotal }
                perDay[day] = t

                let model = Self.displayModel(row.message?.model)
                var models = perDayModel[day] ?? [:]
                var m = models[model] ?? Tally()
                m.input += usage.inputTokens ?? 0
                m.cacheCreate += usage.cacheCreationInputTokens ?? 0
                m.cacheRead += usage.cacheReadInputTokens ?? 0
                m.output += usage.outputTokens ?? 0
                m.messages += 1
                models[model] = m
                perDayModel[day] = models

                let project = Self.displayProject(row.cwd)
                var projects = perDayProject[day] ?? [:]
                var p = projects[project] ?? Tally()
                p.input += usage.inputTokens ?? 0
                p.cacheCreate += usage.cacheCreationInputTokens ?? 0
                p.cacheRead += usage.cacheReadInputTokens ?? 0
                p.output += usage.outputTokens ?? 0
                p.messages += 1
                projects[project] = p
                perDayProject[day] = projects

                let lineTotal = (usage.inputTokens ?? 0) + (usage.cacheCreationInputTokens ?? 0)
                    + (usage.cacheReadInputTokens ?? 0) + (usage.outputTokens ?? 0)
                let hour = Calendar.current.component(.hour, from: ts)
                perDayHour[day, default: [:]][hour, default: 0] += lineTotal
            }
        }
        return FileSummary(size: size, mtime: mtime, perDay: perDay, perDayModel: perDayModel,
                           perDayProject: perDayProject, perDayHour: perDayHour)
    }

    // cwd 最后一段作为项目名；空值归入 "(其他)"
    private static func displayProject(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "(其他)" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "(其他)" : name
    }

    // "claude-opus-4-8" → "opus-4-8"，"claude-fable-5" → "fable-5"；其他原样
    private static func displayModel(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "unknown" }
        if raw.hasPrefix("claude-") { return String(raw.dropFirst("claude-".count)) }
        return raw
    }
}

private extension ISO8601DateFormatter {
    // Claude 时间戳带毫秒："2026-06-11T06:35:07.772Z"
    static let claude: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
