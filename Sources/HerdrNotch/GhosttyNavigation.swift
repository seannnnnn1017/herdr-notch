import AppKit

/// Brings the single Herdr client in Ghostty to an agent.
///
/// Herdr's `agent focus` API selects the exact pane on the agent's server and
/// moves clients already viewing that server. Which machine a client views is
/// client-local state with no API, so a client on another machine is first
/// stepped across the sidebar with Herdr's direct `next_workspace` /
/// `previous_workspace` shortcuts, one press at a time, each acknowledged by
/// the outer window title. No screen text is read and no Accessibility is used.
@MainActor enum GhosttyNavigation {
    private static var preferredTerminalID: String?
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
    nonisolated static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func script(_ body: String) async throws -> String {
        let source = "with timeout of 3 seconds\ntell application id \"com.mitchellh.ghostty\"\n" + body + "\nend tell\nend timeout"
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let number = error[NSAppleScript.errorNumber] as? Int
                    let message: String
                    if number == -1743 {
                        message = "請允許 Herdr Notch 控制 Ghostty（系統設定 → 隱私權與安全性 → 自動化）"
                    } else if number == -1712 {
                        message = "Ghostty 回應逾時，請稍後重試"
                    } else {
                        message = "Ghostty 控制失敗：\(error[NSAppleScript.errorMessage] as? String ?? "未知錯誤")"
                    }
                    continuation.resume(throwing: Failure.message(message))
                } else if let result {
                    continuation.resume(returning: result.stringValue ?? String(result.booleanValue))
                } else {
                    continuation.resume(throwing: Failure.message("無法建立 Ghostty 控制指令"))
                }
            }
        }
    }
    /// Ghostty's `text:` action writes to one terminal by ID, bypassing the
    /// keyboard and input method; the target need not be frontmost.
    static func send(_ escapedBytes: String, terminalID: String) async throws {
        let result = try await script("return perform action " + quoted("text:" + escapedBytes) + " on terminal id " + quoted(terminalID))
        guard result == "true" else { throw Failure.message("Ghostty 沒有接受切換指令") }
    }
    static func terminalTitle(_ terminalID: String) async -> String? {
        try? await script("return name of terminal id " + quoted(terminalID))
    }
    nonisolated static var localHost: String {
        var buffer = [CChar](repeating: 0, count: 256)
        return gethostname(&buffer, buffer.count) == 0 ? String(cString: buffer) : ProcessInfo.processInfo.hostName
    }
    private static let learnedHostsKey = "learnedHosts"
    static var learnedHosts: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: learnedHostsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: learnedHostsKey) }
    }

    static func switchPane(agent: Agent, machines: [Machine], knownTitles: [String], app: NSRunningApplication,
                           focusAPI: () async throws -> Void, handoff: () -> Void,
                           diagnostic: (String) -> Void = { _ in }) async throws {
        // Resolve once: later commands cannot drift into another tab/window.
        let listing = try await script("""
            set currentID to ""
            try
                set currentID to id of focused terminal of selected tab of front window
            end try
            set listing to currentID & (ASCII character 30)
            repeat with t in terminals
                set listing to listing & (id of t) & (ASCII character 31) & (name of t) & (ASCII character 30)
            end repeat
            return listing
            """)
        let rows = listing.split(separator: "\u{001e}", omittingEmptySubsequences: false)
        let currentID = String(rows.first ?? "")
        let candidates = rows.dropFirst().compactMap { row -> TerminalCandidate? in
            let fields = row.split(separator: "\u{001f}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty else { return nil }
            return TerminalCandidate(id: String(fields[0]), title: String(fields[1]))
        }
        let terminalID = try TerminalChoice.choose(candidates: candidates, currentID: currentID,
            knownTitles: knownTitles, preferredID: preferredTerminalID)
        let host = localHost
        var hosts = learnedHosts
        func machine(_ view: ClientView) -> String? {
            view.machine(localHost: host, machines: machines, learnedHosts: hosts)
        }
        func view() async -> ClientView? {
            await terminalTitle(terminalID).flatMap { ClientView(title: $0) }
        }
        /// Herdr retitles the outer terminal shortly after the API focus.
        func confirmShown(attempts: Int) async -> Bool {
            for _ in 0..<attempts {
                if let current = await view(),
                   current.shows(agent, localHost: host, machines: machines, learnedHosts: hosts) { return true }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            return false
        }
        let viewing = await view().flatMap(machine)
        diagnostic("navigation begin viewing=\(viewing ?? "unknown") target=\(agent.machineId)")
        if viewing == nil || viewing == agent.machineId {
            try await focusAPI()
            handoff()
            _ = try await script("focus terminal id " + quoted(terminalID))
            if await confirmShown(attempts: 15) {
                diagnostic("navigation api-focus confirmed")
                preferredTerminalID = terminalID
                return
            }
        } else {
            handoff()
            _ = try await script("focus terminal id " + quoted(terminalID))
        }
        guard WorkspaceKeys.configured() else {
            throw Failure.message("目前停在其他機器。請在 ~/.config/herdr/config.toml 的 [keys] 加入 "
                + "next_workspace = \"ctrl+alt+n\" 與 previous_workspace = \"ctrl+alt+p\"，再於 Herdr 按 Ctrl+B Shift+R")
        }
        let total = machines.reduce(0) { $0 + max(1, $1.workspaces?.count ?? 1) }
        try await walk(toMachine: agent.machineId,
            preferred: WorkspaceKeys.direction(from: viewing, to: agent.machineId, machines: machines),
            maxPresses: max(6, total * 2 + 2),
            machine: { view in
                let id = machine(view)
                // A unique workspace label identifies its machine; remember
                // the host so shared labels stay distinguishable later.
                if let id, id != "local", view.host.caseInsensitiveCompare(host) != .orderedSame, hosts[view.host] != id {
                    hosts[view.host] = id; learnedHosts = hosts
                }
                return id
            },
            view: view, press: { try await send($0.bytes, terminalID: terminalID) },
            diagnostic: diagnostic)
        // The client now views the agent's server, where the API moves it.
        try await focusAPI()
        guard await confirmShown(attempts: 25) else {
            throw Failure.message("已切到 \(agent.machine)，但未確認 \(agent.pane) 已顯示")
        }
        diagnostic("navigation walk confirmed")
        preferredTerminalID = terminalID
    }

    /// Step through Herdr's sidebar until the client views `target`. Each press
    /// waits for the title to change before the next one, so remote switches
    /// that retitle late are never overtaken. A press that changes nothing
    /// means the end of the sidebar (no wrap-around) or an unbound shortcut:
    /// reverse once, and stop if that does not move either.
    static func walk(toMachine target: String, preferred: WorkspaceKeys.Step, maxPresses: Int,
                     machine: (ClientView) -> String?, view: () async -> ClientView?,
                     press: (WorkspaceKeys.Step) async throws -> Void,
                     diagnostic: (String) -> Void = { _ in },
                     pause: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }) async throws {
        func settled() async -> ClientView? {
            for _ in 0..<15 {
                if let current = await view() { return current }
                await pause(80_000_000)
            }
            return nil
        }
        guard var current = await settled() else {
            throw Failure.message("無法從 Ghostty 視窗標題判斷 Herdr 目前位置")
        }
        var step = preferred, reversed = false, moved = false, presses = 0
        while machine(current) != target {
            guard presses < maxPresses else {
                throw Failure.message("切換了 \(presses) 次仍未到達目標機器，已停止")
            }
            try await press(step)
            presses += 1
            var next: ClientView?
            for _ in 0..<30 {
                await pause(80_000_000)
                if let candidate = await view(), candidate != current { next = candidate; break }
            }
            diagnostic("navigation step \(step) -> \(next.map { $0.host + ": " + $0.workspace } ?? "unchanged")")
            if let next { current = next; moved = true; continue }
            guard !reversed else {
                throw Failure.message(moved ? "Herdr 側欄找不到目標機器（可能未連線）"
                    : "Herdr 沒有回應 ctrl+alt+n / ctrl+alt+p；請在 Herdr 按 Ctrl+B Shift+R 重新載入設定")
            }
            reversed = true
            step = step.reversed
        }
    }
}

