import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

extension TyperApp {
    // Insert accepted text by synthesizing a single Unicode keystroke event — no
    // pasteboard involved, so the user's clipboard is never touched (no loss, no
    // leak, no races). We arm a suppression window so our own injected keystroke
    // isn't re-processed as user typing.
    func insert(_ text: String) {
        let units = Array(text.replacingOccurrences(of: "\r", with: "").utf16)
        guard !units.isEmpty else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
        units.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buf.baseAddress)
        }
        // Tag so we recognize (and ignore) our own injected events exactly — never by
        // count/timing, which races a fast real keystroke into being swallowed.
        down.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // Accept text by briefly putting it on the clipboard and pasting. Safer version:
    //  - serialized (no overlapping inserts that leave the suggestion stuck on the clipboard)
    //  - snapshots/restores ALL item types (not just .string), so images/files survive
    //  - uses changeCount to NOT clobber anything the user copied during the paste window
    func withPasteboard(_ text: String, action: () -> Void) {
        let pb = NSPasteboard.general
        if pasteboardBusy { return }      // don't overlap; a dropped accept is fine
        pasteboardBusy = true

        // Deep-copy the existing items so we can restore non-text content too.
        let saved: [NSPasteboardItem] = pb.pasteboardItems?.compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let d = item.data(forType: type) { copy.setData(d, forType: type) } }
            return copy.types.isEmpty ? nil : copy
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)
        let afterWrite = pb.changeCount
        action()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            defer { self.pasteboardBusy = false }
            // If the user copied something during the window, leave THEIR clipboard alone.
            guard pb.changeCount == afterWrite else { return }
            pb.clearContents()
            if saved.isEmpty { pb.setString("", forType: .string) } else { pb.writeObjects(saved) }
        }
    }

    func postPaste() {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // Always tagged so neither tap re-processes our own injected navigation/deletion
    // keys — an untagged synthetic Backspace would hit the kVK_Delete handler in the
    // observer and corrupt the keystroke buffer.
    func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
