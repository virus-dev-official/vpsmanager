import SwiftUI
import AVKit
import AVFoundation
import PDFKit

// MARK: - Image

/// Classic light/dark gray transparency checkerboard (the same convention Preview,
/// Photoshop, Figma, etc. use) so images with transparent backgrounds are actually
/// readable instead of just blending into a solid fill.
private struct CheckerboardBackground: View {
    var tileSize: CGFloat = 14
    var light = Color.white
    var dark = Color(white: 0.8)

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            let cols = Int(ceil(size.width / tileSize))
            let rows = Int(ceil(size.height / tileSize))
            var darkSquares = Path()
            for row in 0..<rows {
                for col in 0..<cols where (row + col) % 2 == 1 {
                    darkSquares.addRect(CGRect(
                        x: CGFloat(col) * tileSize,
                        y: CGFloat(row) * tileSize,
                        width: tileSize,
                        height: tileSize
                    ))
                }
            }
            context.fill(darkSquares, with: .color(dark))
        }
        .drawingGroup()
    }
}

struct ImageViewerView: View {
    let server: Server
    let file: RemoteFile

    @State private var image: NSImage?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1

    var body: some View {
        ZStack {
            if image != nil {
                CheckerboardBackground()
            } else {
                Color.black.opacity(0.9)
            }
            Group {
                if loading {
                    ProgressView("Loading image…").tint(.white).foregroundStyle(.white)
                } else if let errorMessage {
                    InlineErrorBanner(message: errorMessage).padding()
                } else if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: image.size.width * zoom, height: image.size.height * zoom)
                    }
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in zoom = max(0.1, min(8, lastZoom * value)) }
                            .onEnded { _ in lastZoom = zoom }
                    )
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if image != nil {
                HStack(spacing: 10) {
                    Button {
                        withAnimation { zoom = max(0.1, zoom - 0.25); lastZoom = zoom }
                    } label: { Image(systemName: "minus.magnifyingglass") }
                    Text("\(Int(zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 44)
                    Button {
                        withAnimation { zoom = min(8, zoom + 0.25); lastZoom = zoom }
                    } label: { Image(systemName: "plus.magnifyingglass") }
                    Divider().frame(height: 14)
                    Button {
                        withAnimation { zoom = 1; lastZoom = 1 }
                    } label: { Image(systemName: "1.magnifyingglass") }
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(16)
            }
        }
        .task { await load() }
    }

    func load() async {
        loading = true
        errorMessage = nil
        do {
            let data = try await SFTPService.shared.readFileData(server, path: file.path, timeout: 120)
            if let img = NSImage(data: data) {
                image = img
            } else {
                errorMessage = "Couldn't decode this image."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - Audio

final class AudioPlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var decodedTemporaryFileURL: URL?

    /// Loads audio data for playback. `fileExtension` (lowercased, no leading dot)
    /// does two things: it routes Ogg-Opus files — which neither `AVAudioPlayer` nor
    /// `AVPlayer` can open at all, since AVFoundation has no built-in Ogg
    /// demuxer/decoder — through `OggOpusDecoder` first, and for every other format
    /// it's passed to `AVAudioPlayer` as a type hint so raw bytes with an
    /// unconventional or missing header (common with files pulled off a server
    /// rather than exported by an OS-native app) still decode correctly instead of
    /// AVAudioPlayer guessing wrong from the bytes alone.
    func load(data: Data, fileExtension: String) throws {
        cleanupTemporaryFile()

        let ext = fileExtension.lowercased()
        if ext == "opus" || ext == "ogg" || ext == "oga" {
            // Decode to PCM ourselves first (see OggOpusDecoder's doc comment for
            // why), then hand AVAudioPlayer the resulting temporary .caf file same
            // as any other supported format.
            let url = try OggOpusDecoder.decodeToTemporaryCAF(data)
            decodedTemporaryFileURL = url
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            return
        }

        let player = try AVAudioPlayer(data: data, fileTypeHint: ext.isEmpty ? nil : ext)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        duration = player.duration
    }

    private func cleanupTemporaryFile() {
        if let decodedTemporaryFileURL {
            try? FileManager.default.removeItem(at: decodedTemporaryFileURL)
        }
        decodedTemporaryFileURL = nil
    }

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            stopTimer()
        } else {
            player.play()
            startTimer()
        }
        isPlaying = player.isPlaying
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    deinit {
        timer?.invalidate()
        cleanupTemporaryFile()
    }
}

struct AudioPlayerView: View {
    let server: Server
    let file: RemoteFile

    @StateObject private var model = AudioPlayerModel()
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 22) {
            if loading {
                ProgressView("Loading audio…")
            } else if let errorMessage {
                InlineErrorBanner(message: errorMessage)
            } else {
                IconTile(systemImage: "waveform", size: 64, tone: Theme.accent)
                Text(file.name).font(.headline).lineLimit(1)

                Slider(
                    value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }),
                    in: 0...(max(model.duration, 0.1))
                )
                .frame(maxWidth: 420)

                HStack {
                    Text(formatTime(model.currentTime)).font(.caption.monospacedDigit())
                    Spacer()
                    Text(formatTime(model.duration)).font(.caption.monospacedDigit())
                }
                .frame(maxWidth: 420)
                .foregroundStyle(.secondary)

                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
    }

    func load() async {
        loading = true
        errorMessage = nil
        do {
            let data = try await SFTPService.shared.readFileData(server, path: file.path, timeout: 180)
            let ext = (file.name as NSString).pathExtension
            try model.load(data: data, fileExtension: ext)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Video

struct VideoPlayerView: View {
    let server: Server
    let file: RemoteFile

    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading video…")
            } else if let errorMessage {
                InlineErrorBanner(message: errorMessage).padding()
            } else if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .task { await load() }
    }

    func load() async {
        loading = true
        errorMessage = nil
        do {
            let data = try await SFTPService.shared.readFileData(server, path: file.path, timeout: 300)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + file.name)
            try data.write(to: tmp)
            player = AVPlayer(url: tmp)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - PDF

private struct PDFKitRepresentedView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document == nil {
            nsView.document = PDFDocument(data: data)
        }
    }
}

struct PDFPreviewView: View {
    let server: Server
    let file: RemoteFile

    @State private var data: Data?
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading PDF…")
            } else if let errorMessage {
                InlineErrorBanner(message: errorMessage).padding()
            } else if let data {
                PDFKitRepresentedView(data: data)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
    }

    func load() async {
        loading = true
        errorMessage = nil
        do {
            data = try await SFTPService.shared.readFileData(server, path: file.path, timeout: 180)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - Unsupported fallback

struct UnsupportedFileView: View {
    let file: RemoteFile
    var onDownload: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            IconTile(systemImage: "questionmark.doc", size: 56, tone: .secondary)
            Text("Can't preview \(file.name)").font(.headline)
            Text("This file type isn't supported for inline preview, but you can still download a copy.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Download…", action: onDownload)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}