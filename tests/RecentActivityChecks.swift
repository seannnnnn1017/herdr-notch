import Foundation

/// Pure "last used" bookkeeping and ordering checks; no UI or process calls.
func runRecentActivityChecks() {
    var checks = 0
    func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
    func agent(_ id: String, _ status: String = "idle", activity: Int? = 1, focused: Bool = false) -> Agent {
        var row = Agent(id: id, machineId: "m", machine: "m", pane: id, session: "default", title: id, cwd: "/", status: status)
        row.activity = activity; row.focused = focused
        return row
    }
    func order(_ recent: RecentActivity, _ agents: [Agent]) -> [String] { recent.sorted(agents).map(\.id) }

    var recent = RecentActivity()
    check(!recent.observe([agent("a"), agent("b")], now: 10), "First sight of unfocused panes records nothing")
    check(order(recent, [agent("b"), agent("a")]) == ["a", "b"], "Never-used rows keep a stable order")
    check(recent.observe([agent("a"), agent("b", activity: 2)], now: 20), "A state change counts as use")
    check(order(recent, [agent("a"), agent("b")]) == ["b", "a"], "Most recently used first")
    check(recent.observe([agent("a", focused: true), agent("b", activity: 2)], now: 30), "Switching to a pane in Herdr counts as use")
    check(order(recent, [agent("a"), agent("b")]) == ["a", "b"], "Focus moves it to the top")
    check(!recent.observe([agent("a", focused: true), agent("b", activity: 2)], now: 40), "Staying focused is not new use")
    check(recent.lastUsed["a"] == 30, "Timestamp stays at the switch")
    recent.touch("b", now: 50)
    check(order(recent, [agent("a"), agent("b")]) == ["b", "a"], "A notch click counts as use")
    check(order(recent, [agent("a"), agent("b"), agent("c", "blocked"), agent("d", "working")]) == ["c", "d", "b", "a"],
          "Status ranks before recency")

    var restored = RecentActivity(lastUsed: ["old": 5])
    check(!restored.observe([agent("old", focused: true)], now: 60), "A focused pane with a saved time keeps it after restart")
    check(restored.observe([agent("new", focused: true)], now: 60), "A focused pane never seen before is in use")
    restored.prune(keeping: ["new"], now: 5 + 8 * 86_400)
    check(restored.lastUsed.keys.sorted() == ["new"], "Agents gone for a week are forgotten")
    print("PASS: \(checks) recent activity checks; no UI actions executed")
}
