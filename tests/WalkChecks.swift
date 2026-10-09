import Foundation

/// Walk the injected sidebar model; no AppleScript, process, or UI calls.
@MainActor func runWalkChecks() async {
    var checks = 0
    func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }
    // Herdr 0.9.3 order observed live: saved machines in profile order, then Local, no wrap.
    let sidebar = [("labbox", "mesh"), ("labbox", "Desktop"), ("WINBOX", "video"), ("WINBOX", "web app"),
                   ("WINBOX", "user"), ("my-mac.local", "~")]
    let machines = [Machine(id: "local", label: "Local", state: "online", agentCount: 1, workspaces: ["~"]),
                    Machine(id: "lab", label: "lab_pc", state: "online", agentCount: 2, workspaces: ["Desktop", "mesh"]),
                    Machine(id: "sean", label: "sean_pc", state: "online", agentCount: 3, workspaces: ["video", "web app", "notes"])]
    func machine(_ view: ClientView) -> String? {
        view.machine(localHost: "my-mac.local", machines: machines, learnedHosts: [:])
    }
    final class Client {
        var index: Int, bound: Bool, lag: Int
        var presses: [WorkspaceKeys.Step] = []
        var pendingIndex: Int?, pendingReads = 0
        let sidebar: [(String, String)]
        init(_ sidebar: [(String, String)], at index: Int, bound: Bool = true, lag: Int = 0) {
            self.sidebar = sidebar; self.index = index; self.bound = bound; self.lag = lag
        }
        func title() -> String? {
            if let pending = pendingIndex {
                if pendingReads >= lag { index = pending; pendingIndex = nil }
                else { pendingReads += 1; return pendingReads == 1 ? "herdr" : sidebar[index].0 + ": " + sidebar[index].1 }
            }
            return sidebar[index].0 + ": " + sidebar[index].1
        }
        func press(_ step: WorkspaceKeys.Step) {
            precondition(pendingIndex == nil, "A press overtook an unacknowledged switch")
            presses.append(step)
            guard bound else { return }
            let target = index + (step == .next ? 1 : -1)
            if sidebar.indices.contains(target) { pendingIndex = target; pendingReads = 0 }
        }
    }
    func run(_ client: Client, to target: String, preferred: WorkspaceKeys.Step, max: Int = 14) async -> Error? {
        do {
            try await GhosttyNavigation.walk(toMachine: target, preferred: preferred, maxPresses: max, machine: machine,
                view: { client.title().flatMap { ClientView(title: $0) } }, press: { client.press($0) }, pause: { _ in })
            return nil
        } catch { return error }
    }

    var client = Client(sidebar, at: 0)
    check(await run(client, to: "sean", preferred: .next) == nil && client.presses == [.next, .next], "lab → sean takes two presses")
    check(machine(ClientView(title: client.title()!)!) == "sean", "Walk stops on the first workspace of the target machine")
    client = Client(sidebar, at: 5, lag: 6)
    check(await run(client, to: "lab", preferred: .previous) == nil && client.presses.count == 4, "Late remote titles are awaited, never overtaken")
    client = Client(sidebar, at: 3)
    check(await run(client, to: "local", preferred: .next) == nil && client.presses == [.next, .next], "Forward to Local")
    client = Client(sidebar, at: 4)
    check(await run(client, to: "lab", preferred: .next) == nil, "A wrong first guess reverses at the end of the sidebar")
    check(client.presses == [.next, .next, .previous, .previous, .previous, .previous], "End of list costs one extra press")
    client = Client(sidebar, at: 2)
    check(await run(client, to: "sean", preferred: .next) == nil && client.presses.isEmpty, "Already on target: no keys")
    client = Client(sidebar, at: 0, bound: false)
    let unbound = await run(client, to: "local", preferred: .next)
    check(unbound != nil && client.presses.count == 2, "Unbound shortcut: at most one press each way, then stop")
    check(unbound?.localizedDescription.contains("Ctrl+B Shift+R") == true, "Unbound shortcut explains reload")
    client = Client(sidebar, at: 0)
    check(await run(client, to: "offline", preferred: .next) != nil, "An unreachable machine stops with an error")
    check(client.presses.count <= 14, "Press budget is respected")
    client = Client(sidebar, at: 0)
    let untitled = await (try? GhosttyNavigation.walk(toMachine: "sean", preferred: .next, maxPresses: 6, machine: machine,
        view: { nil }, press: { client.press($0) }, pause: { _ in })) == nil
    check(untitled && client.presses.isEmpty, "Without a readable title no key is sent")

    check(WorkspaceKeys.configured("[keys]\nnext_workspace = \"ctrl+alt+n\"\nprevious_workspace = [\"prefix+p\", \"ctrl+alt+p\"]"), "Bindings, including arrays, are recognised")
    check(!WorkspaceKeys.configured("[keys]\nnext_workspace = \"ctrl+alt+n\""), "Both directions are required")
    check(!WorkspaceKeys.configured("[keys]\n# next_workspace = \"ctrl+alt+n\"\nprevious_workspace = \"ctrl+alt+p\""), "Commented bindings do not count")
    check(!WorkspaceKeys.configured("next_workspace = \"\" # \"ctrl+alt+n\"\nprevious_workspace = \"ctrl+alt+p\""), "Trailing comments do not count")
    check(WorkspaceKeys.direction(from: "lab", to: "sean", machines: machines) == .next, "Profile order")
    check(WorkspaceKeys.direction(from: "local", to: "lab", machines: machines) == .previous, "Local is last")
    check(WorkspaceKeys.direction(from: nil, to: "lab", machines: machines) == .next, "Unknown position defaults forward")
    print("PASS: \(checks) workspace walk checks; no UI actions executed")
}
