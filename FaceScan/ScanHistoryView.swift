import SwiftUI

/// Lists immutable original scans. Opening an entry returns it to the same
/// result workspace, where filtering and display enhancement remain copies.
struct ScanHistoryView: View {
    @ObservedObject var history: ScanHistoryStore
    let onOpen: (ScanHistoryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: ScanHistoryEntry?
    @State private var confirmsClearAll = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                recordsSection
                Section {
                    Text("扫描成功后自动保存一份原始点云，滤波和呈现增强不会覆盖它。历史仅存于本机，不自动淘汰；删除 App 会移除这些记录，请主动导出需要长期保留的模型。")
                        .font(.footnote)
                        .foregroundStyle(ScanTheme.secondary)
                        .listRowBackground(ScanTheme.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ScanTheme.background)
            .foregroundStyle(ScanTheme.primary)
            .tint(ScanTheme.tint)
            .navigationTitle("扫描历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("全部删除", role: .destructive) { confirmsClearAll = true }
                        .foregroundStyle(ScanTheme.destructive)
                        .disabled(history.entries.isEmpty || history.isSaving || history.isClearing)
                        .accessibilityIdentifier("history.clearAll")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .refreshable {
                history.refresh()
                await history.waitUntilIdle()
            }
            .onAppear { history.refresh() }
            .confirmationDialog("永久删除这份原始扫描？", isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ), titleVisibility: .visible) {
                if let entry = pendingDeletion {
                    Button("永久删除", role: .destructive) {
                        history.delete(entry)
                        pendingDeletion = nil
                    }
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("这份历史记录将从本机移除，无法恢复。已导出的 PLY 文件不受影响。")
            }
            .confirmationDialog("永久删除全部扫描历史？", isPresented: $confirmsClearAll,
                                titleVisibility: .visible) {
                Button("永久删除全部历史", role: .destructive) { history.clearAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("本机保存的所有原始扫描都会被移除，无法恢复。已导出的 PLY 文件不受影响。")
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if history.isLoading || history.isSaving || history.isClearing
            || history.hasFailedSaves || history.errorMessage != nil {
            Section {
                if history.isClearing {
                    ProgressView("正在清除历史…")
                } else if history.isSaving {
                    ProgressView("正在保存原始扫描…")
                } else if history.isLoading {
                    ProgressView("正在读取历史…")
                }
                if history.errorMessage != nil || history.hasFailedSaves {
                    Text(history.errorMessage ?? "有原始扫描尚未保存，请重试保存。")
                        .font(.footnote)
                        .foregroundStyle(ScanTheme.destructive)
                    HStack {
                        Button(history.hasFailedSaves ? "重试保存" : "重新读取") {
                            if history.hasFailedSaves { history.retryFailedSaves() }
                            else { history.refresh() }
                        }
                        .disabled(history.isSaving || history.isClearing)
                        Spacer()
                        Button("关闭提示") { history.errorMessage = nil }
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
                ContentUnavailableView("暂无历史记录", systemImage: "clock",
                                       description: Text("成功扫描后会自动保存原始点云。"))
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
                            Button("删除", role: .destructive) { pendingDeletion = entry }
                                .disabled(history.isSaving || history.isClearing)
                        }
                        .contextMenu {
                            Button("打开原始扫描", systemImage: "arrow.up.forward.app") { onOpen(entry) }
                            Button("删除", systemImage: "trash", role: .destructive) { pendingDeletion = entry }
                                .disabled(history.isSaving || history.isClearing)
                        }
                        .listRowBackground(ScanTheme.card)
                }
            } header: {
                Text("\(history.entries.count) 份原始扫描 · 最新在前")
            }
        }
    }

    private func recordRow(_ entry: ScanHistoryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 23, weight: .light))
                .foregroundStyle(ScanTheme.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.createdAt.formatted(date: .numeric, time: .standard))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ScanTheme.primary)
                Text("\(entry.vertexCount) 点 · \(entry.frameCount) 帧 · \(entry.coveredAngles.count)/\(ScanAngle.allCases.count) 视角")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(ScanTheme.secondary)
                HStack(spacing: 8) {
                    Text(entry.isSample ? "合成示例 · 非真实扫描" : "原始扫描")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                }
                .font(.system(size: 11))
                .foregroundStyle(ScanTheme.secondary)
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
        .accessibilityHint("打开原始点云，可重新滤波、增强或导出。")
    }
}
