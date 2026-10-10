import SwiftUI

struct RootView: View {
    enum RootTab: Hashable {
        case catalog, inbox, settings
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = ItemListViewModel()
    @State private var syncViewModel = SyncViewModel()
    @State private var sharedInbox = SharedInboxViewModel()
    @State private var searchNavigation = CatalogSearchNavigation.shared
    @State private var catalogPresentationID = UUID()
    @State private var selectedTab: RootTab = .catalog

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Precios", systemImage: "tag", value: RootTab.catalog) {
                CatalogView(viewModel: viewModel, syncViewModel: syncViewModel, selectedTab: $selectedTab)
                    .id(catalogPresentationID)
            }
            Tab("Bandeja", systemImage: "tray.and.arrow.down", value: RootTab.inbox) {
                SharedInboxView(viewModel: sharedInbox) { await viewModel.load() }
            }
            .badge(sharedInbox.entries.count)
            Tab("Ajustes", systemImage: "gearshape", value: RootTab.settings) {
                SettingsView(viewModel: viewModel, syncViewModel: syncViewModel)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(Color.accentColor)
        .onChange(of: searchNavigation.pending, initial: true) { _, request in
            guard let request else { return }
            viewModel.searchText = request.term
            viewModel.categoryFilter = .all
            viewModel.statusFilter = .active
            selectedTab = .catalog
            catalogPresentationID = request.id
            searchNavigation.pending = nil
        }
        .task {
            let viewModel = viewModel
            sharedInbox.onItemAdded = { item, pageText in
                await viewModel.didAdd(item, pageText: pageText)
            }
            if AppGroup.isDemo {
                await viewModel.loadDemo()
                return
            }
            await syncViewModel.start()
            await sharedInbox.processAll()
            await viewModel.load()
            await syncViewModel.syncNow()
            await viewModel.load()
            await syncViewModel.monitorStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard !AppGroup.isDemo, phase == .active else { return }
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
