import SwiftUI

struct Agent: Codable, Identifiable {
    let id, machineId, machine, pane, session, title, cwd, status: String
    /// Herdr workspace label; the client's window title shows it.
    var workspace: String?
    /// Herdr agent kind: "codex" or "claude".
    var agent: String?
    /// Herdr's per-server state_change_seq, and whether the pane is that server's focused pane.
    var activity: Int?
    var focused: Bool?
    var kindLabel: String { agent == "claude" ? "Claude" : "Codex" }
    var color: Color { status == "blocked" ? .orange : status == "working" ? .mint : status == "done" ? .cyan : .gray }
    var label: String { ["blocked":"需要你回覆", "working":"工作中", "idle":"待命", "done":"已完成", "unknown":"狀態未知"][status] ?? status }
}
struct Machine: Codable, Identifiable { let id, label, state: String; let agentCount: Int; var workspaces: [String]? }
struct Inventory: Codable { let agents: [Agent]; let machines: [Machine]; let errors: [String]; let navigation: [String: Int]?; let updated: Double }
struct Window: Codable, Identifiable { let id, label: String; let remaining: Double; let resetsAt: Double?; let plan: String? }
struct QuotaProvider: Codable, Identifiable { let id, label: String; let windows: [Window]; let updated: Double; let error: String? }
struct Quota: Codable { let providers: [QuotaProvider]; let updated: Double }

extension Agent {
    static let claudeColor = Color(red: 0.85, green: 0.47, blue: 0.34)
    var kindColor: Color { agent == "claude" ? Self.claudeColor : Color(white: 0.85) }
}
