// Compile with the Gantry sources except GantryApp.swift. No printers, defaults writes or sockets.
import AppKit

@main @MainActor struct PrinterDragCheck {
    static func main() {
        _ = NSApplication.shared
        var starts = 0
        let handle = PrinterDragHandle { _ in starts += 1 }
        precondition(!handle.mouseDownCanMoveWindow, "The grip must never move its host window")
        precondition(handle.acceptsFirstMouse(for: nil), "Dragging must also work in an inactive window")
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        handle.mouseDown(with: event(.leftMouseDown))
        handle.mouseUp(with: event(.leftMouseUp))
        precondition(starts == 0, "A click alone must not reorder printers")
        handle.mouseDown(with: event(.leftMouseDown))
        handle.mouseDragged(with: event(.leftMouseDragged))
        handle.mouseDragged(with: event(.leftMouseDragged))
        precondition(starts == 1, "Only one drag session per gesture")
        handle.reset()
        handle.mouseDown(with: event(.leftMouseDown))
        handle.mouseDragged(with: event(.leftMouseDragged))
        precondition(starts == 2, "The grip must rearm after a drag")
        print("PASS printer grip owns drag events, accepts first mouse, starts once and rearms")
    }
}
