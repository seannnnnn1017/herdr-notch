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
    hosting.dropTarget = { x, fromTop, width in model.dropTarget(x: x, fromTop: fromTop, width: width) }
    hosting.dropHover = { model.dropHover = $0 }
    var keyRequests: [Bool] = []
    model.onComposeChange = { keyRequests.append($0) }
    hosting.dropPerform = { kind, urls in model.stage(target: kind, urls: urls) }
    panel.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    let board = NSPasteboard(name: NSPasteboard.Name("herdr-notch-check-drop"))
    func load(_ paths: [String]) { board.clearContents(); board.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL }) }
    load(["/tmp/My Folder", "/tmp/data.zip"])
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

    // A drop stages files for that agent instead of launching anything.
    check(hosting.performDragOperation(drag(360, fromTop: 75)), "A drop on the right is accepted")
    check(model.composing && model.draftKind == "codex" && model.draftFiles.map(\.path) == ["/tmp/My Folder", "/tmp/data.zip"],
          "Folders and any file type are staged as paths, for Codex")
    check(keyRequests == [true] && model.panelSize.height == composeHeight && !model.showsDropZone, "Composing asks for keyboard focus and shows the tray")
    check(model.launchingKind == nil && model.focusingID == nil, "Nothing is launched by a drop")

    // While composing, the whole tray takes more files; the agent choice is kept.
    load(["/tmp/data.zip", "/tmp/photo.png"])
    model.dropActive = true
    check(hover(120, 75) == ("add", true) && hover(360, 150) == ("add", true), "Either half of the tray adds files")
    check(hover(120, composeHeight + 30) == (nil, false), "Below the tray the drag passes through")
    check(hosting.performDragOperation(drag(120, fromTop: 75)), "A drop on the tray is accepted")
    check(model.draftFiles.map(\.lastPathComponent) == ["My Folder", "data.zip", "photo.png"] && model.draftKind == "codex",
          "Added files are appended once, without changing the agent")
    model.draftKind = "claude"; model.draftText = "這是什麼？"
    model.removeDraftFile(URL(fileURLWithPath: "/tmp/data.zip"))
    check(model.draftFiles.count == 2 && model.composing && model.draftText == "這是什麼？", "Removing one file keeps the draft")
    model.removeDraftFile(URL(fileURLWithPath: "/tmp/My Folder")); model.removeDraftFile(URL(fileURLWithPath: "/tmp/photo.png"))
    check(!model.composing && model.draftText.isEmpty && keyRequests == [true, false], "Removing the last file ends the draft and releases focus")
    check(model.panelSize.height == 34, "The notch returns to its compact strip")

    model.dropActive = false
    check(hover(360, 75) == (nil, false), "Without a file drag the notch is not a drop target")
    load(["/tmp/a.txt"]); model.dropActive = true
    _ = hosting.performDragOperation(drag(120, fromTop: 75))
    model.cancelDraft()
    check(!model.composing && model.draftFiles.isEmpty && keyRequests.last == false, "Cancel discards the draft")
    board.releaseGlobally()
    print("PASS: \(checks) drop and staging checks; nothing launched")
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
