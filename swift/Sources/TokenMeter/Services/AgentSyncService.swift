import Foundation

// AgentSync CLI（Python）的 Swift 封装：通过子进程调用全局命令 `agentsync --json ...`，
// 解析结构化 JSON。项目此前无捕获子进程输出的先例，这里建立 Process + Pipe + 退出码
// 的读取模式；阻塞调用放在 Task.detached 里执行（仿 loadClaude/loadCodex），不阻塞主线程。

// MARK: - 错误

enum AgentSyncError: LocalizedError {
    case cliNotFound
    case nonZeroExit(code: Int32)
    case decodeFailed
    case cliError(String)   // CLI 返回 ok:false 的业务错误

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "未找到 agentsync 命令。请先执行：uv tool install --editable ~/Documents/code-xt/agentsync"
        // 子进程原始输出可能意外包含配置片段，不能回显到 UI。
        // 结构化 {ok:false,error} 的业务提示仍由 cliError 单独展示。
        case .nonZeroExit(let code):
            return "agentsync 执行失败（退出码 \(code)）。请检查安装状态后重试。"
        case .decodeFailed:
            return "agentsync 返回了无法识别的数据。请更新 agentsync 后重试。"
        case .cliError(let msg):
            return msg
        }
    }
}

// MARK: - JSON 数据模型（对应 CLI --json 输出）

struct ConfigProfile: Decodable, Identifiable, Equatable {
    let key: String
    let label: String
    let variant: String
    let mcpState: String          // present / absent / none
    let mcpCount: Int?
    let hasRules: Bool
    let memory: String
    let skills: String
    let commands: String?
    let agents: String?
    let hooks: String?
    // 新版 agentsync 的目标写入能力；nil 代表旧 CLI，需回退到旧有内容判断。
    let declaredWritableLayers: [String]?

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, label, variant, memory, skills, commands, agents, hooks
        case mcpState = "mcp_state"
        case mcpCount = "mcp_count"
        case hasRules = "has_rules"
        case declaredWritableLayers = "writable_layers"
    }

    var mcpDisplay: String {
        switch mcpState {
        case "present": return "\(mcpCount ?? 0)"
        case "absent": return "absent"
        default: return "—"
        }
    }

    var hasSkills: Bool {
        skills != "—" && !skills.isEmpty
    }

    var hasCommands: Bool {
        Self.hasLayerValue(commands)
    }

    var hasAgents: Bool {
        Self.hasLayerValue(agents)
    }

    var hasHooks: Bool {
        Self.hasLayerValue(hooks)
    }

    /// 按 agentsync CLI 的层名返回此 profile 实际可作为真源的内容。
    /// 顺序需要稳定，直接用于 UI 与 `--layer` 参数。
    var syncableLayers: [String] {
        var layers: [String] = []
        if mcpState == "present" { layers.append("mcp") }
        if hasRules { layers.append("rules") }
        if hasSkills { layers.append("skills") }
        if hasCommands { layers.append("commands") }
        if hasAgents { layers.append("agents") }
        if hasHooks { layers.append("hooks") }
        return layers
    }

    var hasSyncableLayer: Bool {
        !syncableLayers.isEmpty
    }

    /// 目标能接收默认 push 的层。旧版 CLI 未提供字段时，保持原有兼容行为。
    var writableLayers: [String] {
        declaredWritableLayers ?? syncableLayers
    }

    var hasWritableLayer: Bool {
        !writableLayers.isEmpty
    }

    private static func hasLayerValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return value != "—" && !value.isEmpty
    }
}

struct ConfigScanResult: Decodable {
    let profiles: [ConfigProfile]
}

enum ConfigSelection {
    static func syncableProfiles(_ profiles: [ConfigProfile]) -> [ConfigProfile] {
        profiles.filter(\.hasSyncableLayer)
    }

    /// 工具可作为真源，取决于它现在实际拥有的内容；这和目标是否可写是两套口径。
    static func targetProfiles(_ profiles: [ConfigProfile]) -> [ConfigProfile] {
        profiles.filter { $0.hasSyncableLayer || $0.hasWritableLayer }
    }

