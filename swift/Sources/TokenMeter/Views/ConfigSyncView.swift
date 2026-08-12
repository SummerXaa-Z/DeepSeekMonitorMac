import SwiftUI

// 配置同步面板：列出本机各 Agent 工具的 MCP/指令现状，选真源 → 勾选目标 →
// 预览（开独立窗口看结构化 diff）→ 确认写入。数据来自 agentsync CLI 子进程。
// 面板宽 420，重内容（完整 diff/确认）走 ConfigSyncWindow 独立窗口。
struct ConfigSyncView: View {
    @EnvironmentObject var state: AppState
    var onSettings: () -> Void

    @State private var source: String = ""              // 真源工具 key
    @State private var selectedTargets: Set<String> = []  // 推送目标
    @State private var layerMCP = true
    @State private var layerRules = false
    @State private var layerSkills = false
    @State private var layerCommands = false
    @State private var layerAgents = false
    @State private var layerHooks = false
    @State private var busy = false
    @State private var actionError: String?

    private var profiles: [ConfigProfile] {
        state.configSync.result?.profiles ?? []
    }

    // 真源必须有当前可抽取的内容；目标则按 writable_layers 单独判断。
    private var sourceProfiles: [ConfigProfile] {
        ConfigSelection.syncableProfiles(profiles)
    }

    private var displayProfiles: [ConfigProfile] {
        ConfigSelection.targetProfiles(profiles)
    }

    private var layers: [String] {
        var l: [String] = []
        if layerMCP { l.append("mcp") }
        if layerRules { l.append("rules") }
        if layerSkills { l.append("skills") }
        if layerCommands { l.append("commands") }
        if layerAgents { l.append("agents") }
        if layerHooks { l.append("hooks") }
        return l
    }

    // Toggle 状态可能比异步 scan 结果旧；所有操作统一使用和当前真源取交集后的层。
    private var activeLayers: [String] {
        ConfigSelection.validLayers(layers, for: source, profiles: profiles)
    }

    // 可选为目标的工具（排除真源自己）
    private var targetableProfiles: [ConfigProfile] {
        ConfigSelection.targetableProfiles(profiles, source: source, layers: activeLayers)
    }

    private var validSelectedTargets: Set<String> {
        ConfigSelection.validTargets(
            selectedTargets,
            profiles: profiles,
            source: source,
            layers: activeLayers
        )
    }

    // 是否全选了
    private var allTargetsSelected: Bool {
        !targetableProfiles.isEmpty && targetableProfiles.allSatisfy { validSelectedTargets.contains($0.key) }
    }

    private var allLayersSelected: Bool {
        !availableSourceLayers.isEmpty && Set(activeLayers) == Set(availableSourceLayers)
    }

    private var availableSourceLayers: [String] {
        ConfigSelection.availableLayers(for: source, profiles: profiles)
    }

    // 切换全选
    private func toggleSelectAll() {
        if allTargetsSelected {
            selectedTargets.removeAll()
        } else {
            selectedTargets = Set(targetableProfiles.map { $0.key })
        }
    }

    private func setAllLayers(_ selected: Bool) {
        setLayers(selected ? availableSourceLayers : [])
    }

