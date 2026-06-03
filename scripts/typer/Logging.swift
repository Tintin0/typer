import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

let typerLogURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Typer.log")

// When false (default), content-bearing logs (typed text, buffer/context/suggestion
// snippets) are suppressed so the log is not a plaintext keystroke transcript.
var debugLoggingEnabled = false

// A single long-lived handle written on a serial queue, so logging never re-opens the
// file or blocks the (often main-thread) caller — the old open/seek/write/close per
// call ran several times per keystroke on the hot path.
let typerLogQueue = DispatchQueue(label: "typer.log", qos: .utility)
private let typerLogHandle: FileHandle? = {
    if !FileManager.default.fileExists(atPath: typerLogURL.path) {
        FileManager.default.createFile(atPath: typerLogURL.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
    }
    let h = try? FileHandle(forWritingTo: typerLogURL)
    _ = try? h?.seekToEnd()
    return h
}()

func log(_ message: String) {
    let line = "\(Date()) \(message)\n"
    typerLogQueue.async {
        guard let h = typerLogHandle else { return }
        try? h.write(contentsOf: Data(line.utf8))
    }
}

// Content-bearing log: only written when debug logging is explicitly enabled, so the
// log never becomes a plaintext record of what the user typed.
func dlog(_ message: @autoclosure () -> String) {
    if debugLoggingEnabled { log(message()) }
}
