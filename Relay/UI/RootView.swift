import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        TabView {
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath") {
                NavigationStack { SyncView() }
            }
            Tab("Data", systemImage: "externaldrive") {
                NavigationStack { HealthDataView() }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
        }
        .overlay(alignment: .top) {
            if model.isDemo {
                Text("DESIGN PREVIEW · SAMPLE DATA").font(.system(size: 9, weight: .medium)).tracking(1)
                    .foregroundStyle(RelayTheme.muted).padding(.top, 1).allowsHitTesting(false)
                    .accessibilityIdentifier("demo-banner")
            }
        }
    }
}

enum RelaySheet: String, Identifiable {
    case connection, health, coverage, history, transfer
    var id: String { rawValue }
}

struct RelaySheetContent: View {
    let sheet: RelaySheet
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                switch sheet {
                case .connection: ConnectionView()
                case .health: HealthAccessView()
                case .coverage: CoverageView()
                case .history: HistoryView()
                case .transfer: TransferDetailsView()
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) } }
        }
        .tint(RelayTheme.mint)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
