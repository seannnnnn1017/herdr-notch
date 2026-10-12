import AppKit
import SwiftUI
import QuartzCore


/// Expanded dashboard height; the agent list takes whatever quota rows leave.
let expandedHeight: CGFloat = 600
/// Half-expanded heights: drop targets while a file is dragged, and a one-line notice.
let dropZoneHeight: CGFloat = 152
/// Staged files with a question field, agent switch and send button.
let composeHeight: CGFloat = 150
let toastHeight: CGFloat = 70

func bridge(_ args: [String]) async -> Data? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            let script = Bundle.main.resourceURL?.appendingPathComponent("monitor.py").path ?? "Resources/monitor.py"
            process.arguments = ["python3", script] + args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/Library/Frameworks/Python.framework/Versions/3.13/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + NSHomeDirectory() + "/.local/bin"
            process.environment = env
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            } catch { continuation.resume(returning: nil) }
        }
    }
}

/// Claude Code's statusLine setting needs a path that survives moving or
/// rebuilding the app, so keep a copy of the bundled wrapper in Application Support.
func installClaudeStatusline() {
    guard let source = Bundle.main.url(forResource: "claude_statusline", withExtension: "py"),
          let data = try? Data(contentsOf: source) else { return }
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Herdr Notch")
    let target = directory.appendingPathComponent("claude_statusline.py")
    guard (try? Data(contentsOf: target)) != data else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: target, options: .atomic)
}

func appendNotchLog(_ message: String) {
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Herdr Notch.log")
    let entry = "\(ISO8601DateFormatter().string(from: Date())) \(message.replacingOccurrences(of: "\n", with: " "))\n"
    guard let data = entry.data(using: .utf8) else { return }
    if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, size.intValue > 65_536 {
        try? data.write(to: url, options: .atomic)
    } else if let file = try? FileHandle(forWritingTo: url) {
        defer { try? file.close() }
        _ = try? file.seekToEnd(); try? file.write(contentsOf: data)
    } else { try? data.write(to: url, options: .atomic) }
}

