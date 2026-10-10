#!/usr/bin/env python3
"""Drive the real hosting view's drag destination with synthetic drags.

Builds the app sources without their entry point, lays out the drop zone in an
off-screen panel, and feeds NSDraggingInfo stand-ins at chosen points. Nothing
is launched: the drop handler is replaced by a recorder.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / "Sources/HerdrNotch"
app = (sources / "main.swift").read_text()
app = app[:app.rindex("MainActor.assumeIsolated {")]
app = app.replace("func appendNotchLog(_ message: String) {", "func appendNotchLog(_ message: String) { return\n", 1)

harness = r'''
import AppKit
import SwiftUI

final class FakeDrag: NSObject, NSDraggingInfo {
    let point: NSPoint, board: NSPasteboard
    weak var window: NSWindow?
    init(_ point: NSPoint, _ board: NSPasteboard, _ window: NSWindow) { self.point = point; self.board = board; self.window = window }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
    var draggingLocation: NSPoint { point }
    var draggedImageLocation: NSPoint { point }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { board }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    var checks = 0
    func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
    let model = Model(); model.dropActive = true
    let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: expandedHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let hosting = NotchHostingView(rootView: Dashboard(model: model))
    hosting.sizingOptions = []
    hosting.registerForDraggedTypes([.fileURL])
    hosting.dropZoneActive = { model.dropActive && model.launchingKind == nil }
    hosting.dropHover = { model.dropHover = $0 }
    var performed: [(String, [String])] = []
    hosting.dropPerform = { kind, urls in performed.append((kind, urls.map(\.path))) }
    panel.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    let board = NSPasteboard(name: NSPasteboard.Name("herdr-notch-check-drop"))
    board.clearContents()
    board.writeObjects([URL(fileURLWithPath: "/tmp/My Folder") as NSURL, URL(fileURLWithPath: "/tmp/data.zip") as NSURL])
    // Window points have a bottom-left origin; the zone is the top dropZoneHeight.
    @MainActor func drag(_ x: CGFloat, fromTop: CGFloat) -> FakeDrag { FakeDrag(NSPoint(x: x, y: expandedHeight - fromTop), board, panel) }
    @MainActor func hover(_ x: CGFloat, _ fromTop: CGFloat) -> (String?, Bool) {
        let operation = hosting.draggingUpdated(drag(x, fromTop: fromTop))
        return (model.dropHover, operation == .copy)
    }
    check(hover(120, 75) == ("claude", true), "Left target accepts as Claude")
    check(hover(360, 75) == ("codex", true), "Right target accepts as Codex")
    check(hover(239, 75).0 == "claude" && hover(241, 75).0 == "codex", "The gap splits at the middle")
    check(hover(400, 20) == ("codex", true), "The strip row above a target counts for it")
    check(hover(360, dropZoneHeight + 40) == (nil, false), "Below the zone the drag passes through")
    hosting.draggingExited(nil)
    check(model.dropHover == nil, "Leaving clears the highlight")
    check(hosting.performDragOperation(drag(360, fromTop: 75)), "A drop on the right is accepted")
    check(performed.count == 1 && performed[0].0 == "codex" && performed[0].1 == ["/tmp/My Folder", "/tmp/data.zip"],
          "Folders and any file type arrive as paths, for Codex")
    check(hosting.performDragOperation(drag(120, fromTop: 75)) && performed.last?.0 == "claude", "A drop on the left opens Claude")
    model.launchingKind = "codex"
    check(hover(120, 75) == (nil, false) && !hosting.performDragOperation(drag(120, fromTop: 75)), "No second drop while one is opening")
    model.launchingKind = nil; model.dropActive = false
    check(hover(360, 75) == (nil, false), "Without a file drag the notch is not a drop target")
    board.releaseGlobally()
    print("PASS: \(checks) drop target checks; nothing launched")
    exit(0)
}
'''

with tempfile.TemporaryDirectory(prefix="herdr-notch-drop-") as temporary:
    directory = Path(temporary)
    (directory / "app.swift").write_text(app)
    (directory / "main.swift").write_text(harness)
    others = [str(sources / name) for name in ["Models.swift", "InventoryStream.swift", "GhosttyNavigation.swift",
                                               "TerminalChoice.swift", "ClientView.swift", "RecentActivity.swift"]]
    binary = directory / "check"
    subprocess.run(["swiftc", *others, str(directory / "app.swift"), str(directory / "main.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
