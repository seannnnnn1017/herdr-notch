import Foundation

/// Pure window-title checks; no application, process, or UI control.
func runClientViewChecks() {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    let local = Machine(id: "local", label: "Local", state: "online", agentCount: 1, workspaces: ["~"])
    let lab = Machine(id: "lab", label: "lab_pc", state: "online", agentCount: 2, workspaces: ["Desktop", "mesh"])
    let sean = Machine(id: "sean", label: "sean_pc", state: "online", agentCount: 3, workspaces: ["video", "Desktop"])
    let machines = [local, lab, sean]
    let host = "my-mac.local"
    func agent(_ machine: String, _ workspace: String?) -> Agent {
        var row = Agent(id: machine + ":default:w1:p1", machineId: machine, machine: machine, pane: "w1:p1",
                        session: "default", title: "t", cwd: "/", status: "idle")
        row.workspace = workspace
        return row
    }
    func view(_ title: String) -> ClientView { ClientView(title: title)! }

    check(ClientView(title: "Herdr") == nil, "A title without host separator is not a client view")
    check(ClientView(title: "a b: c") == nil, "Hostnames contain no spaces")
    check(view("labbox: 了解: 專案").workspace == "了解: 專案", "Workspace labels may contain the separator")
    check(view(host + ": ~").machine(localHost: host, machines: machines, learnedHosts: [:]) == "local", "Local host title")
    check(view("MY-MAC.LOCAL: ~").machine(localHost: host, machines: machines, learnedHosts: [:]) == "local", "Hostnames compare case-insensitively")
    check(view("labbox: mesh").machine(localHost: host, machines: machines, learnedHosts: [:]) == "lab", "A unique remote workspace label identifies its machine")
    check(view("labbox: Desktop").machine(localHost: host, machines: machines, learnedHosts: [:]) == nil, "A label shared by two remotes is ambiguous")
    check(view("labbox: Desktop").machine(localHost: host, machines: machines, learnedHosts: ["labbox": "lab"]) == "lab", "A learned host resolves shared labels")
    check(view("labbox: Desktop").machine(localHost: host, machines: machines, learnedHosts: ["labbox": "gone"]) == nil, "A learned host for a removed machine is ignored")
    check(view(host + ": ~").shows(agent("local", "~"), localHost: host, machines: machines, learnedHosts: [:]), "Local target shown")
    check(!view(host + ": ~").shows(agent("local", nil), localHost: host, machines: machines, learnedHosts: [:]), "Unknown target workspace is never confirmed")
    check(!view("labbox: Desktop").shows(agent("sean", "Desktop"), localHost: host, machines: machines, learnedHosts: [:]), "Ambiguous view is never confirmed")
    check(!view("labbox: mesh").shows(agent("sean", "video"), localHost: host, machines: machines, learnedHosts: [:]), "Another machine's view is not confirmed")
    check(view("WINBOX: video").shows(agent("sean", "video"), localHost: host, machines: machines, learnedHosts: [:]), "Remote target shown")
    // Ghostty terminal choice recognises the default "{hostname}: {workspace}" title.
    let chosen = try? TerminalChoice.choose(candidates: [TerminalCandidate(id: "shell", title: "zsh"), TerminalCandidate(id: "herdr", title: "labbox: mesh")],
                                            currentID: "shell", knownTitles: ["mesh"], preferredID: nil)
    check(chosen == "herdr", "Herdr's workspace title selects its terminal")
    print("PASS: \(checks) client view checks")
}