@MainActor final class Model: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var errors: [String] = []
    @Published var machines: [Machine] = []
    @Published var quota: Quota?
    @Published var expanded = false
    @Published var notchWidth: CGFloat = 0
    var compactWidth: CGFloat { max(180, notchWidth + 110) }
    @Published var updated: Date?
    @Published var refreshing = false
    @Published var focusingID: String?
    /// Machine whose sessions the list shows; nil shows every machine.
    @Published var machineFilter: String?
    /// A file drag is in progress somewhere on screen; the notch offers drop targets.
    @Published var dropActive = false
    @Published var launchingKind: String?
    /// Drop target under the dragged file: "claude", "codex" or nil.
    @Published var dropHover: String?
    @Published var toast: String?
    private var toastTask: Task<Void, Never>?
    /// Dropped files wait here with a question until sent.
    @Published var draftFiles: [URL] = []
    @Published var draftKind = "claude"
    @Published var draftText = ""
    var composing: Bool { !draftFiles.isEmpty && launchingKind == nil }
    /// The panel must be key to type while composing, and only then.
    var onComposeChange: ((Bool) -> Void)?
    var showsDropZone: Bool { (dropActive && draftFiles.isEmpty) || launchingKind != nil }
    var panelSize: CGSize {
        if composing { return CGSize(width: 480, height: composeHeight) }
        if showsDropZone { return CGSize(width: 480, height: dropZoneHeight) }
        if toast != nil { return CGSize(width: 480, height: toastHeight) }
        return expanded ? CGSize(width: 480, height: expandedHeight) : CGSize(width: compactWidth, height: 34)
    }
    var visibleAgents: [Agent] { machineFilter.map { id in agents.filter { $0.machineId == id } } ?? agents }
    private var recent = RecentActivity(lastUsed: UserDefaults.standard.dictionary(forKey: "lastUsed") as? [String: Double] ?? [:])
    private func saveRecent() { UserDefaults.standard.set(recent.lastUsed, forKey: "lastUsed") }
    func toggleFilter(_ machineID: String) {
        machineFilter = machineFilter == machineID ? nil : machineID
    }
    @Published var feedback: String?
    @Published var feedbackFailed = false
    var interactionUntil = Date.distantPast
    private var feedbackTask: Task<Void, Never>?
    var onStatus: (() -> Void)?
    var onFeedback: ((String, Bool) -> Void)?
    var onNavigationBegin: (() -> Void)?
    var onNavigationEnd: ((Bool) -> Void)?
    private var polling = false, fetchingQuota = false
    var blocked: Int { agents.filter { $0.status == "blocked" }.count }
    var working: Int { agents.filter { $0.status == "working" }.count }
    private var fleet = FleetInventory()
    func refresh() async {
        guard focusingID == nil, !polling else { return }
        polling = true; defer { polling = false }
        let succeeded = await streamInventory { [weak self] event in self?.apply(event) }
        if !succeeded { errors = fleet.errors + ["部分 Herdr 狀態未完成更新，請稍後重試"] }
        onStatus?()
    }
    private func apply(_ event: InventoryEvent) {
        let oldBlocked = Set(agents.filter { $0.status == "blocked" }.map(\.id))
        fleet.apply(event)
        let now = Date().timeIntervalSince1970
        var changed = recent.observe(fleet.agents, now: now)
        if event.type == "done" { recent.prune(keeping: Set(fleet.agents.map(\.id)), now: now); changed = true }
        if changed { saveRecent() }
        agents = recent.sorted(fleet.agents)
        machines = fleet.machines; errors = fleet.errors; updated = fleet.updated
        if let filter = machineFilter, !machines.contains(where: { $0.id == filter }) { machineFilter = nil }
        if agents.contains(where: { $0.status == "blocked" && !oldBlocked.contains($0.id) }) {
            NSSound(named: "Glass")?.play()
        }
        onStatus?()
    }
    /// `fresh` bypasses the bridge's short cache of Claude's usage report.
    func refreshQuota(fresh: Bool = false) async {
        guard !fetchingQuota else { return }; fetchingQuota = true; defer { fetchingQuota = false }
        if let data = await bridge(fresh ? ["quota", "fresh"] : ["quota"]), let result = try? JSONDecoder().decode(Quota.self, from: data) { quota = result }
        else {
            let now = Date().timeIntervalSince1970
            quota = Quota(providers: ["Codex", "Claude"].map {
                QuotaProvider(id: $0.lowercased(), label: $0, windows: [], updated: now, error: "無法取得額度")
            }, updated: now)
        }
    }
    func setHovered(_ inside: Bool) {
        guard expanded != inside else { return }
        withAnimation(.easeInOut(duration: 0.24)) { expanded = inside }
    }
    func expandFromClick() {
        // Let keyboard/VoiceOver users open the same hover surface too.
        interactionUntil = Date().addingTimeInterval(1.5)
        setHovered(true)
    }
    func report(_ message: String, failed: Bool = false) {
        onFeedback?(message, failed)
        feedbackTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            feedback = message; feedbackFailed = failed
        }
        if failed { interactionUntil = Date().addingTimeInterval(8) }
        feedbackTask = Task {
            try? await Task.sleep(nanoseconds: failed ? 8_000_000_000 : 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { feedback = nil }
        }
    }
    func manualRefresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            // Wait for an existing automatic fetch rather than reporting a
            // refresh as complete while that fetch is still in flight.
            while polling || fetchingQuota || focusingID != nil { try? await Task.sleep(nanoseconds: 50_000_000) }
            await refresh(); await refreshQuota(fresh: true)
            refreshing = false
            let failed = !errors.isEmpty || quota?.providers.contains { $0.error != nil } != false
            report(failed ? "更新完成，部分資料無法取得" : "已更新最新狀態", failed: failed)
        }
    }
    struct FocusFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    /// One JSON object from the bridge; its `error` field becomes a failure.
    private func bridgeReply(_ args: [String], context: String) async throws -> [String: Any] {
        guard let data = await bridge(args),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FocusFailure(message: "Herdr 沒有回應，請稍後重試")
        }
        if let error = result["error"] as? String { throw FocusFailure(message: context + "：" + error) }
        return result
    }
    /// Herdr's own API selects the exact workspace, tab and pane on the
    /// agent's server, and moves clients already viewing that server.
    private func apiFocus(_ agent: Agent) async throws {
        _ = try await bridgeReply(["focus", agent.machineId, agent.session, agent.pane], context: "\(agent.machine) · \(agent.pane)")
    }
    /// The drop target under a point of the notch canvas, measured from its
    /// top-left: "add" on the compose tray, else the left or right agent.
    func dropTarget(x: CGFloat, fromTop: CGFloat, width: CGFloat) -> String? {
        guard x >= 0, x <= width, fromTop >= 0 else { return nil }
        if composing { return fromTop <= composeHeight ? "add" : nil }
        guard dropActive, launchingKind == nil, focusingID == nil, fromTop <= dropZoneHeight else { return nil }
        return x < width / 2 ? "claude" : "codex"
    }
    /// Stage dropped files: a drop on an agent target starts a draft for that
    /// agent, a drop on the tray adds to it.
    func stage(target: String, urls: [URL]) {
        let fresh = urls.filter { url in !draftFiles.contains { $0.path == url.path } }
        guard !urls.isEmpty else { showToast("沒有讀到檔案路徑，請再拖一次"); return }
        let starting = draftFiles.isEmpty
        if starting, target != "add" { draftKind = target }
        withAnimation(.easeInOut(duration: 0.2)) { draftFiles += fresh; dropActive = false }
        dropHover = nil
        if starting { onComposeChange?(true) }
    }
    func removeDraftFile(_ url: URL) {
        withAnimation(.easeInOut(duration: 0.15)) { draftFiles.removeAll { $0.path == url.path } }
        if draftFiles.isEmpty { cancelDraft() }
    }
    func cancelDraft() {
        withAnimation(.easeInOut(duration: 0.2)) { draftFiles = []; draftText = "" }
        dropHover = nil
        onComposeChange?(false)
    }
    func sendDraft() {
        guard composing else { return }
        let files = draftFiles, kind = draftKind, text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        draftFiles = []; draftText = ""
        onComposeChange?(false)
        launch(kind: kind, urls: files, prompt: text)
    }
    func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { toast = message }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { toast = nil }
        }
    }
    /// Dropped files open a new agent in a fresh tab of the local Herdr
    /// session, with their paths handed to it, and the client jumps there.
    func launch(kind: String, urls: [URL], prompt: String = "") {
        let name = kind == "claude" ? "Claude" : "Codex"
        guard focusingID == nil, !urls.isEmpty else {
            let reason = urls.isEmpty ? "沒有讀到檔案路徑，請再拖一次" : "上一個切換還在進行，請稍後再試"
            appendNotchLog("FAILED: launch \(kind): " + reason)
            launchingKind = nil; dropActive = false
            showToast(reason)
            return
        }
        guard let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first else {
            launchingKind = nil; dropActive = false
            showToast("找不到已開啟的 Ghostty／Herdr 視窗")
            return
        }
        launchingKind = kind
        focusingID = "launch"
        Task {
            var handedOff = false
            var succeeded = false
            var restoreDraft: ([URL], String, String)?
            defer {
                focusingID = nil; launchingKind = nil; dropActive = false; dropHover = nil
                if handedOff { onNavigationEnd?(succeeded) }
                if let (files, kind, text) = restoreDraft {
                    draftFiles = files; draftKind = kind; draftText = text
                    onComposeChange?(true)
                }
            }
            let paths = urls.map(\.path)
            do {
                let tab = try await bridgeReply(["launch-tab", kind] + paths, context: "無法開啟 \(name)")
                guard let pane = tab["pane"] as? String, let tabID = tab["tab"] as? String else {
                    throw FocusFailure(message: "Herdr 沒有回傳新分頁")
                }
                var agent = Agent(id: "local:default:" + pane, machineId: "local", machine: "Local", pane: pane, session: "default",
                                  title: tab["label"] as? String ?? name, cwd: tab["cwd"] as? String ?? "", status: "unknown")
                agent.workspace = tab["workspace"] as? String
                agent.agent = kind
                // The agent starts while Ghostty is brought over; a startup
                // dialog must not hold the jump for the readiness timeout.
                let started = Task { await bridge(["launch-agent", kind, pane] + (prompt.isEmpty ? [] : ["--prompt", prompt]) + paths) }
                try await GhosttyNavigation.switchPane(
                    agent: agent, machines: machines,
                    knownTitles: agents.map(\.title) + machines.flatMap { $0.workspaces ?? [] } + [agent.workspace ?? ""],
                    app: terminal,
                    focusAPI: { _ = try await self.bridgeReply(["focus-tab", tabID], context: "Local · \(pane)") },
                    handoff: { if !handedOff { handedOff = true; self.onNavigationBegin?() } },
                    diagnostic: { appendNotchLog($0) }
                )
                succeeded = true
                let outcome = await started.value.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let message: String
                if outcome["submitted"] as? Bool == true { message = "已送出給 \(name)" }
                else if !prompt.isEmpty { message = "已開啟分頁，但 \(name) 未啟動：\(outcome["startError"] as? String ?? "未知錯誤")" }
                else if outcome["pasted"] as? Bool == true { message = "已開啟 \(name)，檔案路徑已填入" }
                else if outcome["copied"] as? Bool == true { message = "已開啟 \(name)；路徑已複製，處理完提示後按 ⌘V 貼上" }
                else { message = "已開啟 \(name)，但檔案路徑未能填入" }
                appendNotchLog("OK: " + message)
                showToast(message)
            } catch {
                appendNotchLog("FAILED: " + error.localizedDescription)
                showToast(error.localizedDescription)
                // Nothing was sent: keep what was typed for another try.
                if !prompt.isEmpty, !succeeded { restoreDraft = (urls, kind, prompt) }
            }
        }
    }
    func focus(_ agent: Agent) {
        guard focusingID == nil else { return }
        guard let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first else {
            report("找不到已開啟的 Ghostty／Herdr 視窗", failed: true)
            return
        }
        focusingID = agent.id
        recent.touch(agent.id, now: Date().timeIntervalSince1970); saveRecent()
        agents = recent.sorted(agents)
        Task {
            var handedOff = false
            var succeeded = false
            defer {
                focusingID = nil
                if handedOff { onNavigationEnd?(succeeded) }
            }
            await Task.yield()
            do {
                // The clicked row already identifies the target. Do not wait
                // for unrelated machines or a background inventory refresh.
                try await GhosttyNavigation.switchPane(
                    agent: agent, machines: machines,
                    knownTitles: [agent.title] + agents.map(\.title) + machines.flatMap { $0.workspaces ?? [] },
                    app: terminal,
                    focusAPI: { try await self.apiFocus(agent) },
                    // Hide only when the actual Ghostty handoff starts.
                    handoff: { if !handedOff { handedOff = true; self.onNavigationBegin?() } },
                    diagnostic: { appendNotchLog($0) }
                )
                succeeded = true
            } catch {
                report(error.localizedDescription, failed: true)
                return
            }
            report("已切換：\(agent.machine) · \(agent.pane)")
        }
    }

}

