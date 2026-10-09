#!/usr/bin/env python3
"""Run actual navigation lifecycle bodies with pure stubs; never operate UI."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/HerdrNotch/main.swift").read_text()
model = source[source.index("@MainActor final class Model:"):source.index("\nstruct ResponsiveButtonStyle")]
lifecycle = source[source.index("    func beginNavigation()"):source.index("    func targetFrame()")]
for old, new in {
    "AXIsProcessTrusted": "fakeAXIsProcessTrusted",
    "NSRunningApplication": "FakeRunningApplication",
    "NSSound": "FakeSound",
    "GhosttyNavigation": "FakeGhosttyNavigation",
}.items():
    model = re.sub(r"\b" + old + r"\b", new, model)
assert not re.search(r"\b(?:AXIsProcessTrusted|NSRunningApplication|NSSound|GhosttyNavigation)\b", model)
assert not re.search(r"\b(?:NSApp|NSApplication|NSWorkspace|AXUIElement|NSAppleScript)\b", model + lifecycle)
models = (root / "Sources/HerdrNotch/Models.swift").read_text().replace("import SwiftUI", "")
models += (root / "Sources/HerdrNotch/RecentActivity.swift").read_text().replace("import Foundation", "")
inventory = (root / "Sources/HerdrNotch/InventoryStream.swift").read_text().split("\nfunc streamInventory(", 1)[0]

stubs = r'''
import Foundation
import Combine
func appendNotchLog(_ message: String) {}
enum Color {
    case orange, mint, cyan, gray
    init(red: Double, green: Double, blue: Double) { self = .orange }
    init(white: Double) { self = .gray }
    func opacity(_ value: Double) -> Color { self }
}
struct Animation {
    static func easeOut(duration: Double) -> Self { Self() }
    static func easeInOut(duration: Double) -> Self { Self() }
}
func withAnimation(_ animation: Animation, _ body: () -> Void) { body() }
@MainActor enum Dependencies {
    static var trusted = true
    static var appAvailable = true
    static var inventoryCalls = 0
    static var focusCalls: [[String]] = []
    static var apiError: String?
}
@MainActor func fakeAXIsProcessTrusted() -> Bool { Dependencies.trusted }
@MainActor final class FakeRunningApplication {
    static func runningApplications(withBundleIdentifier id: String) -> [FakeRunningApplication] {
        assert(id == "com.mitchellh.ghostty")
        return Dependencies.appAvailable ? [FakeRunningApplication()] : []
    }
}
struct FakeSound {
    init?(named: String) { fatalError("focus must not play a native sound") }
    func play() { fatalError("focus must not play a native sound") }
}
@MainActor func bridge(_ args: [String]) async -> Data? {
    guard args.first == "focus" else {
        Dependencies.inventoryCalls += 1
        fatalError("focus must not query inventory/quota")
    }
    Dependencies.focusCalls.append(Array(args.dropFirst()))
    let body: [String: Any] = Dependencies.apiError.map { ["error": $0] } ?? ["agent": ["pane_id": args[3]]]
    return try? JSONSerialization.data(withJSONObject: body)
}
@MainActor func streamInventory(onEvent: @MainActor @escaping (InventoryEvent) -> Void) async -> Bool {
    Dependencies.inventoryCalls += 1
    fatalError("focus must not query inventory")
}
@MainActor enum FakeGhosttyNavigation {
    static var pending: CheckedContinuation<Void, Error>?
    static var calls = 0
    static var target: [String] = []
    static var titles: [String] = []
    static func switchPane(agent: Agent, machines: [Machine], knownTitles: [String], app: FakeRunningApplication,
                           focusAPI: () async throws -> Void, handoff: () -> Void, diagnostic: (String) -> Void = { _ in }) async throws {
        assert(knownTitles.contains(agent.title), "inventory must include the clicked title")
        calls += 1
        target = [agent.pane, agent.cwd, agent.title, agent.machine]
        titles = knownTitles
        // A failed API focus must stop before the notch hands off to Ghostty.
        try await focusAPI()
        assert(Dependencies.focusCalls.last == [agent.machineId, agent.session, agent.pane])
        handoff(); handoff() // Repeated handoff signals begin navigation once.
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    static func complete(_ error: Error? = nil) {
        let continuation = pending!; pending = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
    static func reset() { assert(pending == nil); calls = 0; target = []; titles = [] }
}
@MainActor final class FakePanel {
    var isKeyWindow = false
    var isVisible = true
    var ignoresMouseEvents = false
    var alphaValue: Double = 1
    var events: [String] = []
    func resignKey() { isKeyWindow = false; events.append("resignKey") }
    func orderOut(_ sender: Any?) { isVisible = false; events.append("orderOut") }
    func orderFrontRegardless() { isVisible = true; events.append("orderFrontRegardless") }
}
'''

delegate = r'''
@MainActor final class LifecycleDelegate {
    let model: Model
    let panel = FakePanel()
    var hoverExitAt: Date?
    var wantsVisible = true
    var visibilityGeneration = 0
    var navigationSuspended = false
    var needsPointerExit = false
    var expandedBeforeNavigation = false
    var starts = 0
    var endings: [Bool] = []
    init(_ model: Model) {
        self.model = model
        model.onNavigationBegin = { [weak self] in
            guard let self else { return }
            self.starts += 1; self.beginNavigation()
        }
        model.onNavigationEnd = { [weak self] succeeded in
            guard let self else { return }
            self.endings.append(succeeded); self.endNavigation(succeeded: succeeded)
        }
    }
'''

checks = r'''
enum SimulatedFailure: LocalizedError {
    case navigation
    var errorDescription: String? { "simulated navigation failure" }
}
@main struct LifecycleChecks {
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        fatalError("lifecycle did not progress")
    }
    @MainActor static func main() async {
        let agent = Agent(id: "sean:normal:w2:p1", machineId: "sean", machine: "sean_pc", pane: "w2:p1", session: "normal", title: "更新 中文 Codex", cwd: "C:\\Users\\user", status: "working")
        var count = 0
        for precondition in ["app", "api"] {
            Dependencies.appAvailable = precondition != "app"
            Dependencies.apiError = precondition == "api" ? "agent target w2:p1 not found" : nil
            FakeGhosttyNavigation.reset()
            let model = Model(); model.expanded = true
            let delegate = LifecycleDelegate(model)
            model.focus(agent)
            await waitUntil { model.focusingID == nil }
            assert(model.feedbackFailed && model.feedback != nil)
            if precondition == "api" { assert(model.feedback?.contains("not found") == true) }
            assert(model.expanded && delegate.panel.isVisible)
            assert(delegate.starts == 0 && delegate.endings.isEmpty && delegate.panel.events.isEmpty)
            assert(FakeGhosttyNavigation.calls == (precondition == "api" ? 1 : 0))
            count += 1
        }
        Dependencies.appAvailable = true; Dependencies.apiError = nil
        for outcome in ["success", "failure", "cancel", "hidden-success", "hidden-failure", "initially-collapsed-failure"] {
            FakeGhosttyNavigation.reset()
            let model = Model(); model.expanded = outcome != "initially-collapsed-failure"
            // The clicked row may disappear in a background update before
            // handoff. Its title must still be available for terminal choice.
            model.agents = outcome == "success" ? [] : [agent]
            let previousExpanded = model.expanded
            // An unrelated offline machine must not affect the clicked row.
            model.machines = [Machine(id: "lab", label: "lab_pc", state: "offline", agentCount: 0)]
            let delegate = LifecycleDelegate(model)
            model.focus(agent)
            assert(model.focusingID == agent.id)
            await waitUntil { FakeGhosttyNavigation.pending != nil }
            assert(delegate.starts == 1 && delegate.endings.isEmpty)
            assert(delegate.navigationSuspended && !delegate.panel.isVisible && !model.expanded)
            assert(FakeGhosttyNavigation.target == [agent.pane, agent.cwd, agent.title, agent.machine])
            assert(Set(FakeGhosttyNavigation.titles) == Set([agent.title] + model.agents.map(\.title)))
            model.focus(agent) // Busy clicks cannot create a second handoff.
            assert(FakeGhosttyNavigation.calls == 1 && delegate.starts == 1)
            if outcome.hasPrefix("hidden-") { delegate.wantsVisible = false }
            let succeeded = outcome == "success" || outcome == "hidden-success"
            if succeeded { FakeGhosttyNavigation.complete() }
            else if outcome == "cancel" { FakeGhosttyNavigation.complete(CancellationError()) }
            else { FakeGhosttyNavigation.complete(SimulatedFailure.navigation) }
            await waitUntil { model.focusingID == nil }
            assert(delegate.endings == [succeeded] && !delegate.navigationSuspended)
            assert(model.expanded == (succeeded ? false : previousExpanded))
            assert(delegate.needsPointerExit == succeeded)
            assert(!delegate.panel.isKeyWindow && delegate.panel.ignoresMouseEvents)
            assert(delegate.panel.isVisible == delegate.wantsVisible)
            assert(delegate.panel.events == (delegate.wantsVisible ? ["orderOut", "orderFrontRegardless"] : ["orderOut"]))
            if succeeded { assert(!model.feedbackFailed && model.feedback?.contains("sean_pc") == true) }
            else {
                assert(model.feedbackFailed && model.feedback != nil)
                assert(model.interactionUntil.timeIntervalSinceNow > 7)
                if outcome != "cancel" { assert(model.feedback == "simulated navigation failure") }
            }
            count += 1
        }
        assert(Dependencies.inventoryCalls == 0)
        print("PASS: \(count) actual-source lifecycle scenarios; success/failure/cancel/API failure/preconditions/busy/hidden preferences; no native UI, AX, AppleScript, Ghostty, or inventory calls")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="herdr-notch-lifecycle-") as temporary:
    generated = Path(temporary) / "LifecycleChecks.swift"
    binary = Path(temporary) / "check"
    generated.write_text(stubs + models + inventory + model + delegate + lifecycle + "\n}\n" + checks)
    subprocess.run(["swiftc", "-parse-as-library", str(generated), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
