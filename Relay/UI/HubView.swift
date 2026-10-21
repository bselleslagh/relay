import SwiftUI

struct HubView: View {
    @State private var hub = HubModel.shared
    @State private var address = ""
    @State private var code = ""
    @State private var confirmDisconnect = false
    var body: some View {
        Form {
            if hub.paired { paired } else { pairing }
            if let error = hub.errorMessage { Section { Text(error).foregroundStyle(.orange).font(.subheadline) } }
        }
        .navigationTitle("Relay Hub").navigationBarTitleDisplayMode(.inline)
        .onAppear { address = hub.serverText }
        .confirmationDialog("Disconnect Relay Hub?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { hub.disconnect() }
        } message: { Text("Queued entries stay on your server. Meals already saved stay in Apple Health.") }
    }
    @ViewBuilder private var pairing: some View {
        Section {
            Text("Log meals with your AI assistant.").font(.title2.weight(.light))
            Text("Relay Hub runs on your own server. Your assistant queues meals there over MCP. Relay saves them to Apple Health and sends your nutrition back, so the assistant can track your intake.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        Section("Relay Hub address") {
            TextField("https://hub.your-tailnet.ts.net:8443", text: $address).textContentType(.URL).keyboardType(.URL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("hub-address")
        }
        Section {
            SecureField("8-character code", text: $code).textInputAutocapitalization(.characters)
                .autocorrectionDisabled().privacySensitive().accessibilityIdentifier("hub-code")
        } header: {
            Text("Pairing code")
        } footer: {
            Text("On your server, run docker compose exec relay-hub relay-hub pair-device. A code works once, for 10 minutes. Your MCP token never goes on this iPhone.")
        }
        Section {
            Button {
                Task { await hub.pair(address: address, code: code); if hub.paired { code = "" } }
            } label: {
                HStack { Text(hub.pairing ? "Pairing…" : "Pair securely"); Spacer(); if hub.pairing { ProgressView() } }
            }.disabled(hub.pairing || code.isEmpty || hub.isDemo).accessibilityIdentifier("hub-pair-button")
        }
    }
    @ViewBuilder private var paired: some View {
        Section {
            Label("Relay Hub is paired", systemImage: "checkmark.circle").foregroundStyle(RelayTheme.mint)
            Text(hub.serverText).font(.footnote).textSelection(.enabled)
            LabeledContent("This iPhone", value: hub.deviceName)
            LabeledContent("Status", value: hub.statusText)
            if let date = hub.lastSync { LabeledContent("Last check", value: date.formatted(date: .omitted, time: .shortened)) }
        } footer: {
            Text("While Relay is open it checks for new entries every 90 seconds. Otherwise iOS decides when Relay may run in the background.")
        }
        Section {
            LabeledContent("Write access", value: writeAccess)
            Button(hub.accessRequested ? "Review nutrition access" : "Allow nutrition access") { Task { await hub.requestAccess() } }
                .disabled(hub.isDemo).accessibilityIdentifier("hub-access-button")
            if hub.waitingForAccess > 0 {
                Label("\(hub.waitingForAccess) queued \(hub.waitingForAccess == 1 ? "entry is" : "entries are") waiting for write access", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text("Relay writes only the meals queued in Relay Hub: energy, protein, carbohydrates, fat, fiber and sugar. It reads those and saturated fat, sodium, cholesterol, caffeine and water to send your intake to Relay Hub. Change access in Health → your profile → Apps → Relay.")
        }
        Section {
            LabeledContent("Records sent", value: hub.state.samplesSent.formatted())
            if let date = hub.state.lastUpload { LabeledContent("Last upload", value: date.formatted(date: .abbreviated, time: .shortened)) }
            if hub.state.rejected > 0 { LabeledContent("Rejected by Relay Hub", value: hub.state.rejected.formatted()) }
            ForEach(hub.typeIssues.sorted(by: { $0.key < $1.key }), id: \.key) { issue in
                Text(issue.value).font(.caption).foregroundStyle(.orange)
            }
            Button(hub.busy ? "Syncing…" : "Sync now") { Task { _ = await hub.sync() } }
                .disabled(hub.busy || !hub.accessRequested || hub.isDemo)
        } header: {
            Text("Nutrition sync")
        } footer: {
            Text("The first sync sends the last \(HubState.historyDays) days. Deletions in Apple Health are removed from Relay Hub too.")
        }
        if !hub.state.activity.isEmpty {
            Section("Recent AI entries") {
                ForEach(hub.state.activity) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(item.title, systemImage: symbol(item.outcome))
                        Text("\(item.detail) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(item.outcome == .failed ? .orange : .secondary)
                    }
                }
            }
        }
        Section {
            Button("Disconnect Relay Hub", role: .destructive) { confirmDisconnect = true }.disabled(hub.busy || hub.isDemo)
        } footer: {
            Text("Removes this iPhone’s Relay Hub token. To revoke it on the server, run relay-hub revoke-device.")
        }
    }
    private var writeAccess: String {
        switch hub.writeAccess {
        case .authorized: "Allowed"
        case .partial: "Partly allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not requested"
        }
    }
    private func symbol(_ outcome: HubActivity.Outcome) -> String {
        switch outcome {
        case .saved: "checkmark.circle"
        case .removed: "trash"
        case .failed: "exclamationmark.triangle"
        case .waiting: "hourglass"
        }
    }
}
