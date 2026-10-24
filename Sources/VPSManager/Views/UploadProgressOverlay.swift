import SwiftUI

struct UploadTask: Identifiable, Equatable {
    let id = UUID()
    let name: String
    var status: Status = .uploading

    enum Status: Equatable {
        case uploading
        case done
        case failed(String)
    }
}

/// Small floating card, anchored bottom-trailing over the file browser, showing the
/// live status of any drag-and-drop or picker uploads currently in flight.
struct UploadProgressOverlay: View {
    let uploads: [UploadTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.accent)
                Text("Uploading \(uploads.count) item\(uploads.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(uploads) { task in
                    HStack(spacing: 8) {
                        statusIcon(task.status)
                        Text(task.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .help(helpText(for: task))
                }
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }

    @ViewBuilder
    private func statusIcon(_ status: UploadTask.Status) -> some View {
        switch status {
        case .uploading:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func helpText(for task: UploadTask) -> String {
        if case .failed(let message) = task.status { return "\(task.name) — \(message)" }
        return task.name
    }
}