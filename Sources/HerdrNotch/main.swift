import AppKit
import SwiftUI
import QuartzCore


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
        agents = fleet.agents.sorted { a,b in
            let rank = ["blocked":0,"working":1,"done":2,"idle":3,"unknown":4]
            return (rank[a.status] ?? 5, a.id) < (rank[b.status] ?? 5, b.id)
        }
        machines = fleet.machines; errors = fleet.errors; updated = fleet.updated
        if agents.contains(where: { $0.status == "blocked" && !oldBlocked.contains($0.id) }) {
            NSSound(named: "Glass")?.play()
        }
        onStatus?()
    }
    func refreshQuota() async {
        guard !fetchingQuota else { return }; fetchingQuota = true; defer { fetchingQuota = false }
        if let data = await bridge(["quota"]), let result = try? JSONDecoder().decode(Quota.self, from: data) { quota = result }
        else { quota = Quota(windows: [], updated: Date().timeIntervalSince1970, error: "無法取得額度") }
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
            await refresh(); await refreshQuota()
            refreshing = false
            let failed = !errors.isEmpty || quota?.error != nil
            report(failed ? "更新完成，部分資料無法取得" : "已更新最新狀態", failed: failed)
        }
    }
    struct FocusFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    /// Herdr's own API selects the exact workspace, tab and pane on the
    /// agent's server, and moves clients already viewing that server.
    private func apiFocus(_ agent: Agent) async throws {
        guard let data = await bridge(["focus", agent.machineId, agent.session, agent.pane]),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FocusFailure(message: "Herdr 沒有回應切換指令，請稍後重試")
        }
        if let error = result["error"] as? String {
            throw FocusFailure(message: "\(agent.machine) · \(agent.pane)：\(error)")
        }
    }
    func focus(_ agent: Agent) {
        guard focusingID == nil else { return }
        guard let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first else {
            report("找不到已開啟的 Ghostty／Herdr 視窗", failed: true)
            return
        }
        focusingID = agent.id
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
            if model.expanded {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) { Text("HERDR").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.mint); Text("你的 Codex 工作台").font(.system(size: 21, weight: .semibold)) }
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
                            HStack(spacing: 4) {
                                Circle().fill(machine.state == "online" ? Color.mint : .orange).frame(width: 5, height: 5)
                                Text("\(machine.label) · \(machine.state == "online" ? "\(machine.agentCount)" : (machine.state == "checking" ? "連線中" : "離線"))")
                                    .lineLimit(1)
                            }.font(.system(size: 10, design: .monospaced))
                        }
                    }
                    ScrollView {
                        VStack(spacing: 7) {
                            if model.agents.isEmpty { Text(model.errors.isEmpty ? "目前沒有 Herdr Codex sessions" : "Herdr 尚未連線").foregroundColor(.gray).padding(20) }
                            ForEach(model.agents) { a in
                                Button { model.focus(a) } label: {
                                    HStack(spacing: 10) {
                                        Circle().fill(a.color).frame(width: 7,height: 7)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(a.title).font(.system(size: 13,weight: .medium)).lineLimit(1)
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
                    }.frame(maxHeight: 174)
                    Divider().overlay(Color.white.opacity(0.1))
                    HStack { Text("Mac 登入帳號剩餘額度").font(.system(size: 12,weight: .semibold)); Spacer(); if let q = model.quota { Text(Date(timeIntervalSince1970:q.updated), style: .time).font(.system(size: 10)).foregroundColor(.gray) } }
                    if let q = model.quota {
                        if let error = q.error { Text("額度無法取得：\(error)").font(.system(size: 11)).foregroundColor(.orange).lineLimit(2) }
                        else if q.windows.isEmpty { Text("此帳號未提供配額資料").font(.system(size:11)).foregroundColor(.gray) }
                        else {
                            ForEach(q.windows) { w in
                                VStack(alignment:.leading, spacing:5) {
                                    HStack { Text(w.label).font(.system(size:11)); Spacer(); Text("\(Int(w.remaining))% 剩餘").font(.system(size:12,weight:.semibold,design:.monospaced)).foregroundColor(w.remaining < 20 ? .orange : .mint) }
                                    ProgressView(value:w.remaining,total:100).tint(w.remaining < 20 ? .orange : .mint)
                                    if let reset=w.resetsAt { Text("重置：\(Date(timeIntervalSince1970:reset).formatted(date:.abbreviated,time:.shortened))").font(.system(size:10)).foregroundColor(.gray) }
                                }
                            }
                        }
                    } else { Text("正在讀取 Codex 額度…").font(.system(size:11)).foregroundColor(.gray) }
                    ForEach(model.errors,id:\.self) { Text($0).font(.system(size:10)).foregroundColor(.orange).lineLimit(2) }
                    if let feedback = model.feedback {
                        Label(feedback, systemImage: model.feedbackFailed ? "exclamationmark.circle" : "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundColor(model.feedbackFailed ? .orange : .mint)
                            .lineLimit(1).transition(.opacity)
                    }
                    Text("各機器分開更新 · 額度每 60 秒更新").font(.system(size:9,design:.monospaced)).foregroundColor(.gray)
                }.padding(.horizontal,20).padding(.top,15).padding(.bottom,20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }.frame(width: model.expanded ? 480 : model.compactWidth, height: model.expanded ? 520 : 34, alignment: .top)
            .background(Color.black).foregroundColor(.white)
            .clipShape(UnevenRoundedRectangleCompat())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .preferredColorScheme(.dark)
    }
    func badge(_ label:String,_ value:Int,_ color:Color) -> some View {
        HStack { Text(label).font(.system(size:10)); Spacer(); Text("\(value)").font(.system(size:16,weight:.semibold,design:.monospaced)) }.foregroundColor(color).padding(10).background(color.opacity(0.08)).cornerRadius(9)
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
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // A notch must remain flush with the physical screen edge, including while
    // animating. Standard window constraints can push it below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    // Dashboard buttons should accept a click while another app is active,
    // without making this nonactivating panel the key window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
        model.onFeedback = { message, failed in appendNotchLog("\(failed ? "FAILED" : "OK"): \(message)") }
        panel=NotchPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=false; panel.level = .statusBar
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]; panel.hidesOnDeactivate=false
        let hosting = NotchHostingView(rootView:Dashboard(model:model))
        hosting.sizingOptions = []
        panel.contentView=hosting
        model.onStatus = { [weak self] in self?.item.button?.title = self?.model.blocked ?? 0 > 0 ? " ◉ \(self?.model.blocked ?? 0)" : " ◉ \(self?.model.working ?? 0)" }
        model.onNavigationBegin = { [weak self] in self?.beginNavigation() }
        model.onNavigationEnd = { [weak self] succeeded in self?.endNavigation(succeeded: succeeded) }
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.title=" ◉"; item.button?.target=self; item.button?.action=#selector(menuClick)
        item.button?.sendAction(on:[.leftMouseUp,.rightMouseUp]); item.button?.toolTip="Herdr Notch — 滑鼠移到瀏海展開，右鍵選單"
        NotificationCenter.default.addObserver(self,selector:#selector(screenChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        position(); panel.orderFrontRegardless()
        // Check the live window bounds so resizing the SwiftUI view cannot
        // generate a spurious hover exit. Keep it open while using its controls.
        hoverTimer=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.navigationSuspended else {
                    self.panel.ignoresMouseEvents = true
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
        let height:CGFloat=model.expanded ? 520 : 34, width:CGFloat=model.expanded ? 480 : model.compactWidth
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
        panel.setFrame(NSRect(x:screen.frame.midX-240,y:screen.frame.maxY-520,width:480,height:520),display:true)
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