    private func setLayers(_ selected: [String]) {
        let selected = Set(selected)
        layerMCP = selected.contains("mcp")
        layerRules = selected.contains("rules")
        layerSkills = selected.contains("skills")
        layerCommands = selected.contains("commands")
        layerAgents = selected.contains("agents")
        layerHooks = selected.contains("hooks")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if !sourceProfiles.isEmpty {
                    sourceCard
                    toolsCard
                    layerCard
                    actionBar
                    if let err = actionError {
                        Text(err).font(.system(size: 11)).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                } else if state.configSync.loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if !profiles.isEmpty {
                    Text("未检测到可同步配置")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.top, 60)
                } else if let err = state.configSync.error {
                    Text(err).font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.top, 60)
                } else {
                    Text("未检测到 agentsync 命令")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.top, 60)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .task { await state.loadConfigSync() }
        .onChange(of: source) { _, newSource in
            // 真源切换时只预选它实际拥有的层，避免默认 MCP 对 Rules/Skills-only 真源产生空操作。
            let available = ConfigSelection.availableLayers(for: newSource, profiles: profiles)
            setLayers(available)
            selectedTargets = ConfigSelection.validTargets(
                selectedTargets,
                profiles: profiles,
                source: newSource,
                layers: available
            )
        }
        .onChange(of: profiles) { _, _ in
            // scan 刷新时，源或目标能力都可能变化：清掉失效层与已不兼容的旧勾选。
            guard source.isEmpty || sourceProfiles.contains(where: { $0.key == source }) else {
                source = ""
                selectedTargets.removeAll()
                return
            }
            let validLayers = ConfigSelection.validLayers(layers, for: source, profiles: profiles)
            setLayers(validLayers)
            selectedTargets = ConfigSelection.validTargets(
                selectedTargets,
                profiles: profiles,
                source: source,
                layers: validLayers
            )
        }
        .onChange(of: activeLayers) { _, newLayers in
            // 手动增减同步层后，保留不了全部层的目标不应继续处于选中状态。
            selectedTargets = ConfigSelection.validTargets(
                selectedTargets,
                profiles: profiles,
                source: source,
                layers: newLayers
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.brand)
            Text("配置同步")
                .font(.system(size: 15, weight: .bold))
            Spacer()
            iconButton("arrow.clockwise") { Task { await state.loadConfigSync(force: true) } }
            iconButton("gearshape") { onSettings() }
        }
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    // MARK: - 真源选择
    private var sourceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("真源（从哪个工具抽取）", systemImage: "star")
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: $source) {
                    Text("请选择").tag("")
                    ForEach(sourceProfiles) { p in
                        Text(p.label).tag(p.key)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - 工具列表（勾选推送目标）
    private var toolsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("推送目标（勾选）", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(allTargetsSelected ? "全不选" : "全选") {
                        toggleSelectAll()
                    }
                    .font(.system(size: 11))
                }
                ForEach(displayProfiles) { p in
                    toolRow(p)
                    if p.id != displayProfiles.last?.id { Divider().opacity(0.3) }
                }
            }
        }
    }

    private func toolRow(_ p: ConfigProfile) -> some View {
        let isSource = p.key == source
        let selectable = targetableProfiles.contains { $0.key == p.key }
        return HStack(spacing: 8) {
            Image(systemName: iconFor(p.key))
                .font(.system(size: 13))
                .foregroundStyle(isSource ? Theme.brand : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.label).font(.system(size: 12, weight: .medium))
                if !isSource && !selectable && !activeLayers.isEmpty {
                    Text("不支持所选同步层")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                } else {
                    layerStatusText(p)
                }
            }
            Spacer()
            if isSource {
                Text("真源").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.brand)
            } else {
                Toggle("", isOn: Binding(
                    get: { validSelectedTargets.contains(p.key) },
                    set: { on in
                        if on { selectedTargets.insert(p.key) }
                        else { selectedTargets.remove(p.key) }
                    }
                ))
                .labelsHidden()
                .disabled(!selectable)
            }
        }
        .opacity(selectable || isSource ? 1 : 0.45)
    }

    private func layerStatusText(_ p: ConfigProfile) -> some View {
        var parts: [String] = []
        parts.append("MCP \(p.mcpDisplay)")
        parts.append("指令 \(p.hasRules ? "✓" : "—")")
        parts.append("Skills \(p.hasSkills ? p.skills : "—")")
        if let cmd = p.commands, p.hasCommands {
            parts.append("Cmd \(cmd)")
        }
        if let agt = p.agents, p.hasAgents {
            parts.append("Agents \(agt)")
        }
        if let hooks = p.hooks, p.hasHooks {
            parts.append("Hooks \(hooks)")
        }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private func iconFor(_ key: String) -> String {
        if key.hasPrefix("claude") { return "sparkles" }
        if key.hasPrefix("codex") { return "chevron.left.forwardslash.chevron.right" }
        if key.hasPrefix("cursor") { return "cursorarrow" }
        if key.hasPrefix("trae") { return "t.square" }
        if key.hasPrefix("qoder") { return "q.square" }
        if key.hasPrefix("cline") { return "terminal" }
        return "app.dashed"
    }

    // MARK: - 层选择
    private var layerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("同步层", systemImage: "square.stack.3d.up")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(allLayersSelected ? "全不选" : "全选可用") {
                        setAllLayers(!allLayersSelected)
                    }
                    .font(.system(size: 11))
                    .disabled(availableSourceLayers.isEmpty)
                }
                HStack(spacing: 16) {
                    layerToggle("MCP", isOn: $layerMCP, layer: "mcp")
                    layerToggle("指令", isOn: $layerRules, layer: "rules")
                    layerToggle("Skills", isOn: $layerSkills, layer: "skills")
                }
                HStack(spacing: 16) {
                    layerToggle("Commands", isOn: $layerCommands, layer: "commands")
                    layerToggle("Agents", isOn: $layerAgents, layer: "agents")
                    layerToggle("Hooks", isOn: $layerHooks, layer: "hooks")
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    private func layerToggle(_ title: String, isOn: Binding<Bool>, layer: String) -> some View {
        Toggle(title, isOn: isOn)
            .font(.system(size: 11))
            .disabled(!availableSourceLayers.contains(layer))
    }

    // MARK: - 操作
    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await doPull() }
            } label: {
                Label("拉取真源", systemImage: "tray.and.arrow.down")
                    .font(.system(size: 12))
            }
            .disabled(source.isEmpty || activeLayers.isEmpty || busy)

            Spacer()

            Button {
                openPreview()
            } label: {
                Label("预览并推送", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(validSelectedTargets.isEmpty || activeLayers.isEmpty || busy)
        }
    }

    private func doPull() async {
        let selectedLayers = activeLayers
        guard !source.isEmpty, !selectedLayers.isEmpty else { return }
        busy = true; actionError = nil
        do {
            _ = try await state.configSyncPull(from: source, layers: selectedLayers)
        } catch {
            actionError = (error as? AgentSyncError)?.errorDescription ?? error.localizedDescription
        }
        busy = false
    }

    private func openPreview() {
        let selectedLayers = activeLayers
        guard !selectedLayers.isEmpty else { return }
        actionError = nil
        ConfigSyncWindow.shared.present(
            targets: Array(validSelectedTargets).sorted(),
            layers: selectedLayers,
            state: state
        )
    }
}
