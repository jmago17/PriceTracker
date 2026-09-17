import SwiftUI

struct RootView: View {
    enum RootTab: Hashable {
        case catalog, inbox, settings
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = ItemListViewModel()
    @State private var syncViewModel = SyncViewModel()
    @State private var sharedInbox = SharedInboxViewModel()
    @State private var selectedTab: RootTab = .catalog

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Precios", systemImage: "tag", value: RootTab.catalog) {
                CatalogView(viewModel: viewModel, syncViewModel: syncViewModel, selectedTab: $selectedTab)
            }
            Tab("Bandeja", systemImage: "tray.and.arrow.down", value: RootTab.inbox) {
                SharedInboxView(viewModel: sharedInbox) { await viewModel.load() }
            }
            .badge(sharedInbox.entries.count)
            Tab("Ajustes", systemImage: "gearshape", value: RootTab.settings) {
                SettingsView(viewModel: viewModel, syncViewModel: syncViewModel)
            }
        }
        .task {
            await syncViewModel.start()
            await sharedInbox.processAll()
            await viewModel.load()
            await syncViewModel.syncNow()
            await viewModel.load()
            await syncViewModel.monitorStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await syncViewModel.syncNow()
                await viewModel.load()
                sharedInbox.reload()
            }
        }
        .onChange(of: syncViewModel.snapshot.catalogRevision) { _, _ in
            Task { await viewModel.load() }
        }
    }
}

#Preview {
    RootView()
}
