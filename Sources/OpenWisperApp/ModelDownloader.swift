// ModelDownloader — the in-app replacement for `make model`.
//
// Downloads one ggml model file with progress and lands it atomically in the
// app's models folder. One instance is one download: the AppDelegate creates
// it when the window asks, drops it on any terminal event, and a new attempt
// gets a new instance. All events are delivered on the main thread
// (the session's delegate queue *is* the main queue), matching the
// `MainWindowActions.downloadModel` contract.
import Foundation
import MainWindowUI
import OpenWisperCore

final class ModelDownloader: NSObject, URLSessionDownloadDelegate {

    /// Anything smaller than this is an error page, not a model — the same
    /// floor scripts/download_model.sh uses.
    private static let minPlausibleBytes: Int64 = 10 * 1024 * 1024

    /// Progress is re-emitted only after this much new data (or on a fraction
    /// step), so SwiftUI is not re-rendered hundreds of times a second.
    private static let progressByteStride: Int64 = 4 * 1024 * 1024

    private let url: URL
    private let destination: URL
    private let onEvent: (ModelDownloadEvent) -> Void

    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    private var lastFractionReported: Double = -1
    private var lastBytesReported: Int64 = 0
    /// Exactly one terminal event (`finished` / `cancelled` / `failed`) may be
    /// emitted: a move failure in `didFinishDownloadingTo` must not be followed
    /// by a second verdict from `didCompleteWithError`.
    private var isSettled = false

    init(url: URL, destination: URL, onEvent: @escaping (ModelDownloadEvent) -> Void) {
        self.url = url
        self.destination = destination
        self.onEvent = onEvent
        super.init()
    }

    func start() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        // Generous ceiling for the whole file on a slow connection.
        configuration.timeoutIntervalForResource = 4 * 60 * 60
        // Delegate callbacks on the main queue: events go straight to SwiftUI.
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session

        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()   // surfaces as URLError.cancelled in didCompleteWithError
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction: Double? = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : nil

        let fractionStepped = fraction.map { $0 - lastFractionReported >= 0.005 } ?? false
        let bytesStepped = totalBytesWritten - lastBytesReported >= Self.progressByteStride
        guard fractionStepped || bytesStepped || lastFractionReported < 0 else { return }

        lastFractionReported = fraction ?? lastFractionReported
        lastBytesReported = totalBytesWritten
        emit(.progress(fraction: fraction, receivedBytes: totalBytesWritten))
    }

    /// The temp file only exists for the duration of this call, so validation
    /// and the move into place happen here, synchronously.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            settle(.failed(message: "The server replied with an error (\(http.statusCode)). Please try again later."))
            return
        }

        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        guard size >= Self.minPlausibleBytes else {
            settle(.failed(message: "The downloaded file was incomplete. Please try again."))
            return
        }

        do {
            let fm = FileManager.default
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
        } catch {
            settle(.failed(message: "Could not save the model: \(error.localizedDescription)"))
            return
        }

        Log.app.info(
            "Model downloaded (\(size, privacy: .public) bytes) to \(self.destination.path, privacy: .public)"
        )
        settle(.finished)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            // The success path already settled in didFinishDownloadingTo.
            return
        }
        if (error as? URLError)?.code == .cancelled {
            settle(.cancelled)
        } else {
            settle(.failed(message: "\(error.localizedDescription) Check your internet connection and try again."))
        }
    }

    // MARK: Plumbing

    private func emit(_ event: ModelDownloadEvent) {
        guard !isSettled else { return }
        onEvent(event)
    }

    private func settle(_ event: ModelDownloadEvent) {
        guard !isSettled else { return }
        onEvent(event)
        isSettled = true
        // The session retains its delegate (us); break the cycle once done.
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
    }
}
