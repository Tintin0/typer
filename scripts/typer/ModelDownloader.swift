import Combine
import Foundation

// Background, observable download of the optional large model (typer-1l.gguf) straight from
// HuggingFace into the Models directory. The menu + onboarding observe `state` to show progress.
// One download at a time. The finished file is validated as a real GGUF (size + magic) before it
// is moved into place, so a 404 HTML body or a truncated transfer never masquerades as a model.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case idle
        case downloading(Double)        // fraction 0...1 (or <0 when total size is unknown)
        case done
        case failed(String)
    }

    // Extra free space we keep beyond the model itself: the temp download lives on the same volume
    // before the move, and we never want to wedge the user's disk to 0. ~1 GB margin.
    static let diskMarginBytes: Int64 = 1_024 * 1_048_576

    static let shared = ModelDownloader()

    @Published private(set) var state: State = .idle

    private var destination: URL?
    private var expectedBytes: Int64 = 0
    private var onDone: ((Bool) -> Void)?
    private lazy var session: URLSession = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil)

    var isDownloading: Bool { if case .downloading = state { return true }; return false }

    // Bytes free on the volume that holds `url`, using the API that accounts for purgeable space
    // the system will free on demand. nil if it can't be determined (then we don't block).
    static func availableBytes(on url: URL) -> Int64? {
        let dir = url.deletingLastPathComponent()
        // Probe an existing ancestor — the destination dir may not exist yet.
        var probe = dir
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path) && probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // True when `dest`'s volume has room for a download of `bytes` plus the safety margin.
    // Unknown capacity → returns true (don't block on a probe failure).
    static func hasRoomForDownload(of bytes: Int64, at dest: URL) -> Bool {
        guard bytes > 0, let free = availableBytes(on: dest) else { return true }
        return free >= bytes + diskMarginBytes
    }

    // Start downloading `urlString` to `dest`. No-op (completion false) if one is already running.
    // `expectedBytes` (when > 0) gates the download on free disk space up front and validates the
    // finished file's size after transfer. Pass the catalog tier's `sizeBytes`.
    func download(urlString: String, to dest: URL, expectedBytes: Int64 = 0,
                  completion: @escaping (Bool) -> Void) {
        guard !isDownloading, let url = URL(string: urlString) else { completion(false); return }
        if expectedBytes > 0, !ModelDownloader.hasRoomForDownload(of: expectedBytes, at: dest) {
            let needGB = String(format: "%.1f", Double(expectedBytes + ModelDownloader.diskMarginBytes) / 1_073_741_824.0)
            let freeGB = ModelDownloader.availableBytes(on: dest)
                .map { String(format: "%.1f", Double($0) / 1_073_741_824.0) } ?? "?"
            DispatchQueue.main.async {
                self.state = .failed("not enough disk space — need \(needGB) GB free, have \(freeGB) GB")
            }
            completion(false)
            return
        }
        destination = dest
        self.expectedBytes = expectedBytes
        onDone = completion
        DispatchQueue.main.async { self.state = .downloading(0) }
        session.downloadTask(with: url).resume()
    }

    private func finish(_ ok: Bool, _ newState: State) {
        let cb = onDone
        onDone = nil
        expectedBytes = 0
        destination = nil
        DispatchQueue.main.async { self.state = newState; cb?(ok) }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten written: Int64,
                    totalBytesExpectedToWrite total: Int64) {
        let frac = total > 0 ? Double(written) / Double(total) : -1
        DispatchQueue.main.async { self.state = .downloading(frac) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is only valid for the duration of this callback — validate + move now.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(false, .failed("HTTP \(http.statusCode)"))
            return
        }
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: location.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let magic = (try? FileHandle(forReadingFrom: location))
            .flatMap { fh -> String? in defer { try? fh.close() }; return (try? fh.read(upToCount: 4)).flatMap { String(data: $0, encoding: .ascii) } }
        guard size > 100_000_000, magic == "GGUF" else {
            finish(false, .failed("downloaded file is not a valid GGUF"))
            return
        }
        // Byte-size validation against the catalog's expected size: a transfer that completed but
        // came up materially short (truncated mirror, partial CDN response) is rejected even though
        // it has a GGUF header. Allow a generous ±5% band since quant sizes can drift between builds.
        if expectedBytes > 0 {
            let lo = Int(Double(expectedBytes) * 0.95)
            if size < lo {
                finish(false, .failed("downloaded file is incomplete (\(size / 1_048_576) MB of ~\(expectedBytes / 1_048_576) MB)"))
                return
            }
        }
        guard let dest = destination else { finish(false, .failed("no destination")); return }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            finish(true, .done)
        } catch {
            finish(false, .failed(error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is handled in didFinishDownloadingTo; only surface real errors here.
        if let error = error { finish(false, .failed(error.localizedDescription)) }
    }
}
