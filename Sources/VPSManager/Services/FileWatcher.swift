import Foundation
import CoreServices

/// Recursively watches a local folder for changes using FSEvents (the same mechanism
/// Finder and Xcode use), so auto-sync can react to edits anywhere inside a project,
/// including subfolders — a plain DispatchSource file watcher only covers the top
/// level directory itself.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: () -> Void

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let pathsToWatch = [path] as CFArray

        let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            watcher.onChange()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.5, // latency: coalesce rapid-fire edits (e.g. a build writing many files) into one event
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}