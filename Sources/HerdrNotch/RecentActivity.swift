import Foundation

/// When each agent was last used. Herdr reports no timestamps, only per-server
/// sequence numbers, so the notch records the moment it observes use: a status
/// change (the agent worked or finished), the pane becoming Herdr's focused
/// pane (you switched to it), or a click in the notch.
struct RecentActivity {
    private struct Observation: Equatable { let activity: Int?; let status: String; let focused: Bool }
    private(set) var lastUsed: [String: Double]
    private var observed: [String: Observation] = [:]

    init(lastUsed: [String: Double] = [:]) { self.lastUsed = lastUsed }

    /// Returns true when a timestamp changed.
    mutating func observe(_ agents: [Agent], now: Double) -> Bool {
        var changed = false
        for agent in agents {
            let current = Observation(activity: agent.activity, status: agent.status, focused: agent.focused ?? false)
            let previous = observed[agent.id]
            let used: Bool
            if let previous {
                used = previous.activity != current.activity || previous.status != current.status ||
                    (current.focused && !previous.focused)
            } else {
                // A pane already focused at first sight is the one in use,
                // unless an earlier run recorded it.
                used = current.focused && lastUsed[agent.id] == nil
            }
            if used { lastUsed[agent.id] = now; changed = true }
            observed[agent.id] = current
        }
        return changed
    }

    mutating func touch(_ id: String, now: Double) { lastUsed[id] = now }

    /// Forget agents not seen for a week so the saved table stays small.
    mutating func prune(keeping ids: Set<String>, now: Double) {
        lastUsed = lastUsed.filter { ids.contains($0.key) || now - $0.value < 7 * 86_400 }
    }

    static let statusRank = ["blocked": 0, "working": 1, "done": 2, "idle": 3, "unknown": 4]

    /// Status first, then most recently used; never-used rows keep a stable order.
    func sorted(_ agents: [Agent]) -> [Agent] {
        agents.sorted { a, b in
            let rank = (Self.statusRank[a.status] ?? 5, Self.statusRank[b.status] ?? 5)
            if rank.0 != rank.1 { return rank.0 < rank.1 }
            let used = (lastUsed[a.id] ?? 0, lastUsed[b.id] ?? 0)
            if used.0 != used.1 { return used.0 > used.1 }
            return a.id < b.id
        }
    }
}