/// Herdr's direct workspace shortcuts, which must be bound in the client's
/// local config. Without them the bytes would reach the focused pane, so the
/// notch never sends them unless the config declares these exact chords.
enum WorkspaceKeys {
    enum Step: CustomStringConvertible {
        case next, previous
        /// Legacy encoding of ctrl+alt+N / ctrl+alt+P: ESC + control byte.
        var bytes: String { self == .next ? "\\x1b\\x0e" : "\\x1b\\x10" }
        var reversed: Step { self == .next ? .previous : .next }
        var description: String { self == .next ? "next" : "previous" }
    }
    nonisolated static func configured(_ text: String) -> Bool {
        func bound(_ action: String, _ chord: String) -> Bool {
            text.split(separator: "\n").contains { line in
                let parts = line.split(separator: "=", maxSplits: 1)
                return parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces) == action &&
                    parts[1].split(separator: "#")[0].contains("\"" + chord + "\"")
            }
        }
        return bound("next_workspace", "ctrl+alt+n") && bound("previous_workspace", "ctrl+alt+p")
    }
    static func configured() -> Bool {
        let path = ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"]
            ?? NSHomeDirectory() + "/.config/herdr/config.toml"
        return (try? String(contentsOfFile: path, encoding: .utf8)).map(configured) ?? false
    }
    /// Herdr lists saved machines in profile order, then Local. A wrong guess
    /// only costs one reversal at the end of the sidebar.
    nonisolated static func direction(from current: String?, to target: String, machines: [Machine]) -> Step {
        func rank(_ id: String?) -> Int? {
            guard let id else { return nil }
            if id == "local" { return Int.max }
            return machines.filter { $0.id != "local" }.firstIndex { $0.id == id }
        }
        guard let from = rank(current), let to = rank(target) else { return .next }
        return to > from ? .next : .previous
    }
}
