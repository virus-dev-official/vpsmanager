import SwiftUI
import AppKit

/// What kind of preview/edit surface a remote file should open in, decided from its
/// extension (and, as a safety net, its size).
enum FileKind: Equatable {
    case code(CodeLanguage)
    case plainText
    case image
    case audio
    case video
    case pdf
    case unsupported

    var isEditable: Bool {
        switch self {
        case .code, .plainText: return true
        default: return false
        }
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico", "avif", "jfif"]
    // "opus"/"oga" are Ogg-Opus; "ogg" is ambiguous between Ogg Opus and Ogg Vorbis,
    // but both are routed to the audio player and disambiguated (with a clear error
    // for Vorbis, which genuinely can't be decoded) inside
    // OggOpusDecoder/AudioPlayerModel. Previously none of these three extensions
    // were recognized at all, so opening an .opus file silently fell through to the
    // plain-text editor instead of the audio player.
    private static let audioExtensions: Set<String> = ["mp3", "wav", "aac", "flac", "m4a", "aiff", "aif", "caf", "opus", "ogg", "oga"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
    // Formats macOS genuinely has no decoder for at all (WMA/WMV — proprietary
    // Microsoft codecs Apple has never shipped support for; legacy MPEG-1/2 and
    // Flash Video — no built-in demuxer either) are routed to the clean "can't
    // preview, download instead" screen rather than the audio/video player, so they
    // fail honestly instead of hitting a cryptic AVFoundation error or, worse,
    // being force-opened as text.
    private static let opaqueBinaryExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "rar", "7z", "exe", "dmg", "so", "dylib", "bin", "o", "a", "class", "jar", "iso", "pkg", "deb", "rpm", "woff", "woff2", "ttf", "otf", "sqlite", "db", "wma", "wmv", "flv", "mpg", "mpeg", "m2v", "ogv", "asf"]

    /// Files larger than this that aren't a recognized text/media type are treated as
    /// opaque binary rather than risking a huge base64 round-trip just to show garbage.
    private static let maxUnknownPreviewBytes: Int64 = 8_000_000

    static func detect(name: String, sizeBytes: Int64) -> FileKind {
        let ns = name as NSString
        let ext = ns.pathExtension.lowercased()

        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if ext == "svg" { return .code(.markup) } // SVG is text — nicer to view as markup than as a raster image
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if opaqueBinaryExtensions.contains(ext) { return .unsupported }

        if let language = CodeLanguage.forExtension(ext, filename: ns.lastPathComponent) {
            return language.isPlainMode ? .plainText : .code(language)
        }

        if sizeBytes > maxUnknownPreviewBytes {
            return .unsupported
        }
        return .plainText
    }
}

struct FileEditorView: View {
    let server: Server
    let file: RemoteFile
    @Environment(\.dismiss) private var dismiss

    @State private var contents: String = ""
    @State private var original: String = ""
    @State private var loading = true
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var kind: FileKind = .plainText
    @State private var isDownloading = false

    var hasChanges: Bool { contents != original }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 920, height: 640)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            Spacer(); ProgressView(); Spacer()
        } else if let errorMessage, kind.isEditable {
            Spacer(); InlineErrorBanner(message: errorMessage).padding(); Spacer()
        } else {
            switch kind {
            case .code(let language):
                CodeEditorView(text: $contents, language: language)
            case .plainText:
                CodeEditorView(text: $contents, language: .plain)
            case .image:
                ImageViewerView(server: server, file: file)
            case .audio:
                AudioPlayerView(server: server, file: file)
            case .video:
                VideoPlayerView(server: server, file: file)
            case .pdf:
                PDFPreviewView(server: server, file: file)
            case .unsupported:
                UnsupportedFileView(file: file) { Task { await downloadWithPanel() } }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.headline)
                Text(file.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if hasChanges && kind.isEditable {
                Text("Unsaved changes").font(.caption.bold()).foregroundStyle(.orange)
            }

            Button {
                Task { await downloadWithPanel() }
            } label: {
                if isDownloading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .help("Download a copy")
            .disabled(isDownloading)

            Button("Close") { dismiss() }

            if kind.isEditable {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges || saving)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(16)
    }

    private func load() async {
        loading = true
        errorMessage = nil
        kind = FileKind.detect(name: file.name, sizeBytes: file.sizeBytes)

        if kind.isEditable {
            do {
                let text = try await SFTPService.shared.readFile(server, path: file.path)
                contents = text
                original = text
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        loading = false
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await SFTPService.shared.writeFile(server, path: file.path, contents: contents)
            original = contents
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func downloadWithPanel() async {
        isDownloading = true
        defer { isDownloading = false }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        panel.title = "Save \"\(file.name)\""
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try await SFTPService.shared.downloadFile(server, remotePath: file.path, to: url, timeout: 3600)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}