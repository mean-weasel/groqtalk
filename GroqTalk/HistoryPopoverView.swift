import AppKit
import SwiftUI

struct HistoryPopoverView: View {
    enum Filter: String, CaseIterable {
        case all = "All"
        case successful = "Successful"
        case failed = "Failed"
    }

    var history: TranscriptionHistory
    var onRetry: ((TranscriptionRecord) -> Void)?
    var onPaste: ((String) -> Void)?
    var showsHeader = true

    @State private var searchText = ""
    @State private var filter: Filter = .all
    @State private var isShowingClearConfirmation = false
    @State private var pendingDeleteRecord: TranscriptionRecord?
    @State private var selectedRecord: TranscriptionRecord?
    @State private var editedText = ""

    private var filteredRecords: [TranscriptionRecord] {
        history.records.filter { record in
            let matchesFilter = switch filter {
            case .all: true
            case .successful: !record.isFailure
            case .failed: record.isFailure
            }
            guard matchesFilter else { return false }

            if searchText.isEmpty { return true }
            if let text = record.text {
                return text.localizedCaseInsensitiveContains(searchText)
            }
            if let error = record.error {
                return error.localizedCaseInsensitiveContains(searchText)
            }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Divider()
            }
            searchAndFilters
            Divider()
            if filteredRecords.isEmpty {
                emptyState
            } else {
                recordsList
            }
        }
        .accessibilityIdentifier("history.root")
        .frame(minWidth: 420, idealWidth: 560, minHeight: 420, idealHeight: 560)
        .alert("Clear History?", isPresented: $isShowingClearConfirmation) {
            Button("Clear History", role: .destructive) {
                history.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all stored transcripts and any retained failed-audio retry files from this Mac.")
        }
        .alert("Delete History Item?", isPresented: pendingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let pendingDeleteRecord {
                    history.delete(id: pendingDeleteRecord.id)
                }
                pendingDeleteRecord = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteRecord = nil
            }
        } message: {
            Text("This removes the selected transcript and any retained failed-audio retry file from this Mac.")
        }
        .sheet(item: $selectedRecord) { record in
            detailView(for: history.records.first { $0.id == record.id } ?? record)
        }
    }

    private var pendingDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { pendingDeleteRecord != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteRecord = nil
                }
            }
        )
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("History")
                    .font(.headline)
                Text(history.isPersistenceEnabled ? "\(history.records.count) of \(history.retentionLimit) stored" : "History storage off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                copy(history.exportMarkdown())
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("history.exportButton")
            .disabled(history.records.isEmpty)

            Button("Clear", role: .destructive) {
                isShowingClearConfirmation = true
            }
            .accessibilityIdentifier("history.clearButton")
            .disabled(history.records.isEmpty)
        }
        .padding(12)
    }

    private var searchAndFilters: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcriptions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("history.searchField")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                ForEach(Filter.allCases, id: \.self) { filter in
                    Button(filter.rawValue) {
                        self.filter = filter
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityAddTraits(self.filter == filter ? .isSelected : [])
                    .accessibilityValue(self.filter == filter ? "Selected" : "Not selected")
                }
            }
            .accessibilityIdentifier("history.filterPicker")
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Image(systemName: searchText.isEmpty ? "clock" : "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "No transcriptions yet" : "No matches")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var recordsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredRecords) { record in
                    recordRow(record)
                    Divider()
                }
            }
        }
    }

    private func recordRow(_ record: TranscriptionRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.isFailure ? "exclamationmark.triangle.fill" : "text.bubble")
                .foregroundStyle(record.isFailure ? .red : .secondary)
                .font(.caption)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.text ?? record.error ?? "")
                    .lineLimit(3)
                    .font(.body)
                    .textSelection(.enabled)
                    .foregroundStyle(record.isFailure ? .red : .primary)
                Text(record.relativeTimestamp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    selectedRecord = record
                    editedText = record.text ?? ""
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
                .accessibilityIdentifier("history.row.detailsButton")
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Spacer()

            rowActions(for: record)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityIdentifier("history.row")
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRecord = record
            editedText = record.text ?? ""
        }
    }

    @ViewBuilder
    private func rowActions(for record: TranscriptionRecord) -> some View {
        HStack(spacing: 8) {
            if let text = record.text {
                Button {
                    copy(text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy")
                .accessibilityIdentifier("history.row.copyButton")
                .help("Copy")

                Button {
                    onPaste?(text)
                } label: {
                    Image(systemName: "arrow.turn.down.left")
                }
                .accessibilityLabel("Paste Again")
                .accessibilityIdentifier("history.row.pasteAgainButton")
                .help("Paste Again")
            }

            if record.isFailure, record.audioFileURL != nil {
                Button {
                    onRetry?(record)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Retry")
                .accessibilityIdentifier("history.row.retryButton")
                .help("Retry")
            }

            Button(role: .destructive) {
                pendingDeleteRecord = record
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete")
            .accessibilityIdentifier("history.row.deleteButton")
            .help("Delete")
        }
        .buttonStyle(.borderless)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func detailView(for record: TranscriptionRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(record.isFailure ? "Failure" : "Transcript")
                    .font(.headline)
                Spacer()
                Text(record.relativeTimestamp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let text = record.text {
                TextEditor(text: $editedText)
                    .font(.body)
                    .frame(minHeight: 180)
                    .accessibilityIdentifier("history.detail.editor")

                HStack {
                    Button {
                        history.updateSuccess(id: record.id, text: editedText)
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .accessibilityIdentifier("history.detail.saveButton")

                    Button {
                        copy(editedText)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("history.detail.copyButton")

                    Button {
                        onPaste?(editedText)
                    } label: {
                        Label("Paste", systemImage: "arrow.turn.down.left")
                    }
                    .accessibilityIdentifier("history.detail.pasteButton")

                    Spacer()

                    Button("Revert") {
                        editedText = text
                    }
                }
                .buttonStyle(.borderless)
            } else {
                Text(record.error ?? "")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("history.detail.error")

                if record.audioFileURL != nil {
                    Button {
                        onRetry?(record)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("history.detail.retryButton")
                }
            }

            Divider()

            HStack {
                Button(role: .destructive) {
                    history.delete(id: record.id)
                    selectedRecord = nil
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("history.detail.deleteButton")

                Spacer()

                Button("Done") {
                    selectedRecord = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .frame(minHeight: 320)
        .onAppear {
            editedText = record.text ?? ""
        }
    }
}
