import Foundation

// Codex CLI 用量解析：纯本地读 ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl，
// 零网络、零凭据。
//
// 归因口径：session 文件里每条 token_count 事件带累计 total_token_usage，
// 用相邻事件的差值（cumulative diff）归到事件时间戳当天。跨天 session
// 的用量会正确拆分到各天，而不是全记到 session 开始日。
// 配额 rate_limits 取全部事件中时间戳最新的一条。
//
// 单文件可达数百 MB，顺序分块流式扫描（8MB chunk），只解码含
// token_count 标记的行；按 (size, mtime) 做内存级缓存，刷新时未变的
// 文件不重扫。

struct CodexRateWindow: Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date
}

struct CodexRateLimits: Equatable {
    let limitId: String?              // 通道 id：codex=订阅配额，其余为灰度/实验通道
    let limitName: String?            // 通道展示名（如 GPT-5.3-Codex-Spark）
    let primary: CodexRateWindow?     // 5 小时窗
    let secondary: CodexRateWindow?   // 周窗（10080 分钟）
    let planType: String?
    let asOf: Date                    // 数据时刻（事件时间戳）

    var isMain: Bool { limitId == nil || limitId == "codex" }
}

struct CodexDayUsage: Equatable, Identifiable {
    let date: String                  // "YYYY-MM-DD"
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var totalTokens: Int = 0
    var sessionCount: Int = 0

    var id: String { date }
    var cacheHitRate: Double? {
        guard inputTokens > 0 else { return nil }
        return Double(cachedInputTokens) / Double(inputTokens) * 100
    }
}

struct CodexModelUsage: Equatable, Identifiable {
    let model: String            // 含 effort 后缀，如 "gpt-5.5 (xhigh)"
    var totalTokens: Int = 0
    var id: String { model }
}

struct CodexProjectUsage: Equatable, Identifiable {
    let project: String          // session_meta cwd 末段
    var totalTokens: Int = 0
    var sessionCount: Int = 0
    var id: String { project }
}

struct CodexUsageResult: Equatable {
    let rateLimits: CodexRateLimits?       // 主通道（订阅配额）
    let allRateLimits: [CodexRateLimits]   // 全部通道，主通道在前
    let days: [CodexDayUsage]         // 最近 7 天，缺失日补零，升序
    let models: [CodexModelUsage]     // 7 天窗口按模型聚合，按量降序
    let projects: [CodexProjectUsage] // 7 天窗口按项目聚合，按量降序
    let todayHours: [CodexHourUsage]  // 今日 24 小时分布
    var today: CodexDayUsage? { days.last }
    var weekTotal: Int { days.reduce(0) { $0 + $1.totalTokens } }
    var weekSessions: Int { days.reduce(0) { $0 + $1.sessionCount } }
}

struct CodexHourUsage: Equatable, Identifiable {
    let hour: Int
    let totalTokens: Int
    var id: Int { hour }
}

