import AppKit
import SwiftUI

// 配置同步的独立窗口：菜单栏面板太窄（360），完整 diff 预览 + 确认写入放这里。
// 复用 LoginSync 的 NSWindow 生命周期模式，内容用 NSHostingView 承载 SwiftUI。
@MainActor
final class ConfigSyncWindow: NSObject, NSWindowDelegate {
    static let shared = ConfigSyncWindow()
    private var window: NSWindow?

    func present(targets: [String], layers: [String], state: AppState) {
        // 已开则先关，避免多窗口
        closeWindow()
        let review = DiffReviewView(
            targets: targets,
            layers: layers,
            onClose: { [weak self] in self?.closeWindow() }
        )
        .environmentObject(state)

        let host = NSHostingView(rootView: review)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.title = "配置同步 — 预览与写入"
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func closeWindow() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    // 危险操作确认：写入前弹 NSAlert（照 Updater.promptInstall 的模式）
    static func confirmApply(targetCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "确认写入 \(targetCount) 个工具的配置？"
        alert.informativeText = "会覆盖目标工具的对应配置段，写入前自动备份，可随时回滚。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确认写入")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - 独立窗口内容

private enum ReviewPhase: Equatable {
    case loading
    case preview
    case applying
    case done(backupTs: String?)
    case rolledBack
    case failed(String)
}

struct DiffReviewView: View {
    @EnvironmentObject var state: AppState
    let targets: [String]
    let layers: [String]
    var onClose: () -> Void

    @State private var phase: ReviewPhase = .loading
    @State private var preview: PushResult?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
            Divider()
            footerBar
        }
        .frame(minWidth: 560, minHeight: 600)
        .task { await loadPreview() }
    }

    private var headerBar: some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.brand)
            Text("目标：\(targets.joined(separator: ", "))  层：\(layers.joined(separator: "+"))")
                .font(.system(size: 12, weight: .medium))
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading, .applying:
            VStack(spacing: 10) {
                ProgressView()
                Text(phase == .loading ? "生成 diff 预览…" : "写入中…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let msg):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(msg).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let ts):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32)).foregroundStyle(.green)
                Text("已写入").font(.system(size: 14, weight: .semibold))
                if let ts {
                    Text("备份时间戳：\(ts)").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("回滚本次写入") { Task { await doRollback(ts: ts) } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .rolledBack:
            VStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 32)).foregroundStyle(Theme.brand)
                Text("已回滚，目标配置已还原").font(.system(size: 13))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .preview:
            previewList
        }
    }

    private var previewList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let preview {
                    let changed = preview.targets.filter { $0.change != "none" }
                    let missing = ConfigPreview.missingTargetLayers(
                        targets: targets,
                        layers: layers,
                        result: preview
                    )
                    if !missing.isEmpty {
                        missingTargetLayerBlock(missing)
                    }
                    if changed.isEmpty && missing.isEmpty {
                        Text("各目标已与真源一致，无需改动。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.top, 40)
                    } else if changed.isEmpty {
                        Text("没有可写入的目标。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(changed) { t in
                        targetBlock(t)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func missingTargetLayerBlock(_ missing: [ConfigSyncTargetLayer]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("部分目标层未返回预览，已视为未同步", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(missing.map { "\($0.target) · \($0.layer.uppercased())" }.joined(separator: "、"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("这些层可能不受目标工具支持。为避免部分同步，本次不能确认写入；请调整目标或同步层后重试。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.corner))
    }

    private func targetBlock(_ t: PushTarget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(t.label).font(.system(size: 13, weight: .bold))
                Text(t.layer.uppercased()).font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.brand.opacity(0.15), in: Capsule())
                Text(changeLabel(t.change)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let path = t.path, !path.isEmpty {
                Text(path).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let reason = t.skipReason, !reason.isEmpty {
                Text("未同步：\(reason)").font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            if let s = t.servers {
                if !s.added.isEmpty {
                    serverDiffLine("新增", s.added, .green)
                }
                if let overwritten = s.overwritten, !overwritten.isEmpty {
                    serverDiffLine("覆盖", overwritten, .orange)
                }
                if let preserved = s.preserved, !preserved.isEmpty {
                    serverDiffLine("保留（目标独有）", preserved, .gray)
                }
            }
            if let items = t.itemsAdded, !items.isEmpty {
                itemDiffLine("新增", items, .green)
            }
            if let present = t.alreadyPresent, !present.isEmpty {
                itemDiffLine("已存在", present, .secondary)
            }
            if let dstOnly = t.dstOnly, !dstOnly.isEmpty {
                itemDiffLine("目标独有", dstOnly, .gray)
            }
            if let diff = t.diffText, !diff.isEmpty {
                DisclosureGroup("完整 diff（已脱敏）") {
                    Text(diff).font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11))
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.corner))
    }

    @ViewBuilder
    private func serverDiffLine(_ label: String, _ names: [String], _ color: Color) -> some View {
        if !names.isEmpty {
            HStack(alignment: .top, spacing: 4) {
                Text("\(label) \(names.count)").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                Text(names.joined(separator: ", ")).font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func itemDiffLine(_ label: String, _ names: [String], _ color: Color) -> some View {
        if !names.isEmpty {
            HStack(alignment: .top, spacing: 4) {
                Text("\(label) \(names.count)").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                Text(names.joined(separator: ", ")).font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func changeLabel(_ c: String) -> String {
        switch c {
        case "create": return "新建文件"
        case "modify": return "修改"
        case "skip_no_create": return "跳过（不存在）"
        case "add": return "补充"
        case "skip": return "跳过"
        default: return c
        }
    }

    private var footerBar: some View {
        HStack {
            Button("关闭") { onClose() }
            Spacer()
            if phase == .preview, let p = preview {
                let writableTargets = ConfigPreview.writableTargetKeys(in: p)
                if ConfigPreview.canApply(targets: targets, layers: layers, result: p) {
                    Button {
                        let n = writableTargets.count
                        if ConfigSyncWindow.confirmApply(targetCount: n) {
                            Task { await doApply() }
                        }
                    } label: {
                        Label("确认写入", systemImage: "square.and.arrow.down.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
    }

    // MARK: 动作

    private func loadPreview() async {
        phase = .loading
        do {
            let r = try await AgentSyncService.pushPreview(to: targets, layers: layers)
            preview = r
            phase = .preview
        } catch {
            phase = .failed((error as? AgentSyncError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func doApply() async {
        phase = .applying
        do {
            let r = try await state.configSyncApply(to: targets, layers: layers)
            phase = .done(backupTs: r.backupTs)
        } catch {
            phase = .failed((error as? AgentSyncError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func doRollback(ts: String) async {
        phase = .applying
        do {
            _ = try await state.configSyncRollback(ts: ts)
            phase = .rolledBack
        } catch {
            phase = .failed((error as? AgentSyncError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
