import Foundation

struct TerminalCandidate {
    let id, title: String
}

enum TerminalChoice {
    enum Failure: LocalizedError, Equatable {
        case missing, ambiguous
        var errorDescription: String? {
            switch self {
            case .missing:
                return "無法辨識已開啟的 Herdr terminal，請先選中原有 Herdr 分頁"
            case .ambiguous:
                return "有多個 Herdr terminal，請先在 Ghostty 選中要使用的 Herdr 分頁"
            }
        }
    }

    static func choose(candidates: [TerminalCandidate], currentID: String,
                       knownTitles: [String], preferredID: String?) throws -> String {
        func trimmed(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let known = Set(knownTitles.map(trimmed).filter { !$0.isEmpty })
        let eligible = Set(candidates.compactMap { candidate -> String? in
            guard !candidate.id.isEmpty else { return nil }
            let title = trimmed(candidate.title)
            let generic = title.lowercased()
            let isHerdr = generic == "herdr" || generic.hasPrefix("herdr ") ||
                generic.hasPrefix("herdr —") || generic.hasPrefix("herdr -")
            // Herdr's default outer title is "{hostname}: {workspace}".
            let workspaceTitle = ClientView(title: title).map { known.contains($0.workspace) } ?? false
            return known.contains(title) || workspaceTitle || isHerdr ? candidate.id : nil
        })
        if eligible.contains(currentID) { return currentID }
        if let preferredID, eligible.contains(preferredID) { return preferredID }
        if eligible.isEmpty {
            // Default Herdr titles are hostname:workspace, also used by shells.
            // Select only the current surface; the caller must verify Herdr's
            // PREFIX/navigation acknowledgement before sending further input.
            guard !currentID.isEmpty, candidates.contains(where: { $0.id == currentID }) else {
                throw Failure.missing
            }
            return currentID
        }
        guard eligible.count == 1, let id = eligible.first else { throw Failure.ambiguous }
        return id
    }
}
