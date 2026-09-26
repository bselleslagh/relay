import SwiftUI

struct SyncView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var sheet: RelaySheet?
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 10), count: dynamicType.isAccessibilitySize ? 1 : 2) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.heading).font(.system(size: 44, weight: .light)).tracking(-1.2)
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    Text(model.subtitle).font(.subheadline).foregroundStyle(RelayTheme.muted)
                }.padding(.top, 20).padding(.bottom, 5)
                if model.connected {
                    LazyVGrid(columns: columns, spacing: 10) {
                        MetricTile(title: "Sent\ntoday", symbol: "arrow.up", value: model.sentToday.formatted(), caption: "records")
                        MetricTile(title: "Waiting\nto send", symbol: "list.bullet", value: model.pendingCount.formatted(), caption: "in current batch")
                        MetricTile(title: "Last\nupload", symbol: "clock", value: model.state.lastAccepted?.formatted(date: .omitted, time: .shortened) ?? "—")
                        MetricTile(title: "Your\nserver", symbol: "externaldrive", value: model.serverStatus, positive: model.serverReachable == true)
                    }
                    .onTapGesture { sheet = .transfer }
                    Button("View transfer details") { sheet = .transfer }.font(.caption).foregroundStyle(RelayTheme.muted)
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        Label("Apple Health", systemImage: "heart").font(.title3)
                        HStack { Rectangle().fill(.white.opacity(0.2)).frame(height: 1); Image(systemName: "arrow.down").foregroundStyle(RelayTheme.mint); Rectangle().fill(.white.opacity(0.2)).frame(height: 1) }
                        Label("Your Open Wearables server", systemImage: "externaldrive").font(.title3)
                        Text("Your history, in your hands. Pair once, choose your health access, and let Relay take care of the uploads.")
                            .font(.subheadline).foregroundStyle(RelayTheme.muted)
                    }.padding(24).smoked()
                }
                HStack(spacing: 14) {
                    PixelSportsView()
                    Text("You move.\nRelay keeps up.").font(.subheadline).lineSpacing(4)
                }.padding(.vertical, 2)
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.orange.opacity(0.95))
                        .padding(16).smoked(20).accessibilityIdentifier("sync-error")
                }
                if !model.typeIssues.isEmpty {
                    Button { sheet = .coverage } label: {
                        Label("\(model.typeIssues.count) health \(model.typeIssues.count == 1 ? "type needs" : "types need") attention — view details", systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(.orange)
                    }
                }
                Button {
                    if !model.connected { sheet = .connection }
                    else if !model.healthRequested { sheet = .health }
                    else { Task { _ = await model.sync() } }
                } label: {
                    HStack(spacing: 12) {
                        if model.busy { ProgressView().tint(.white) }
                        else { Image(systemName: model.connected ? "arrow.triangle.2.circlepath" : "link").font(.title3) }
                        Text(!model.connected ? "Connect your server" : !model.healthRequested ? "Choose Health access" : model.busy ? "Sending…" : "Sync now")
                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.glass).controlSize(.large).disabled(model.busy)
                .accessibilityIdentifier("primary-sync-action")
                VStack(spacing: 5) {
                    Text("Background updates are managed by iOS.")
                    if model.connected { Text("Sent counts confirm upload acceptance, not processing.") }
                }.font(.caption2).foregroundStyle(RelayTheme.muted).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }.padding(.horizontal, 22).padding(.bottom, 24)
        }
        .navigationTitle("Relay").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Connection", systemImage: "link") { sheet = .connection }
                    Button("Data coverage", systemImage: "checklist") { sheet = .coverage }
                    Button("Transfer details", systemImage: "clock.arrow.circlepath") { sheet = .transfer }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .relayScreen()
        .sheet(item: $sheet) { RelaySheetContent(sheet: $0) }
    }
}
