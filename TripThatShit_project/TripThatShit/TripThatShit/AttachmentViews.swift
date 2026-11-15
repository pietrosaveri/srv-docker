import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct AttachmentList: View {
    let store: TripStore
    let attachments: [Attachment]
    let onOpen: (Attachment) -> Void
    var onDelete: ((Attachment) -> Void)?

    var body: some View {
        if attachments.isEmpty {
            Text("Nessun biglietto allegato")
                .font(.system(size: 14))
                .foregroundStyle(Theme.stone)
                .padding(.vertical, 4)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { Divider().overlay(Theme.hairline) }
                    let available = store.hasFile(a)
                    HStack(spacing: 12) {
                        Button { onOpen(a) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: available ? a.symbol : "icloud.and.arrow.down")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.onInverse)
                                    .frame(width: 34, height: 34)
                                    .background(Theme.inverse, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                                Text(a.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if !available {
                                    Text("In download")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.stone)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!available)
                        if let onDelete {
                            Button { onDelete(a) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Theme.mute)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        }
    }
}

/// Two buttons: pick files (PDF, any document) or photos/screenshots. Files are copied into the app.
struct AttachmentAdder: View {
    let store: TripStore
    let onAdd: ([Attachment]) -> Void

    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        HStack(spacing: 10) {
            Button { showFiles = true } label: { Label("File o PDF", systemImage: "doc.badge.plus") }
                .buttonStyle(SoftPillStyle())
            Button { showPhotos = true } label: { Label("Foto", systemImage: "photo.badge.plus") }
                .buttonStyle(SoftPillStyle())
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .image, .item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let added = urls.compactMap { try? store.importFile(at: $0) }
            if !added.isEmpty { onAdd(added) }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                var added: [Attachment] = []
                for (i, item) in items.enumerated() {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    if let a = try? store.importData(data, ext: ext, name: items.count > 1 ? "Foto \(i + 1)" : "Foto") {
                        added.append(a)
                    }
                }
                if !added.isEmpty { onAdd(added) }
            }
        }
    }
}
