import Foundation

/// What the Herdr client in Ghostty currently shows, read from the outer
/// window title. Herdr renders `ui.window_title` (default
/// "{hostname}: {workspace}") on the server the client is viewing, so the
/// title follows machine and workspace switches without Accessibility.
struct ClientView: Equatable {
    let host, workspace: String

    init?(title: String) {
        guard let separator = title.range(of: ": ") else { return nil }
        host = String(title[..<separator.lowerBound])
        workspace = String(title[separator.upperBound...])
        guard !host.isEmpty, !host.contains(" ") else { return nil }
    }

    /// The machine ID this view belongs to, or nil when it cannot be told
    /// apart from another machine.
    func machine(localHost: String, machines: [Machine], learnedHosts: [String: String]) -> String? {
        if host.caseInsensitiveCompare(localHost) == .orderedSame { return "local" }
        if let id = learnedHosts[host], machines.contains(where: { $0.id == id }) { return id }
        let remote = machines.filter { $0.id != "local" && ($0.workspaces ?? []).contains(workspace) }
        return remote.count == 1 ? remote[0].id : nil
    }

    func shows(_ agent: Agent, localHost: String, machines: [Machine], learnedHosts: [String: String]) -> Bool {
        guard let label = agent.workspace, workspace == label else { return false }
        return machine(localHost: localHost, machines: machines, learnedHosts: learnedHosts) == agent.machineId
    }
}