enum CodexUsage {
    static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: sessionsDir.path)
    }

    // MARK: - JSONL 事件解码（只取需要的字段）

    private struct Event: Decodable {
        let timestamp: String?
        let payload: Payload?
        struct Payload: Decodable {
            let type: String?
            let info: Info?
            let rateLimits: RateLimits?
            let model: String?       // turn_context
            let effort: String?      // turn_context
            let cwd: String?         // session_meta / turn_context
            enum CodingKeys: String, CodingKey {
                case type, info, model, effort, cwd
                case rateLimits = "rate_limits"
            }
        }
        struct Info: Decodable {
            let totalTokenUsage: TokenUsage?
            let lastTokenUsage: TokenUsage?
            enum CodingKeys: String, CodingKey {
                case totalTokenUsage = "total_token_usage"
                case lastTokenUsage = "last_token_usage"
            }
        }
        struct TokenUsage: Decodable {
            let inputTokens: Int?
            let cachedInputTokens: Int?
            let outputTokens: Int?
            let reasoningOutputTokens: Int?
            let totalTokens: Int?
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cachedInputTokens = "cached_input_tokens"
                case outputTokens = "output_tokens"
                case reasoningOutputTokens = "reasoning_output_tokens"
                case totalTokens = "total_tokens"
            }
        }
        struct RateLimits: Decodable {
            let limitId: String?
            let limitName: String?
            let primary: Window?
            let secondary: Window?
            let planType: String?
            enum CodingKeys: String, CodingKey {
                case primary, secondary
                case limitId = "limit_id"
                case limitName = "limit_name"
                case planType = "plan_type"
            }
        }
        struct Window: Decodable {
            let usedPercent: Double?
            let windowMinutes: Int?
            let resetsAt: Double?
            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case windowMinutes = "window_minutes"
                case resetsAt = "resets_at"
            }
        }
    }

    // MARK: - 单文件扫描结果与缓存

    private struct Tally: Equatable {
        var input = 0, cached = 0, output = 0, reasoning = 0, total = 0
    }

    private struct FileSummary {
        let size: UInt64
        let mtime: Date
        let perDay: [String: Tally]
        let perDayModel: [String: [String: Int]] // day → 模型 → totalTokens
        let perDayHour: [String: [Int: Int]] // day → hour → totalTokens
        let project: String?                 // session cwd 末段（每文件一个）
        let rateLimitsByChannel: [String: CodexRateLimits]  // 通道 → 该文件内最新快照
    }

    // 内存级缓存：app 存续期内，未变的文件不重扫
    private static var cache: [String: FileSummary] = [:]
    private static let cacheLock = NSLock()

    // MARK: - 入口

    // 全树扫描，按 mtime 过滤：长期复用的 session（Codex Desktop 可挂数周）
    // 落在很老的日期目录里，但只要还在写 mtime 就是新的，按目录日期扫会漏掉。
    // mtime 早于 7 天窗起点的文件不可能含窗内事件，直接跳过。
    static func load(sessionsDirectory: URL = sessionsDir, now: Date = Date()) -> CodexUsageResult {
        let fm = FileManager.default
        var dayMap: [String: CodexDayUsage] = [:]
        let window: Set<String> = Set((0..<7).map { DateUtil.key(DateUtil.addDays(now, -$0)) })
        for key in window { dayMap[key] = CodexDayUsage(date: key) }
        let windowStart = Calendar.current.startOfDay(for: DateUtil.addDays(now, -6))

        var limitsByChannel: [String: CodexRateLimits] = [:]
        var modelMap: [String: CodexModelUsage] = [:]
        var projectMap: [String: CodexProjectUsage] = [:]
        var hourMap: [Int: Int] = [:]
        let todayKey = DateUtil.key(now)

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: sessionsDirectory, includingPropertiesForKeys: keys) else {
            return CodexUsageResult(rateLimits: nil, allRateLimits: [],
                                    days: dayMap.values.sorted { $0.date < $1.date },
                                    models: [], projects: [], todayHours: [])
        }

        for case let file as URL in walker where file.pathExtension == "jsonl" {
            guard let attrs = try? file.resourceValues(forKeys: Set(keys)),
                  attrs.isRegularFile == true,
                  let mtime = attrs.contentModificationDate, mtime >= windowStart else { continue }

            let summary = summarize(file)
            var counted = false
            var fileTokens = 0
            for (date, t) in summary.perDay where window.contains(date) {
                var d = dayMap[date] ?? CodexDayUsage(date: date)
                d.inputTokens += t.input
                d.cachedInputTokens += t.cached
                d.outputTokens += t.output
                d.reasoningTokens += t.reasoning
                d.totalTokens += t.total
                d.sessionCount += 1
                dayMap[date] = d
                counted = true
                fileTokens += t.total
            }
            for (channel, rl) in summary.rateLimitsByChannel {
                if let prev = limitsByChannel[channel], prev.asOf >= rl.asOf { continue }
                limitsByChannel[channel] = rl
            }
            guard counted else { continue }
            for (date, models) in summary.perDayModel where window.contains(date) {
                for (model, tokens) in models {
                    var m = modelMap[model] ?? CodexModelUsage(model: model)
                    m.totalTokens += tokens
                    modelMap[model] = m
                }
            }
            let proj = summary.project ?? "(其他)"
            var pj = projectMap[proj] ?? CodexProjectUsage(project: proj)
            pj.totalTokens += fileTokens
            pj.sessionCount += 1
            projectMap[proj] = pj
            if let hours = summary.perDayHour[todayKey] {
                for (h, tokens) in hours { hourMap[h, default: 0] += tokens }
            }
        }

        let days = dayMap.values.sorted { $0.date < $1.date }
        let models = modelMap.values.sorted { $0.totalTokens > $1.totalTokens }
        let projects = projectMap.values.sorted { $0.totalTokens > $1.totalTokens }
        let todayHours = (0..<24).map { CodexHourUsage(hour: $0, totalTokens: hourMap[$0] ?? 0) }
        // 主通道在前，其余按数据新鲜度降序
        let channels = limitsByChannel.values.sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            return $0.asOf > $1.asOf
        }
        return CodexUsageResult(rateLimits: channels.first, allRateLimits: channels, days: days,
                                models: models, projects: projects, todayHours: todayHours)
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
                                perDayHour: [:], project: nil, rateLimitsByChannel: [:])
        guard let handle = try? FileHandle(forReadingFrom: file) else { return empty }
        defer { try? handle.close() }

        let marker = Data("\"token_count\"".utf8)
        let ctxMarker = Data("\"turn_context\"".utf8)
        let metaMarker = Data("\"session_meta\"".utf8)
        let newline = UInt8(ascii: "\n")
        let chunkSize = 8 * 1024 * 1024
        let decoder = JSONDecoder()

        var perDay: [String: Tally] = [:]
        var perDayModel: [String: [String: Int]] = [:]
        var perDayHour: [String: [Int: Int]] = [:]
        var project: String?
        var currentModel = "unknown"     // turn_context 声明后续 turn 的模型
        var rlByChannel: [String: CodexRateLimits] = [:]
        var prevTotal: Event.TokenUsage?
        var carry = Data()   // chunk 边界上的半行

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
                    carry = data[lineStart...]   // 行未结束，留到下个 chunk
                    break
                }
                let line = data[lineStart..<nl]
                lineStart = data.index(after: nl)

                // 轻量行:turn_context 行更新当前模型,session_meta 行取项目
                if line.range(of: ctxMarker) != nil || (project == nil && line.range(of: metaMarker) != nil) {
                    if let event = try? decoder.decode(Event.self, from: line) {
                        if let m = event.payload?.model {
                            let effort = event.payload?.effort
                            currentModel = effort.map { "\(m) (\($0))" } ?? m
                        }
                        if project == nil, let cwd = event.payload?.cwd, !cwd.isEmpty {
                            let name = (cwd as NSString).lastPathComponent
                            project = name.isEmpty ? nil : name
                        }
                    }
                    continue
                }
                guard line.range(of: marker) != nil,
                      let event = try? decoder.decode(Event.self, from: line),
                      event.payload?.type == "token_count" else { continue }

                let ts = event.timestamp.flatMap { ISO8601DateFormatter.codex.date(from: $0) }

                if let cur = event.payload?.info?.totalTokenUsage, let ts {
                    let day = DateUtil.key(ts)
                    var t = perDay[day] ?? Tally()
                    // 累计值差分；累计变小说明 session 内部重置，退回单轮值
                    let d = delta(cur, prevTotal, fallback: event.payload?.info?.lastTokenUsage)
                    t.input += d.input; t.cached += d.cached
                    t.output += d.output; t.reasoning += d.reasoning; t.total += d.total
                    perDay[day] = t
                    prevTotal = cur
                    var models = perDayModel[day] ?? [:]
                    models[currentModel, default: 0] += d.total
                    perDayModel[day] = models
                    let hour = Calendar.current.component(.hour, from: ts)
                    perDayHour[day, default: [:]][hour, default: 0] += d.total
                }

                if let rl = event.payload?.rateLimits, let ts {
                    let p = rl.primary.flatMap(window)
                    let s = rl.secondary.flatMap(window)
                    // 两个窗口都空的事件（偶发 primary: null）不顶掉有效快照。
                    // 按 limit_id 分通道各存最新：codex 是订阅配额，灰度通道
                    // （如 codex_bengalfox）单独留快照，上游切换通道时 UI 全量呈现
                    guard p != nil || s != nil else { continue }
                    let channel = rl.limitId ?? "codex"
                    let snapshot = CodexRateLimits(
                        limitId: rl.limitId, limitName: rl.limitName,
                        primary: p, secondary: s, planType: rl.planType, asOf: ts)
                    if let prev = rlByChannel[channel], prev.asOf >= ts { continue }
                    rlByChannel[channel] = snapshot
                }
            }
        }
        return FileSummary(size: size, mtime: mtime, perDay: perDay, perDayModel: perDayModel,
                           perDayHour: perDayHour, project: project,
                           rateLimitsByChannel: rlByChannel)
    }

    private static func delta(_ cur: Event.TokenUsage, _ prev: Event.TokenUsage?,
                              fallback: Event.TokenUsage?) -> Tally {
        let curTotal = cur.totalTokens ?? 0
        if let prev, curTotal < (prev.totalTokens ?? 0) {
            // 累计被重置（如 compaction），用本轮用量兜底
            let f = fallback ?? cur
            return Tally(input: f.inputTokens ?? 0, cached: f.cachedInputTokens ?? 0,
                         output: f.outputTokens ?? 0, reasoning: f.reasoningOutputTokens ?? 0,
                         total: f.totalTokens ?? 0)
        }
        return Tally(
            input: max((cur.inputTokens ?? 0) - (prev?.inputTokens ?? 0), 0),
            cached: max((cur.cachedInputTokens ?? 0) - (prev?.cachedInputTokens ?? 0), 0),
            output: max((cur.outputTokens ?? 0) - (prev?.outputTokens ?? 0), 0),
            reasoning: max((cur.reasoningOutputTokens ?? 0) - (prev?.reasoningOutputTokens ?? 0), 0),
            total: max(curTotal - (prev?.totalTokens ?? 0), 0))
    }

    private static func window(_ w: Event.Window) -> CodexRateWindow? {
        guard let pct = w.usedPercent, let minutes = w.windowMinutes else { return nil }
        let resets = Date(timeIntervalSince1970: w.resetsAt ?? 0)
        return CodexRateWindow(usedPercent: pct, windowMinutes: minutes, resetsAt: resets)
    }

    // MARK: - 实时配额（官方接口）

    // 本地快照是被动的：只有对应通道发生请求才落盘，切灰度模型后订阅配额
    // 可能数小时不更新。官方 wham/usage 接口返回全通道实时配额，凭据复用
    // Codex CLI 自己维护的 ~/.codex/auth.json（只读，过期由 CLI 刷新）。
    private struct AuthFile: Decodable {
        let tokens: Tokens?
        struct Tokens: Decodable {
            let accessToken: String?
            let accountId: String?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountId = "account_id"
            }
        }
    }

    private struct WhamUsage: Decodable {
        let planType: String?
        let rateLimit: WhamRateLimit?
        let additionalRateLimits: [WhamAdditional]?
        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
        }
        struct WhamAdditional: Decodable {
            let limitName: String?
            let meteredFeature: String?
            let rateLimit: WhamRateLimit?
            enum CodingKeys: String, CodingKey {
                case limitName = "limit_name"
                case meteredFeature = "metered_feature"
                case rateLimit = "rate_limit"
            }
        }
        struct WhamRateLimit: Decodable {
            let primaryWindow: WhamWindow?
            let secondaryWindow: WhamWindow?
            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }
        struct WhamWindow: Decodable {
            let usedPercent: Double?
            // 秒数字段用 Double 解：JSON 数字无类型区分，服务端若返回小数秒
            // （如 18000.0）用 Int 会解码失败，导致整条配额被丢弃
            let limitWindowSeconds: Double?
            let resetAt: Double?
            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case limitWindowSeconds = "limit_window_seconds"
                case resetAt = "reset_at"
            }
        }
    }

    private static func whamWindow(_ w: WhamUsage.WhamWindow?) -> CodexRateWindow? {
        // secs > 0 兜底：窗口秒数缺失或为 0 时整条窗口无意义，丢弃；
        // 换算分钟取 max(_, 1)，避免极小秒数被整除成 0 分钟
        guard let w, let pct = w.usedPercent, let secs = w.limitWindowSeconds, secs > 0
        else { return nil }
        return CodexRateWindow(usedPercent: pct, windowMinutes: max(Int(secs) / 60, 1),
                               resetsAt: Date(timeIntervalSince1970: w.resetAt ?? 0))
    }

    // 失败（无凭据/过期/网络）返回 nil，调用方回退本地快照
    static func fetchLiveRateLimits() async -> [CodexRateLimits]? {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let authData = try? Data(contentsOf: authURL),
              let auth = try? JSONDecoder().decode(AuthFile.self, from: authData),
              let token = auth.tokens?.accessToken, !token.isEmpty else { return nil }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                             timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let acct = auth.tokens?.accountId {
            req.setValue(acct, forHTTPHeaderField: "chatgpt-account-id")
        }
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let usage = try? JSONDecoder().decode(WhamUsage.self, from: data) else { return nil }

        let now = Date()
        var out: [CodexRateLimits] = []
        if let rl = usage.rateLimit {
            out.append(CodexRateLimits(
                limitId: "codex", limitName: nil,
                primary: whamWindow(rl.primaryWindow),
                secondary: whamWindow(rl.secondaryWindow),
                planType: usage.planType, asOf: now))
        }
        for extra in usage.additionalRateLimits ?? [] {
            guard let rl = extra.rateLimit else { continue }
            out.append(CodexRateLimits(
                limitId: extra.meteredFeature, limitName: extra.limitName,
                primary: whamWindow(rl.primaryWindow),
                secondary: whamWindow(rl.secondaryWindow),
                planType: usage.planType, asOf: now))
        }
        return out.isEmpty ? nil : out
    }
}

private extension ISO8601DateFormatter {
    // Codex 时间戳带毫秒："2026-06-10T16:13:09.841Z"
    static let codex: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
