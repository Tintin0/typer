import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

let app = NSApplication.shared
let delegate = TyperApp()
app.delegate = delegate
app.run()