    /// 目标必须覆盖本次选中的每一层。这样预览前就排除无效组合，仍保留可 --create 的空路径。
    static func targetableProfiles(
        _ profiles: [ConfigProfile],
        source: String,
        layers: [String]
    ) -> [ConfigProfile] {
        let selectedLayers = Set(layers)
        return targetProfiles(profiles).filter { profile in
            profile.key != source
                && profile.hasWritableLayer
                && selectedLayers.isSubset(of: Set(profile.writableLayers))
        }
    }

    static func validTargets(
        _ selected: Set<String>,
        profiles: [ConfigProfile],
        source: String,
        layers: [String]
    ) -> Set<String> {
        let allowed = Set(targetableProfiles(profiles, source: source, layers: layers).map(\.key))
        return selected.intersection(allowed)
    }

    static func availableLayers(for source: String, profiles: [ConfigProfile]) -> [String] {
        profiles.first { $0.key == source }?.syncableLayers ?? []
    }

    /// 刷新扫描结果后，已从真源消失的层绝不能继续传给 pull / push。
    static func validLayers(_ selected: [String], for source: String, profiles: [ConfigProfile]) -> [String] {
        let available = Set(availableLayers(for: source, profiles: profiles))
        return selected.filter { available.contains($0) }
    }
}

struct ServersDiff: Decodable {
    let added: [String]
    let overwritten: [String]?
    let preserved: [String]?
    // 兼容旧格式
    let modified: [String]?
    let removed: [String]?
}

struct PushTarget: Decodable, Identifiable {
    let key: String
    let label: String
    let layer: String
    // agentsync 对不支持或只读的层会返回 skip 条目；这些条目没有 path / exists。
    // 这两个字段必须可选，否则一次 skip 会让整个预览 JSON 解码失败。
    let path: String?
    let exists: Bool?
    let servers: ServersDiff?
    let itemsAdded: [String]?
    let alreadyPresent: [String]?
    let dstOnly: [String]?
    let change: String            // none / modify / create / skip_no_create / add / skip
    let written: Bool
    let diffText: String?
    let skipReason: String?

    var id: String { "\(key)-\(layer)" }

    enum CodingKeys: String, CodingKey {
        case key, label, layer, path, exists, servers, change, written
        case itemsAdded = "items_added"
        case alreadyPresent = "already_present"
        case dstOnly = "dst_only"
        case diffText = "diff_text"
        case skipReason = "skip_reason"
    }
}

struct PushResult: Decodable {
    let ok: Bool
    let apply: Bool
    let anyChange: Bool
    let backupTs: String?
    let targets: [PushTarget]
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, apply, targets, error
        case anyChange = "any_change"
        case backupTs = "backup_ts"
    }
}

/// 把 agentsync 返回的层级结果与用户本次请求逐项对照，避免把「没有预览结果」误称为一致。
struct ConfigSyncTargetLayer: Hashable, Identifiable {
    let target: String
    let layer: String

    var id: String { "\(target)-\(layer)" }
}

enum ConfigPreview {
    /// agentsync 对一个工具不支持的单文件层不会生成条目；保留缺口供 UI 明示「未同步」。
    static func missingTargetLayers(
        targets: [String],
        layers: [String],
        result: PushResult
    ) -> [ConfigSyncTargetLayer] {
        let returned = Set(result.targets.map {
            ConfigSyncTargetLayer(target: $0.key, layer: $0.layer)
        })
        var seen = Set<ConfigSyncTargetLayer>()

        return targets.flatMap { target in
            layers.map { ConfigSyncTargetLayer(target: target, layer: $0) }
        }.filter { request in
            seen.insert(request).inserted && !returned.contains(request)
        }
    }

    /// 只有这些变更会在带 --apply 的第二步产生写入；skip 只是提示，不能启用确认写入。
    static func writableTargetKeys(in result: PushResult) -> Set<String> {
        Set(result.targets.compactMap { target in
            switch target.change {
            case "create", "modify", "add": return target.key
            default: return nil
            }
        })
    }

    /// 预览必须覆盖用户请求的每一对目标/层，才允许进入真正的写入步骤，避免静默部分同步。
    static func canApply(targets: [String], layers: [String], result: PushResult) -> Bool {
        missingTargetLayers(targets: targets, layers: layers, result: result).isEmpty
            && !writableTargetKeys(in: result).isEmpty
    }
}

struct PullLayerResult: Decodable {
    let layer: String
    let count: Int?
    let chars: Int?
    let path: String?
    let skipped: String?
}

