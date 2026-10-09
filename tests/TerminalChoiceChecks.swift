import Foundation

/// Pure terminal selection checks; no application, process, or UI control.
func runTerminalChoiceChecks() {
    var checks = 0
    func candidate(_ id: String, _ title: String) -> TerminalCandidate {
        TerminalCandidate(id: id, title: title)
    }
    func selected(_ expected: String, _ candidates: [TerminalCandidate],
                  current: String = "shell", known: [String] = [], preferred: String? = nil) {
        do {
            let id = try TerminalChoice.choose(candidates: candidates, currentID: current,
                knownTitles: known, preferredID: preferred)
            precondition(id == expected, "Expected \(expected), selected \(id)")
            precondition(candidates.contains { $0.id == id }, "Selected a nonexistent terminal")
        } catch { preconditionFailure("Unexpected selection failure: \(error)") }
        checks += 1
    }
    func rejected(_ expected: TerminalChoice.Failure, _ candidates: [TerminalCandidate],
                  current: String = "shell", known: [String] = [], preferred: String? = nil) {
        do {
            _ = try TerminalChoice.choose(candidates: candidates, currentID: current,
                knownTitles: known, preferredID: preferred)
            preconditionFailure("Expected \(expected) selection failure")
        } catch {
            precondition(error as? TerminalChoice.Failure == expected, "Unexpected failure: \(error)")
            precondition(!error.localizedDescription.isEmpty, "Missing localized explanation")
        }
        checks += 1
    }

    let shell = candidate("shell", "Shell")
    let one = candidate("one", "Herdr")
    let two = candidate("two", "Herdr — sean_pc")
    selected("one", [shell, one])
    selected("one", [shell, one, two], current: "one")
    selected("one", [one, two], current: "one", preferred: "two")
    selected("two", [shell, one, two], preferred: "two")
    selected("one", [shell, one], preferred: "removed")
    selected("one", [shell, one], preferred: "shell")
    selected("one", [one, one])
    rejected(.ambiguous, [shell, one, two])
    rejected(.ambiguous, [shell, one, two], preferred: "removed")
    rejected(.ambiguous, [shell, one, two], preferred: "shell")
    selected("shell", [shell])
    rejected(.missing, [], current: "one", preferred: "one")
    selected("shell", [shell], preferred: "removed")
    // An existing cached terminal that has changed to Shell is ineligible.
    selected("shell", [shell, candidate("cached", "Shell")], preferred: "cached")
    selected("one", [one, candidate("cached", "Shell")], preferred: "cached")
    for title in ["herdr", " HERDR\n", "HeRdR default", "herdr — sean_pc", "HERDR - lab_pc"] {
        selected("generic", [shell, candidate("generic", title)])
    }
    let title = "優化影片語音生成 | video"
    selected("agent", [shell, candidate("agent", title)], known: [title])
    selected("agent", [shell, candidate("agent", " \(title)\n")], known: ["\t\(title) "])
    selected("agent", [candidate("agent", title), one], current: "agent", known: [title])
    selected("agent", [shell, candidate("agent", title), one], known: [title], preferred: "agent")
    rejected(.missing, [candidate("other", "prefix \(title)")], known: [title])
    rejected(.missing, [candidate("other", "TASK")], known: ["task"])
    rejected(.missing, [candidate("blank", "")], known: ["", "  "])
    for title in ["other herdr", "herdrx", "my-herdr", "herdr—default", "herdr-default"] {
        rejected(.missing, [candidate("false-positive", title)])
    }
    rejected(.missing, [candidate("", "Herdr")])
    // Herdr v0.9.3 src/config/window_title.rs defaults to
    // "{hostname}: {workspace}". Choosing this current surface is not proof
    // it runs Herdr; GhosttyNavigation's screen ACK still gates all input.
    let defaultTitle = candidate("default", "my-mac.local: ~")
    selected("default", [shell, defaultTitle], current: "default", known: [title])
    selected("shell", [shell, defaultTitle], known: [title], preferred: "default")
    let unknown = candidate("unknown", "unrecognized title")
    selected("unknown", [shell, unknown], current: "unknown", preferred: "shell")
    rejected(.missing, [shell, unknown], current: "removed", preferred: "unknown")
    rejected(.missing, [shell, unknown], current: "")
    rejected(.ambiguous, [unknown, one, two], current: "unknown")
    selected("one", [unknown, one], current: "unknown")
    print("\(checks) terminal selection checks passed; no UI actions executed")
}
