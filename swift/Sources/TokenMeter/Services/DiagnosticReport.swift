import Foundation

enum DiagnosticReport {
    struct SourceStatus {
        let name: String
        let enabled: Bool
        let available: Bool
        let running: String
        let path: String?
        let detail: String?
    }

    struct Context {
        let generatedAt: Date
        let appVersion: String
        let bundleIdentifier: String
        let bundlePath: String
        let signatureStatus: String
        let macOSVersion: String
        let architecture: String
        let updateStatus: String
        let sources: [SourceStatus]
    }

    static func defaultFilename(version: String) -> String {
        "TokenMeter-Diagnostics-\(version).txt"
    }

    @MainActor
    static func currentFilename() -> String {
        defaultFilename(version: Updater.currentVersion)
    }

    static func build(
        context: Context,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        var lines: [String] = [
            "TokenMeter Diagnostic Report",
            "Generated At: \(isoString(context.generatedAt))",
            "",
            "## App",
            "Version: \(context.appVersion)",
            "Bundle ID: \(context.bundleIdentifier)",
            "Path: \(context.bundlePath)",
            "Signature: \(context.signatureStatus)",
            "",
            "## Environment",
            "macOS: \(context.macOSVersion)",
            "Architecture: \(context.architecture)",
            "Update: \(context.updateStatus)",
            "",
            "## Sources",
        ]

        for source in context.sources {
            var line = "\(source.name): enabled=\(yesNo(source.enabled)) available=\(yesNo(source.available)) running=\(source.running)"
            if let path = source.path, !path.isEmpty {
                line += " path=\(path)"
            }
            if let detail = source.detail, !detail.isEmpty {
                line += " detail=\(detail)"
            }
            lines.append(line)
        }

        return lines
            .map { redact(shortenHome(oneLine($0), homePath: homePath)) }
            .joined(separator: "\n") + "\n"
    }

    @MainActor
    static func currentText() -> String {
        build(context: collect(updatePhase: Updater.shared.phase))
    }

    @MainActor
    static func collect() -> Context {
        collect(updatePhase: Updater.shared.phase)
    }

    @MainActor
    static func collect(updatePhase: Updater.Phase) -> Context {
        let store = ConfigStore.shared
        return Context(
            generatedAt: Date(),
            appVersion: Updater.currentVersion,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            bundlePath: Bundle.main.bundlePath,
            signatureStatus: signatureStatus(for: Bundle.main.bundlePath),
            macOSVersion: macOSVersion(),
            architecture: architecture(),
            updateStatus: updateStatus(updatePhase),
            sources: [
                SourceStatus(
                    name: "DeepSeek",
                    enabled: store.deepseekMonitorEnabled,
                    available: store.apiKeyConfigured || store.usageTokenConfigured,
                    running: "n/a",
                    path: nil,
                    detail: "apiKeyConfigured=\(yesNo(store.apiKeyConfigured)) usageTokenConfigured=\(yesNo(store.usageTokenConfigured))"
                ),
                SourceStatus(
                    name: "Claude",
                    enabled: store.claudeMonitorEnabled,
                    available: ClaudeUsage.isAvailable,
                    running: runningText(ProcessStatus.claude()),
                    path: ClaudeUsage.projectsDir.path,
                    detail: nil
                ),
                SourceStatus(
                    name: "Codex",
                    enabled: store.codexMonitorEnabled,
                    available: CodexUsage.isAvailable,
                    running: runningText(ProcessStatus.codex()),
                    path: CodexUsage.sessionsDir.path,
                    detail: nil
                ),
                SourceStatus(
                    name: "Cursor",
                    enabled: store.cursorMonitorEnabled,
                    available: CursorUsage.isAvailable,
                    running: runningText(ProcessStatus.cursor()),
                    path: CursorUsage.stateDB.path,
                    detail: nil
                ),
                SourceStatus(
                    name: "AgentSync",
                    enabled: true,
                    available: AgentSyncService.isAvailable,
                    running: "n/a",
                    path: AgentSyncService.cliPath?.path,
                    detail: nil
                ),
            ]
        )
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static func runningText(_ snapshot: ProcessStatus.Snapshot) -> String {
        guard snapshot.running else { return "未运行" }
        return snapshot.count > 1 ? "运行中(\(snapshot.count))" : "运行中"
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func updateStatus(_ phase: Updater.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .checking: return "checking"
        case .upToDate: return "upToDate"
        case .available(let version): return "available(\(version))"
        case .downloading: return "downloading"
        case .installing: return "installing"
        case .failed(let message): return "failed(\(message))"
        }
    }

    private static func signatureStatus(for bundlePath: String) -> String {
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            return "missing bundle"
        }
        let result = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", bundlePath])
        guard result.status == 0 else {
            let message = result.output
                .split(separator: "\n")
                .first
                .map(String.init) ?? "codesign failed"
            return "invalid: \(message)"
        }
        return "valid"
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            let captured = ProcessPipeReader.read(stdout: out, stderr: err, process: proc)
            let output = String(decoding: captured.stdout + captured.stderr, as: UTF8.self)
            return (proc.terminationStatus, output)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private static func shortenHome(_ value: String, homePath: String) -> String {
        guard !homePath.isEmpty, homePath != "/" else { return value }
        return value.replacingOccurrences(of: homePath, with: "~")
    }

    private static func oneLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func redact(_ value: String) -> String {
        let patterns: [(pattern: String, replacement: String)] = [
            ("(?i)(authorization\\s*:\\s*)[^\\s,;]+(\\s+[^\\s,;]+)?", "$1<redacted>"),
            ("(?i)(bearer\\s+)[^\\s,;]+", "$1<redacted>"),
            ("(?i)\\b(token|cookie|api[_-]?key|password)\\s*[:=]\\s*[^\\s,;]+", "$1=<redacted>"),
            ("sk-[A-Za-z0-9._-]+", "<redacted>"),
        ]
        return patterns.reduce(value) { current, item in
            current.replacingOccurrences(
                of: item.pattern,
                with: item.replacement,
                options: .regularExpression
            )
        }
    }
}
