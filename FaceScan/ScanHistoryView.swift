import SwiftUI
import UIKit

/// Lists immutable original scans. Opening an entry returns it to the same
/// result workspace, where filtering never changes the stored original.
struct ScanHistoryView: View {
    @ObservedObject var history: ScanHistoryStore
    let onOpen: (ScanHistoryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var pendingDeletion: ScanHistoryEntry?
    @State private var confirmsClearAll = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                recordsSection
                Section {
                    Text("Each successful scan is automatically saved as an original point cloud. Filtering never overwrites it. Scan History stays on this device and records are not automatically removed. Deleting the app removes these records, so export any models you want to keep.")
                        .font(.footnote)
                        .foregroundStyle(ScanTheme.secondary)
                        .listRowBackground(ScanTheme.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ScanTheme.background)
            .foregroundStyle(ScanTheme.primary)
            .tint(ScanTheme.tint)
            .navigationTitle("Scan History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Delete All", role: .destructive) { confirmsClearAll = true }
                        .foregroundStyle(ScanTheme.destructive)
                        .disabled(history.entries.isEmpty || history.isSaving || history.isClearing)
                        .accessibilityIdentifier("history.clearAll")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable {
                history.refresh()
                await history.waitUntilIdle()
            }
            .onAppear { history.refresh() }
            .confirmationDialog("Permanently delete this original scan?", isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ), titleVisibility: .visible) {
                if let entry = pendingDeletion {
                    Button("Permanently Delete", role: .destructive) {
                        history.delete(entry)
                        pendingDeletion = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("This history record will be removed from this device and cannot be recovered. Exported PLY files are not affected.")
            }
            .confirmationDialog("Permanently delete all scan history?", isPresented: $confirmsClearAll,
                                titleVisibility: .visible) {
                Button("Permanently Delete All", role: .destructive) { history.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All original scans saved on this device will be removed and cannot be recovered. Exported PLY files are not affected.")
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if history.isLoading || history.isSaving || history.isClearing
            || history.hasFailedSaves || history.errorMessage != nil {
            Section {
                if history.isClearing {
                    ProgressView("Clearing history…")
                } else if history.isSaving {
                    ProgressView("Saving original scan…")
                } else if history.isLoading {
                    ProgressView("Loading history…")
                }
                if history.errorMessage != nil || history.hasFailedSaves {
                    Text(history.errorMessage ?? String(localized: "Some original scans haven't been saved. Try saving again."))
                        .font(.footnote)
                        .foregroundStyle(ScanTheme.destructive)
                    HStack {
                        Button(history.hasFailedSaves ? LocalizedStringKey("Retry Save") : LocalizedStringKey("Reload")) {
                            if history.hasFailedSaves { history.retryFailedSaves() }
                            else { history.refresh() }
                        }
                        .disabled(history.isSaving || history.isClearing)
                        Spacer()
                        Button("Dismiss") { history.errorMessage = nil }
                            .foregroundStyle(ScanTheme.secondary)
                    }
                }
            }
            .listRowBackground(ScanTheme.card)
        }
    }

    @ViewBuilder
    private var recordsSection: some View {
        if history.entries.isEmpty {
            Section {
                ContentUnavailableView("No Scan History", systemImage: "clock",
                                       description: Text("Original point clouds are saved automatically after a successful scan."))
                    .listRowBackground(ScanTheme.card)
                    .accessibilityIdentifier("history.empty")
            }
        } else {
            Section {
                ForEach(history.entries) { entry in
                    Button { onOpen(entry) } label: { recordRow(entry) }
                        .buttonStyle(.plain)
                        .disabled(history.isLoading || history.isClearing)
                        .accessibilityIdentifier("history.entry.\(entry.id.uuidString)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) { pendingDeletion = entry }
                                .disabled(history.isSaving || history.isClearing)
                        }
                        .contextMenu {
                            Button("Open Original Scan", systemImage: "arrow.up.forward.app") { onOpen(entry) }
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = entry }
                                .disabled(history.isSaving || history.isClearing)
                        }
                        .listRowBackground(ScanTheme.card)
                }
            } header: {
                Text(L10n.scanCount(history.entries.count, locale: locale)) + Text(verbatim: " · ") + Text("Newest First")
            }
        }
    }

    private func recordRow(_ entry: ScanHistoryEntry) -> some View {
        HStack(spacing: 12) {
            ScanHistoryThumbnail(entry: entry, history: history)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.createdAt.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(locale)))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ScanTheme.primary)
                    .lineLimit(2)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(L10n.pointCount(entry.vertexCount, locale: locale))
                        Text(verbatim: "·")
                        Text(L10n.frameCount(entry.frameCount, locale: locale))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.pointCount(entry.vertexCount, locale: locale))
                        Text(L10n.frameCount(entry.frameCount, locale: locale))
                    }
                }
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(ScanTheme.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("Views: \(entry.coveredAngles.count) / \(ScanAngle.allCases.count)")
                        Text(Int64(entry.byteCount).formatted(.byteCount(style: .file).locale(locale)))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Views: \(entry.coveredAngles.count) / \(ScanAngle.allCases.count)")
                        Text(Int64(entry.byteCount).formatted(.byteCount(style: .file).locale(locale)))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(ScanTheme.secondary)
                Text(entry.isSample ? LocalizedStringKey("Sample — Not a Real Scan") : LocalizedStringKey("Original Scan"))
                    .font(.system(size: 12))
                    .foregroundStyle(ScanTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ScanTheme.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open the original point cloud to filter or export it.")
    }
}

/// A cached image of the original points. Only visible list rows request work;
/// disappearing rows can cancel without affecting the stored original.
private struct ScanHistoryThumbnail: View {
    let entry: ScanHistoryEntry
    @ObservedObject var history: ScanHistoryStore
    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            ScanTheme.canvas
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if isLoading {
                ProgressView()
                    .tint(ScanTheme.canvasAccent)
            } else {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(ScanTheme.canvasAccent.opacity(0.65))
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(ScanTheme.canvasTrack.opacity(0.5), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: entry.id) {
            isLoading = true
            image = nil
            do {
                let data = try await history.thumbnail(for: entry)
                guard !Task.isCancelled else { return }
                image = data.flatMap { UIImage(data: $0) }
            } catch {
                guard !Task.isCancelled else { return }
            }
            isLoading = false
        }
    }
}