struct PullResult: Decodable {
    let ok: Bool
    let source: String?
    let label: String?
    let layers: [PullLayerResult]?
    let error: String?
}

struct BackupList: Decodable {
    let backups: [String]
}

struct RollbackResult: Decodable {
    let ok: Bool
    let ts: String?
    let restored: [String]?
    let error: String?
}

// MARK: - 服务

enum AgentSyncService {

    /// 探测全局 agentsync 命令路径。顺序：~/.local/bin → /opt/homebrew/bin → which。
    static var cliPath: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/agentsync"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agentsync"),
            URL(fileURLWithPath: "/usr/local/bin/agentsync"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return whichAgentsync()
    }

    static var isAvailable: Bool { cliPath != nil }

    private static func whichAgentsync() -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", "agentsync"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    // MARK: 子进程核心

    /// 执行 `agentsync <args> --json`，返回 stdout 数据。阻塞——调用方须在 detached 上下文里用。
    private static func runRaw(_ args: [String]) throws -> Data {
        guard let cli = cliPath else { throw AgentSyncError.cliNotFound }
        let proc = Process()
        proc.executableURL = cli
        proc.arguments = args + ["--json"]
        // 保证子进程能找到 uv / python 环境；env 数组传参天然免注入
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        let output = ProcessPipeReader.read(stdout: outPipe, stderr: errPipe, process: proc)
        let outData = output.stdout
        let errData = output.stderr

        guard proc.terminationStatus == 0 else {
            // CLI 的业务错误（如 canonical 为空）以 {ok:false,error} + 退出码 1 返回，
            // stdout 才有可读文案。优先透出它，退回才用 stderr/退出码。
            if let msg = decodeCLIError(outData) {
                throw AgentSyncError.cliError(msg)
            }
            // stderr 仍须读完，避免子进程因 pipe 缓冲区阻塞；但绝不显示其原文。
            _ = errData
            throw AgentSyncError.nonZeroExit(code: proc.terminationStatus)
        }
        return outData
    }

    private struct CLIErrorEnvelope: Decodable {
        let ok: Bool?
        let error: String?
    }

    private static func decodeCLIError(_ data: Data) -> String? {
        guard let env = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: data),
              env.ok == false, let msg = env.error, !msg.isEmpty
        else { return nil }
        return msg
    }

    private static func run<T: Decodable>(_ args: [String], as type: T.Type) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            let data = try runRaw(args)
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                // JSON 可能来自未来版本或异常 CLI，不能将原始输出带入用户可见错误。
                throw AgentSyncError.decodeFailed
            }
        }.value
    }

    // MARK: 对外 API

    static func scan() async throws -> ConfigScanResult {
        try await run(["scan"], as: ConfigScanResult.self)
    }

    static func pull(from source: String, layers: [String]) async throws -> PullResult {
        let r = try await run(
            ["pull", "--from", source, "--layer", layers.joined(separator: ",")],
            as: PullResult.self
        )
        if !r.ok { throw AgentSyncError.cliError(r.error ?? "拉取失败") }
        return r
    }

    /// dry-run 预览（不落盘），附完整脱敏 diff 文本。
    static func pushPreview(to targets: [String], layers: [String]) async throws -> PushResult {
        let r = try await run(
            ["push", "--to", targets.joined(separator: ","),
             "--layer", layers.joined(separator: ","), "--with-diff"],
            as: PushResult.self
        )
        if !r.ok { throw AgentSyncError.cliError(r.error ?? "预览失败") }
        return r
    }

    /// 真正落盘（--apply --create），CLI 内部自动备份。
    static func pushApply(to targets: [String], layers: [String]) async throws -> PushResult {
        let r = try await run(
            ["push", "--to", targets.joined(separator: ","),
             "--layer", layers.joined(separator: ","), "--apply", "--create"],
            as: PushResult.self
        )
        if !r.ok { throw AgentSyncError.cliError(r.error ?? "写入失败") }
        return r
    }

    static func listBackups() async throws -> [String] {
        try await run(["rollback", "list"], as: BackupList.self).backups
    }

    static func rollback(ts: String) async throws -> RollbackResult {
        let r = try await run(["rollback", ts], as: RollbackResult.self)
        if !r.ok { throw AgentSyncError.cliError(r.error ?? "回滚失败") }
        return r
    }
}
