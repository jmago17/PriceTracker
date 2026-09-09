import SwiftUI

struct SharedInboxView: View {
    @Bindable var viewModel: SharedInboxViewModel
    var onChanged: () async -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.urlString)
                            .font(.callout)
                            .lineLimit(2)
                        if let error = entry.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        HStack {
                            Button("Retry") {
                                Task { await viewModel.retry(entry); await onChanged() }
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Button("Delete", role: .destructive) { viewModel.delete(entry) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .overlay {
                if viewModel.entries.isEmpty {
                    ContentUnavailableView("No pending links", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("Shared links")
            .toolbar {
                if !viewModel.entries.isEmpty {
                    Button("Retry all") {
                        Task { await viewModel.processAll(); await onChanged() }
                    }
                    .disabled(viewModel.isProcessing)
                }
            }
        }
    }
}
