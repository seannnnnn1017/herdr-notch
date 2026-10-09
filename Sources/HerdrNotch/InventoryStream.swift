import Foundation

struct InventoryTarget: Codable { let machineId, session: String; var key: String { machineId + ":" + session } }
struct InventoryEvent: Codable {
    let type: String
    let machineId, session, state, error: String?
    let agents: [Agent]?
    let machines: [Machine]?
    let targets: [InventoryTarget]?
    let errors: [String]?
    let workspaces: [String]?
    let updated: Double
}

/// Each event only replaces its own endpoint. A slow/offline PC cannot hold
/// already-completed peers' rows and status behind an all-machine barrier.
struct FleetInventory {
    var agents: [Agent] = []
    var machines: [Machine] = []
    var errors: [String] = []
    var updated: Date?
    private var discoveryErrors: [String] = []
    private var targetErrors: [String: String] = [:]
    mutating func apply(_ event: InventoryEvent) {
        switch event.type {
        case "targets":
            let keys = Set((event.targets ?? []).map(\.key))
            agents.removeAll { !keys.contains($0.machineId + ":" + $0.session) }
            targetErrors = targetErrors.filter { keys.contains($0.key) }
            discoveryErrors = event.errors ?? []
            let previous = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0) })
            machines = (event.machines ?? []).map { machine in
                if machine.state == "checking", let old = previous[machine.id] {
                    return Machine(id: machine.id, label: machine.label, state: old.state, agentCount: agents.filter { $0.machineId == machine.id }.count, workspaces: old.workspaces)
                }
                return machine
            }
        case "target":
            guard let id = event.machineId, let session = event.session else { return }
            agents.removeAll { $0.machineId == id && $0.session == session }
            agents += event.agents ?? []
            let key = id + ":" + session
            targetErrors[key] = event.error
            if let index = machines.firstIndex(where: { $0.id == id }) {
                let old = machines[index]
                let failed = targetErrors.keys.contains { $0.hasPrefix(id + ":") }
                machines[index] = Machine(id: id, label: old.label, state: failed ? "offline" : (event.state ?? "online"), agentCount: agents.filter { $0.machineId == id }.count, workspaces: event.workspaces ?? old.workspaces)
            }
        case "done":
            agents = event.agents ?? agents
            machines = event.machines ?? machines
            errors = event.errors ?? []
            updated = Date(timeIntervalSince1970: event.updated)
            return
        default: return
        }
        errors = discoveryErrors + targetErrors.sorted { $0.key < $1.key }.map(\.value)
        updated = Date(timeIntervalSince1970: event.updated)
    }
}

func streamInventory(onEvent: @MainActor @escaping (InventoryEvent) -> Void) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            let script = Bundle.main.resourceURL?.appendingPathComponent("monitor.py").path ?? "Resources/monitor.py"
            process.arguments = ["python3", script, "stream"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/Library/Frameworks/Python.framework/Versions/3.13/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + NSHomeDirectory() + "/.local/bin"
            process.environment = env
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            var completed = false
            do {
                try process.run()
                var pending = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = pending.prefix(upTo: newline)
                        pending.removeSubrange(...newline)
                        guard let event = try? JSONDecoder().decode(InventoryEvent.self, from: line) else { continue }
                        if event.type == "done" { completed = true }
                        DispatchQueue.main.async { onEvent(event) }
                    }
                }
                process.waitUntilExit()
                let succeeded = process.terminationStatus == 0 && completed
                // The main queue is FIFO: every event applies before refresh
                // completes and allows the next background polling pass.
                DispatchQueue.main.async { continuation.resume(returning: succeeded) }
            } catch {
                DispatchQueue.main.async { continuation.resume(returning: false) }
            }
        }
    }
}