struct ResponsiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FeedbackButton(configuration: configuration)
    }
    private struct FeedbackButton: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(configuration.isPressed ? 0.12 : hovered ? 0.05 : 0)).allowsHitTesting(false))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

struct Dashboard: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(spacing: 0) {
            Button { model.expandFromClick() } label: { HStack {
                HStack(spacing: 5) {
                    Circle().fill(model.errors.isEmpty ? Color.mint : .orange).frame(width: 6,height: 6)
                    Text(model.expanded ? "\(model.working) 執行" : "\(model.working)")
                }
                Spacer(minLength: model.notchWidth)
                HStack(spacing: 5) {
                    Image(systemName: model.blocked > 0 ? "exclamationmark.bubble.fill" : "terminal")
                    Text(model.expanded ? (model.blocked > 0 ? "\(model.blocked) 待回覆" : "\(model.agents.count) sessions") : "\(model.blocked > 0 ? model.blocked : model.agents.count)")
                }.foregroundColor(model.blocked > 0 ? .orange : .white)
            }.font(.system(size: 11, weight: .medium, design: .monospaced)).frame(height: 34).padding(.horizontal, 16)
                .contentShape(Rectangle())
                .help("\(model.working) 個工作中，\(model.blocked) 個待回覆，\(model.agents.count) 個 sessions；移入展開")
            }.buttonStyle(.plain).accessibilityLabel("展開 Herdr 工作台")
            if model.composing {
                ComposeTray(model: model).transition(.opacity)
            } else if model.showsDropZone {
                DropZone(model: model).transition(.opacity)
            } else if let toast = model.toast {
                Text(toast).font(.system(size: 11, weight: .medium)).foregroundColor(.mint)
                    .lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity)
            } else if model.expanded {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) { Text("HERDR").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.mint); Text("你的 Agent 工作台").font(.system(size: 21, weight: .semibold)) }
                        Spacer()
                        Button { model.manualRefresh() } label: {
                            Group {
                                if model.refreshing { ProgressView().controlSize(.small) }
                                else { Image(systemName: "arrow.clockwise") }
                            }.frame(width: 30, height: 30).background(Color.white.opacity(0.06)).cornerRadius(10)
                        }.disabled(model.refreshing).help(model.refreshing ? "正在更新…" : "重新整理")
                            .accessibilityLabel(model.refreshing ? "正在更新" : "重新整理")
                    }.buttonStyle(ResponsiveButtonStyle())
                    HStack(spacing: 8) {
                        badge("工作中", model.working, .mint)
                        badge("需要回覆", model.blocked, .orange)
                        badge("Sessions", model.agents.count, .white)
                    }
                    HStack(spacing: 10) {
                        ForEach(model.machines) { machine in
                            let selected = model.machineFilter == machine.id
                            Button { withAnimation(.easeOut(duration: 0.15)) { model.toggleFilter(machine.id) } } label: {
                                HStack(spacing: 4) {
                                    Circle().fill(machine.state == "online" ? Color.mint : .orange).frame(width: 5, height: 5)
                                    Text("\(machine.label) · \(machine.state == "online" ? "\(machine.agentCount)" : (machine.state == "checking" ? "連線中" : "離線"))")
                                        .lineLimit(1)
                                }.font(.system(size: 10, design: .monospaced))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color.white.opacity(selected ? 0.16 : 0.0001)).cornerRadius(6)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(selected ? 0.35 : 0), lineWidth: 1))
                                    .opacity(model.machineFilter == nil || selected ? 1 : 0.45)
                            }.buttonStyle(.plain).help(selected ? "顯示所有機器" : "只顯示 \(machine.label)")
                                .accessibilityLabel(selected ? "取消篩選 \(machine.label)" : "只顯示 \(machine.label)")
                        }
                    }
                    ScrollView {
                        VStack(spacing: 7) {
                            if model.agents.isEmpty { Text(model.errors.isEmpty ? "目前沒有 Herdr Codex / Claude sessions" : "Herdr 尚未連線").foregroundColor(.gray).padding(20) }
                            else if model.visibleAgents.isEmpty { Text("這台機器目前沒有 sessions").foregroundColor(.gray).padding(20) }
                            ForEach(model.visibleAgents) { a in
                                Button { model.focus(a) } label: {
                                    HStack(spacing: 10) {
                                        Circle().fill(a.color).frame(width: 7,height: 7)
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 6) {
                                                Text(a.kindLabel).font(.system(size: 9, weight: .semibold, design: .monospaced))
                                                    .foregroundColor(a.kindColor).padding(.horizontal, 5).padding(.vertical, 1)
                                                    .background(a.kindColor.opacity(0.15)).cornerRadius(4)
                                                Text(a.title).font(.system(size: 13,weight: .medium)).lineLimit(1)
                                            }
                                            Text("\(a.machine) · \(a.session) · \(a.pane) · \(a.cwd)").font(.system(size: 10,design: .monospaced)).foregroundColor(.gray).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer(minLength: 4)
                                        Text(a.label).font(.system(size: 10,weight: .medium)).foregroundColor(a.color)
                                        if model.focusingID == a.id {
                                            ProgressView().controlSize(.small).frame(width: 12, height: 12)
                                        } else {
                                            Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundColor(.gray)
                                        }
                                    }.padding(11).background(a.status == "blocked" ? Color.orange.opacity(0.13) : Color.white.opacity(0.06)).cornerRadius(10)
                                }.buttonStyle(ResponsiveButtonStyle()).disabled(model.focusingID != nil).help("開啟 \(a.machine) 的原有 Herdr session")
                            }
                        }
                    }.frame(maxHeight: 254)
                    Divider().overlay(Color.white.opacity(0.1))
                    HStack { Text("本機登入帳號剩餘額度").font(.system(size: 12,weight: .semibold)); Spacer() }
                    if let q = model.quota {
                        ForEach(q.providers) { provider in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(provider.label).font(.system(size: 11, weight: .semibold)).foregroundColor(provider.id == "claude" ? Agent.claudeColor : .white)
                                    Spacer()
                                    if provider.error == nil { Text(Date(timeIntervalSince1970: provider.updated), style: .time).font(.system(size: 10)).foregroundColor(.gray) }
                                }
                                if let error = provider.error { Text(error).font(.system(size: 10)).foregroundColor(.orange).lineLimit(2) }
                                else if provider.windows.isEmpty { Text("目前沒有額度資料").font(.system(size: 10)).foregroundColor(.gray) }
                                ForEach(provider.windows) { w in
                                    HStack(spacing: 8) {
                                        Text(w.label).font(.system(size: 10)).frame(width: 64, alignment: .leading).lineLimit(1)
                                        ProgressView(value: w.remaining, total: 100).tint(w.remaining < 20 ? .orange : .mint)
                                        Text("\(Int(w.remaining))%").font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundColor(w.remaining < 20 ? .orange : .mint).frame(width: 38, alignment: .trailing)
                                        Text(w.resetsAt.map { "重置 " + Date(timeIntervalSince1970: $0).formatted(.dateTime.month(.defaultDigits).day().hour().minute()) } ?? "")
                                            .font(.system(size: 9)).foregroundColor(.gray).frame(width: 96, alignment: .trailing).lineLimit(1)
                                    }
                                }
                            }
                        }
                    } else { Text("正在讀取額度…").font(.system(size:11)).foregroundColor(.gray) }
                    ForEach(model.errors,id:\.self) { Text($0).font(.system(size:10)).foregroundColor(.orange).lineLimit(2) }
                    if let feedback = model.feedback {
                        Label(feedback, systemImage: model.feedbackFailed ? "exclamationmark.circle" : "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundColor(model.feedbackFailed ? .orange : .mint)
                            .lineLimit(1).transition(.opacity)
                    }
                    Text("各機器分開更新 · 剩餘額度每 60 秒更新").font(.system(size:9,design:.monospaced)).foregroundColor(.gray)
                }.padding(.horizontal,20).padding(.top,15).padding(.bottom,20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }.frame(width: model.panelSize.width, height: model.panelSize.height, alignment: .top)
            .background(Color.black).foregroundColor(.white)
            .clipShape(UnevenRoundedRectangleCompat())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .preferredColorScheme(.dark)
    }
    func badge(_ label:String,_ value:Int,_ color:Color) -> some View {
        HStack { Text(label).font(.system(size:10)); Spacer(); Text("\(value)").font(.system(size:16,weight:.semibold,design:.monospaced)) }.foregroundColor(color).padding(10).background(color.opacity(0.08)).cornerRadius(9)
    }
}
/// Shown while a file is dragged anywhere: one target per agent kind.
struct DropZone: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                DropTarget(model: model, kind: "claude", label: "Claude", color: Agent.claudeColor)
                DropTarget(model: model, kind: "codex", label: "Codex", color: Color(white: 0.85))
            }
            Text(model.launchingKind == nil ? "把檔案拖到這裡，在本機 Herdr 開新 session" : "正在開啟新分頁並跳轉…")
                .font(.system(size: 10)).foregroundColor(.gray)
        }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 14)
    }
}
/// Staged files, a question, the agent choice and a send button.
struct ComposeTray: View {
    @ObservedObject var model: Model
    @FocusState private var typing: Bool
    var body: some View {
        let adding = model.dropHover == "add"
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.draftFiles, id: \.path) { url in
                            HStack(spacing: 4) {
                                Image(systemName: url.hasDirectoryPath ? "folder.fill" : "doc.fill").font(.system(size: 9))
                                Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 130)
                                Button { model.removeDraftFile(url) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                    .buttonStyle(.plain).foregroundColor(.gray).help("移除 \(url.lastPathComponent)")
                            }.padding(.horizontal, 7).padding(.vertical, 4).background(Color.white.opacity(0.10)).cornerRadius(6)
                        }
                    }
                }
                Button { model.cancelDraft() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 15)) }
                    .buttonStyle(.plain).foregroundColor(.gray).help("取消（Esc）").accessibilityLabel("取消")
            }.frame(height: 24)
            HStack(spacing: 6) {
                ForEach([("claude", "Claude", Agent.claudeColor), ("codex", "Codex", Color(white: 0.85))], id: \.0) { kind, label, color in
                    let selected = model.draftKind == kind
                    Button { model.draftKind = kind } label: {
                        Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(selected ? color : .gray)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(color.opacity(selected ? 0.18 : 0.0001)).cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(selected ? 0.6 : 0.15), lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel("送給 \(label)")
                }
                Spacer()
                Text(adding ? "放開以加入" : "可繼續拖入檔案").font(.system(size: 10)).foregroundColor(adding ? .mint : .gray)
            }
            HStack(spacing: 8) {
                TextField("輸入問題，Enter 送出；留空則只帶入檔案", text: $model.draftText)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($typing)
                    .onSubmit { model.sendDraft() }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.white.opacity(0.08)).cornerRadius(8)
                Button { model.sendDraft() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)) }
                    .buttonStyle(.plain).foregroundColor(model.draftKind == "claude" ? Agent.claudeColor : Color(white: 0.85))
                    .help("送出").accessibilityLabel("送出")
            }
        }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 14)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.mint.opacity(adding ? 0.8 : 0), lineWidth: 1.5).padding(.horizontal, 10).padding(.bottom, 6))
            .onExitCommand { model.cancelDraft() }
            .onAppear { DispatchQueue.main.async { typing = true } }
    }
}
struct DropTarget: View {
    @ObservedObject var model: Model
    let kind, label: String
    let color: Color
    var body: some View {
        let busy = model.launchingKind == kind
        // The hosting view receives the drop and reports which half is under
        // the pointer; SwiftUI's own drop destinations were misplaced here.
        let targeted = model.dropHover == kind && model.launchingKind == nil
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) } else { Image(systemName: "plus.circle.fill") }
            Text(busy ? "正在開啟 \(label)…" : "新 \(label) session").font(.system(size: 13, weight: .semibold))
        }.foregroundColor(color).frame(maxWidth: .infinity).frame(height: 72)
            .background(color.opacity(targeted ? 0.28 : 0.10)).cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(targeted ? 0.9 : 0.35),
                style: StrokeStyle(lineWidth: 1.5, dash: targeted ? [] : [5, 4])))
            .scaleEffect(targeted ? 1.02 : 1).animation(.easeOut(duration: 0.12), value: targeted)
            .opacity(model.launchingKind == nil || busy ? 1 : 0.4)
    }
}
struct UnevenRoundedRectangleCompat: Shape {
    func path(in r:CGRect) -> Path {
        var p=Path(); let radius:CGFloat=20
        p.move(to:CGPoint(x:0,y:0)); p.addLine(to:CGPoint(x:r.maxX,y:0)); p.addLine(to:CGPoint(x:r.maxX,y:r.maxY-radius))
        p.addQuadCurve(to:CGPoint(x:r.maxX-radius,y:r.maxY),control:CGPoint(x:r.maxX,y:r.maxY))
        p.addLine(to:CGPoint(x:radius,y:r.maxY)); p.addQuadCurve(to:CGPoint(x:0,y:r.maxY-radius),control:CGPoint(x:0,y:r.maxY)); p.closeSubpath(); return p
    }
}
class NotchPanel: NSPanel {
    /// Key only while composing, so the question field can take typing
    /// without the notch ever activating the app or stealing focus otherwise.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    // A notch must remain flush with the physical screen edge, including while
    // animating. Standard window constraints can push it below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    // Dashboard buttons should accept a click while another app is active,
    // without making this nonactivating panel the key window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// File drops are handled here rather than with SwiftUI's onDrop, whose
    /// platform drop views were all placed at the zone's origin, so only the
    /// left target ever received a drag. The zone is split down the middle.
    var dropTarget: (_ x: CGFloat, _ fromTop: CGFloat, _ width: CGFloat) -> String? = { _, _, _ in nil }
    var dropHover: (String?) -> Void = { _ in }
    var dropPerform: (String, [URL]) -> Void = { _, _ in }
    private func dropKind(_ sender: NSDraggingInfo) -> String? {
        let point = convert(sender.draggingLocation, from: nil)
        return dropTarget(point.x, isFlipped ? point.y : bounds.height - point.y, bounds.width)
    }
    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        let kind = dropKind(sender)
        dropHover(kind)
        return kind == nil ? [] : .copy
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHover(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHover(nil) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dropKind(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let kind = dropKind(sender) else { return false }
        // Any file type or folder: only its path is handed to the agent.
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        dropPerform(kind, urls)
        return true
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model=Model()
    var panel:NotchPanel!, item:NSStatusItem!, poll:Timer?, quotaTimer:Timer?, hoverTimer:Timer?
    private var hoverExitAt: Date?
    private var wantsVisible = true
    private var visibilityGeneration = 0
    private var navigationSuspended = false
    private var needsPointerExit = false
    private var expandedBeforeNavigation = false
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
        appendNotchLog("Started")
        installClaudeStatusline()
        model.onFeedback = { message, failed in appendNotchLog("\(failed ? "FAILED" : "OK"): \(message)") }
        panel=NotchPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=false; panel.level = .statusBar
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]; panel.hidesOnDeactivate=false
        let hosting = NotchHostingView(rootView:Dashboard(model:model))
        hosting.sizingOptions = []
        hosting.registerForDraggedTypes([.fileURL])
        hosting.dropTarget = { [weak self] x, fromTop, width in self?.model.dropTarget(x: x, fromTop: fromTop, width: width) }
        hosting.dropHover = { [weak self] kind in
            guard let self, self.model.dropHover != kind else { return }
            self.model.dropHover = kind
        }
        hosting.dropPerform = { [weak self] kind, urls in
            guard let self else { return }
            appendNotchLog("drop \(kind): \(urls.count) file URL(s)")
            self.model.stage(target: kind, urls: urls)
        }
        model.onComposeChange = { [weak self] composing in
            guard let self else { return }
            self.panel.allowsKey = composing
            if composing {
                self.panel.makeKey()
            } else if self.panel.isKeyWindow, !self.navigationSuspended {
                // Reordering is what actually hands key status back.
                self.panel.orderOut(nil)
                if self.wantsVisible { self.panel.orderFrontRegardless() }
            }
        }
        panel.contentView=hosting
        model.onStatus = { [weak self] in self?.item.button?.title = self?.model.blocked ?? 0 > 0 ? " ◉ \(self?.model.blocked ?? 0)" : " ◉ \(self?.model.working ?? 0)" }
        model.onNavigationBegin = { [weak self] in self?.beginNavigation() }
        model.onNavigationEnd = { [weak self] succeeded in self?.endNavigation(succeeded: succeeded) }
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.title=" ◉"; item.button?.target=self; item.button?.action=#selector(menuClick)
        item.button?.sendAction(on:[.leftMouseUp,.rightMouseUp]); item.button?.toolTip="Herdr Notch — 滑鼠移到瀏海展開，右鍵選單"
        NotificationCenter.default.addObserver(self,selector:#selector(screenChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        position(); panel.orderFrontRegardless()
        watchFileDrags()
        // Check the live window bounds so resizing the SwiftUI view cannot
        // generate a spurious hover exit. Keep it open while using its controls.
        hoverTimer=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.navigationSuspended else {
                    self.panel.ignoresMouseEvents = true
                    return
                }
                if self.model.showsDropZone || self.model.composing || self.model.toast != nil {
                    // Take the pointer only over the visible zone or tray; the
                    // rest of the canvas keeps passing events to the app underneath.
                    self.panel.ignoresMouseEvents = !((self.model.showsDropZone || self.model.composing) && self.wantsVisible
                        && self.panel.isVisible && self.targetFrame().contains(NSEvent.mouseLocation))
                    return
                }
                if self.needsPointerExit {
                    self.panel.ignoresMouseEvents = true
                    if !self.targetFrame().contains(NSEvent.mouseLocation) {
                        self.needsPointerExit = false
                    }
                    return
                }
                // Use destination bounds, not intermediate animated bounds.
                // Brief pointer exits should not make the panel flicker.
                let inside = self.wantsVisible && self.panel.isVisible && self.targetFrame().contains(NSEvent.mouseLocation)
                // The full-size transparent canvas is never a mouse blocker.
                self.panel.ignoresMouseEvents = !inside
                if inside {
                    self.hoverExitAt = nil
                    self.model.setHovered(true)
                } else if self.model.expanded && self.model.focusingID == nil && Date() >= self.model.interactionUntil {
                    if self.hoverExitAt == nil { self.hoverExitAt = Date() }
                    if Date().timeIntervalSince(self.hoverExitAt!) >= 0.2 {
                        self.model.setHovered(false); self.hoverExitAt = nil
                    }
                }
            }
        }
        Task { await model.refresh(); await model.refreshQuota() }
        poll=Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in Task { await self?.model.refresh() } }
        quotaTimer=Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in Task { await self?.model.refreshQuota() } }
    }
    /// Finder and other apps own the drag, so watch it globally: the drag
    /// pasteboard changes when a drag starts, and holds file URLs for a file drag.
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    func watchFileDrags() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.fileDrag(event) }
        }
    }
    private func fileDrag(_ event: NSEvent) {
        let board = NSPasteboard(name: .drag)
        switch event.type {
        case .leftMouseDown:
            dragBaseline = board.changeCount
        case .leftMouseDragged:
            guard !model.dropActive, wantsVisible, !navigationSuspended, model.focusingID == nil,
                  board.changeCount != dragBaseline,
                  board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
            appendNotchLog("drag: file drag detected")
            withAnimation(.easeInOut(duration: 0.2)) { model.dropActive = true }
        case .leftMouseUp:
            dragBaseline = board.changeCount
            guard model.dropActive else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.model.launchingKind == nil else { return }
                self.model.dropHover = nil
                withAnimation(.easeInOut(duration: 0.2)) { self.model.dropActive = false }
            }
        default: break
        }
    }
    func beginNavigation() {
        expandedBeforeNavigation = model.expanded
        navigationSuspended = true
        visibilityGeneration += 1
        hoverExitAt = nil
        panel.ignoresMouseEvents = true
        if panel.isKeyWindow { panel.resignKey() }
        panel.orderOut(nil)
        model.expanded = false
        model.interactionUntil = .distantPast
    }
    func endNavigation(succeeded: Bool) {
        // Successful handoff restores the compact surface without taking
        // focus. A failure restores the dashboard so its error stays visible.
        model.expanded = succeeded ? false : expandedBeforeNavigation
        model.interactionUntil = succeeded ? .distantPast : Date().addingTimeInterval(8)
        navigationSuspended = false
        needsPointerExit = succeeded
        hoverExitAt = nil
        panel.ignoresMouseEvents = true
        panel.alphaValue = 1
        if wantsVisible { panel.orderFrontRegardless() }
    }
    func targetFrame() -> NSRect {
        guard let screen=NSScreen.screens.first(where:{$0.safeAreaInsets.top>0}) ?? NSScreen.main else{return .zero}
        let height = model.panelSize.height, width = model.panelSize.width
        return NSRect(x:screen.frame.midX-width/2,y:screen.frame.maxY-height,width:width,height:height)
    }
    func position() {
        guard let screen=NSScreen.screens.first(where:{$0.safeAreaInsets.top>0}) ?? NSScreen.main else{return}
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchWidth = max(0, right.minX - left.maxX)
        } else { model.notchWidth = 0 }
        // Animate only the SwiftUI silhouette in a stationary, top-aligned
        // canvas. Animating both the window frame and layout causes a seam.
        panel.setFrame(NSRect(x:screen.frame.midX-240,y:screen.frame.maxY-expandedHeight,width:480,height:expandedHeight),display:true)
    }
    @objc func screenChanged(){position()}
    @objc func menuClick(){
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu=NSMenu(); menu.addItem(withTitle:"顯示／隱藏瀏海",action:#selector(toggleVisibility),keyEquivalent:"").target=self
            menu.addItem(.separator()); menu.addItem(withTitle:"結束 Herdr Notch",action:#selector(quit),keyEquivalent:"q").target=self
            item.menu=menu; item.button?.performClick(nil); item.menu=nil
        } else { model.setHovered(false); setVisible(true) }
    }
    func setVisible(_ visible: Bool) {
        wantsVisible = visible; visibilityGeneration += 1
        guard !navigationSuspended else { return }
        let generation = visibilityGeneration
        if visible && !panel.isVisible {
            panel.alphaValue = 0; panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityGeneration == generation else { return }
                if !visible { self.panel.orderOut(nil) }
            }
        }
    }
    @objc func toggleVisibility(){model.setHovered(false); setVisible(!wantsVisible)}
    @objc func quit(){NSApp.terminate(nil)}
}
MainActor.assumeIsolated {
    let app=NSApplication.shared
    let delegate=AppDelegate()
    app.delegate=delegate
    app.run()
}
