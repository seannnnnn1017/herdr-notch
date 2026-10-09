import Foundation

/// Data-only stream merge checks. This does not launch a process or touch UI.
func runInventoryChecks() {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    func agent(_ machine: String, _ session: String = "default", _ pane: String = "w1:p1") -> Agent {
        Agent(id: machine + ":" + session + ":" + pane, machineId: machine,
            machine: machine == "local" ? "Local" : machine + "_pc", pane: pane,
            session: session, title: "Session " + pane, cwd: "/" + machine, status: "working")
    }
    func machine(_ id: String, _ state: String = "checking", _ count: Int = 0) -> Machine {
        Machine(id: id, label: id == "local" ? "Local" : id + "_pc", state: state, agentCount: count)
    }
    func event(_ type: String, id: String? = nil, session: String? = nil,
               state: String? = nil, error: String? = nil, agents: [Agent]? = nil,
               machines: [Machine]? = nil, targets: [InventoryTarget]? = nil,
               errors: [String]? = nil, time: Double = 100) -> InventoryEvent {
        InventoryEvent(type: type, machineId: id, session: session, state: state,
            error: error, agents: agents, machines: machines, targets: targets,
            errors: errors, workspaces: nil, updated: time)
    }
    func target(_ id: String, _ session: String = "default") -> InventoryTarget {
        InventoryTarget(machineId: id, session: session)
    }

    // A healthy endpoint is usable as soon as its event arrives, while the
    // offline peer has not completed and no final "done" event has arrived.
    var fleet = FleetInventory()
    fleet.apply(event("targets", machines: [machine("local"), machine("lab"), machine("sean")],
        targets: [target("local"), target("lab"), target("sean", "normal")], errors: []))
    check(fleet.machines.allSatisfy { $0.state == "checking" }, "New endpoints should initially be checking")
    let seanRows = [agent("sean", "normal"), agent("sean", "normal", "w2:p1")]
    fleet.apply(event("target", id: "sean", session: "normal", state: "online", agents: seanRows, time: 101))
    check(Set(fleet.agents.map(\.id)) == Set(seanRows.map(\.id)), "Fast sean rows must appear before slow lab finishes")
    check(fleet.machines.first { $0.id == "sean" }?.state == "online", "Fast sean state should become online immediately")
    check(fleet.machines.first { $0.id == "sean" }?.agentCount == 2, "Fast sean count should update immediately")
    check(fleet.machines.first { $0.id == "lab" }?.state == "checking", "Lab should remain checking independently")
    check(fleet.updated == Date(timeIntervalSince1970: 101), "Partial results should have their own update time")
    let localRows = [agent("local"), agent("local", "default", "w2:p1")]
    fleet.apply(event("target", id: "local", session: "default", state: "online", agents: localRows, time: 102))
    fleet.apply(event("target", id: "lab", session: "default", state: "offline", error: "lab_pc/default: timeout", agents: [], time: 103))
    check(Set(fleet.agents.map(\.id)) == Set((localRows + seanRows).map(\.id)), "Lab timeout must retain all local and sean rows")
    check(fleet.machines.first { $0.id == "local" }?.agentCount == 2, "Lab timeout must retain local count")
    check(fleet.machines.first { $0.id == "sean" }?.agentCount == 2, "Lab timeout must retain sean count")
    check(fleet.machines.first { $0.id == "lab" }?.state == "offline", "Only lab should become offline")
    check(fleet.errors == ["lab_pc/default: timeout"], "Lab timeout should remain visible")

    // The next pass may be slow; discovery must retain healthy rows and counts
    // until a completed event replaces that endpoint's data.
    fleet.apply(event("targets", machines: [machine("local"), machine("lab"), machine("sean")],
        targets: [target("local"), target("lab"), target("sean", "normal")], errors: [], time: 104))
    check(fleet.agents.count == 4, "Starting the next pass must not erase healthy rows")
    check(fleet.machines.first { $0.id == "sean" }?.agentCount == 2, "Checking must retain the previous successful sean count")
    fleet.apply(event("target", id: "lab", session: "default", state: "online", agents: [agent("lab")], time: 105))
    check(fleet.errors.isEmpty, "Successful lab retry must clear its timeout error")
    check(fleet.machines.first { $0.id == "lab" }?.state == "online", "Successful lab retry should restore online state")
    check(fleet.agents.count == 5, "Recovery should add lab without replacing healthy peers")

    // A machine can contain multiple sessions. One successful session cannot
    // clear another session's error or its machine's aggregate offline state.
    var multiple = FleetInventory()
    multiple.apply(event("targets", machines: [machine("local")],
        targets: [target("local"), target("local", "other")], errors: []))
    multiple.apply(event("target", id: "local", session: "default", state: "offline", error: "default failed", agents: []))
    multiple.apply(event("target", id: "local", session: "other", state: "online", agents: [agent("local", "other")]))
    check(multiple.machines[0].state == "offline", "A healthy session must not hide a failed sibling session")
    check(multiple.machines[0].agentCount == 1, "Machine count should include the healthy sibling session")
    check(multiple.errors == ["default failed"], "Sibling success must retain the failing session's error")
    multiple.apply(event("target", id: "local", session: "default", state: "online", agents: [agent("local")]))
    check(multiple.machines[0].state == "online", "All recovered sessions should restore online state")
    check(multiple.machines[0].agentCount == 2, "Machine count should combine sessions")
    check(multiple.errors.isEmpty, "Recovery should clear only the recovered session's error")

    // Discovery is authoritative for active machine/session keys. Removing a
    // machine or session must prune its old rows and errors, retaining peers.
    fleet.apply(event("targets", machines: [machine("local"), machine("lab"), machine("sean")],
        targets: [target("local"), target("local", "other"), target("lab"), target("lab", "retired"), target("sean", "normal")], errors: []))
    fleet.apply(event("target", id: "local", session: "other", state: "online", agents: [agent("local", "other")]))
    fleet.apply(event("target", id: "lab", session: "retired", state: "offline", error: "retired lab failed", agents: []))
    fleet.apply(event("targets", machines: [machine("local"), machine("sean")],
        targets: [target("local"), target("sean", "normal")], errors: [], time: 106))
    check(Set(fleet.agents.map(\.id)) == Set((localRows + seanRows).map(\.id)), "Discovery must prune removed machine/session rows only")
    check(Set(fleet.machines.map(\.id)) == Set(["local", "sean"]), "Removed machine must disappear from machine chips")
    check(fleet.errors.isEmpty, "Removed target errors must also be pruned")
    check(fleet.machines.first { $0.id == "local" }?.agentCount == 2, "Pruning a session must recompute the retained machine count")

    // Discovery errors persist across individual successes and are replaced
    // only when a new discovery event reports recovery.
    fleet.apply(event("targets", machines: [machine("local"), machine("sean")],
        targets: [target("local"), target("sean", "normal")], errors: ["machine discovery failed"], time: 107))
    fleet.apply(event("target", id: "sean", session: "normal", state: "online", agents: seanRows, time: 108))
    check(fleet.errors == ["machine discovery failed"], "Endpoint success must not hide a discovery error")
    fleet.apply(event("targets", machines: [machine("local"), machine("sean")],
        targets: [target("local"), target("sean", "normal")], errors: [], time: 109))
    check(fleet.errors.isEmpty, "Fresh successful discovery should clear its previous error")
    check(fleet.agents.count == 4, "Discovery recovery should preserve retained endpoints' rows")

    print("\(checks) inventory stream merge checks passed; no process or UI actions executed")
}
