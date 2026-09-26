import SwiftUI

struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var confirmDisconnect = false
    var body: some View {
        Form {
            if model.connected {
                Section {
                    Label("Your server is paired", systemImage: "checkmark.circle").foregroundStyle(RelayTheme.mint)
                    Text(model.serverText).font(.footnote).textSelection(.enabled)
                    Button("Check connection") { Task { await model.checkConnection() } }.disabled(model.isDemo)
                    LabeledContent("Reachability", value: model.serverStatus)
                } footer: { Text("Your iPhone must be able to reach this address. Connect to the network that hosts your server.") }
                if !model.healthRequested {
                    Section {
                        Button("Choose Apple Health access") { Task { await model.authorize(); if model.healthRequested { dismiss() } } }
                    }
                }
                Section {
                    Button("Disconnect this iPhone", role: .destructive) { confirmDisconnect = true }.disabled(model.busy || model.isDemo)
                } footer: { Text("Removes this iPhone’s saved credentials and stops uploads. Records already on your server remain there. Revoke the connection from the server dashboard if needed.") }
            } else {
                Section {
                    Text("Give your health data a home.").font(.title2.weight(.light))
                    Text("Use a one-time invitation code from your Open Wearables user page. Your administrator credentials stay off this iPhone.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Server") {
                    TextField("https://your-server", text: $address).textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("server-address")
                }
                Section {
                    SecureField("8-character code", text: $code).textInputAutocapitalization(.characters)
                        .autocorrectionDisabled().privacySensitive().accessibilityIdentifier("invitation-code")
                } header: {
                    Text("Invitation code")
                } footer: {
                    Text("In Open Wearables, open Users, select your user, and generate an invitation code. Enter it here while it is valid.")
                }
                Section {
                    Button {
                        Task { await model.pair(address: address, code: code); if model.connected { code = "" } }
                    } label: {
                        HStack { Text(model.pairing ? "Connecting…" : "Connect securely"); Spacer(); if model.pairing { ProgressView() } }
                    }.disabled(model.pairing || code.isEmpty).accessibilityIdentifier("pair-button")
                }
            }
            if let error = model.errorMessage { Section { Text(error).foregroundStyle(.orange).font(.subheadline) } }
        }
        .navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
        .onAppear { address = model.serverText }
        .confirmationDialog("Disconnect this iPhone?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { model.disconnectLocally(); dismiss() }
        } message: { Text("Uploads stop. Your server’s existing records are kept.") }
    }
}

struct HealthAccessView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section {
                Label("Read-only by design", systemImage: "heart").font(.title3)
                Text("Choose which records Relay can read. It never writes to Apple Health, and sends your selected records only to your paired server.")
            }
            Section("What Relay can transfer") {
                ForEach(HealthGroup.allCases) { group in Label(group.rawValue, systemImage: group.symbol) }
            }
            Section {
                Button(model.healthRequested ? "Review Health access" : "Choose Health access") { Task { await model.authorize() } }
                    .disabled(!model.connected || model.isDemo)
                if !model.connected { Text("Connect your server first.").font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Apple does not tell apps which read permissions you denied. To change an existing choice, open Health → your profile → Apps → Relay. The system may not show a new permission sheet when every type has already been requested. After allowing more data, use Settings → History → Rescan all history to include older records.")
            }
            Section { Text(HealthCatalog.limitations).font(.footnote).foregroundStyle(.secondary) }
            if let error = model.errorMessage { Section { Text(error).foregroundStyle(.orange) } }
        }.navigationTitle("Health access").navigationBarTitleDisplayMode(.inline)
    }
}

struct CoverageView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section {
                Label("\(HealthCatalog.entries.count) available types", systemImage: "checklist").font(.headline)
                Text("Supported by Relay’s reviewed Open Wearables mapping. Availability does not mean you have records or have granted read access.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !model.typeIssues.isEmpty {
                Section("Needs attention") {
                    ForEach(HealthCatalog.entries.filter { model.typeIssues[$0.id] != nil }) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.title).font(.headline)
                            Text(model.typeIssues[entry.id] ?? "").font(.subheadline).foregroundStyle(.orange)
                        }
                    }
                    Text("Relay will retry these types on the next sync. Their saved progress has not advanced past the affected page.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(HealthGroup.allCases) { group in
                Section(group.rawValue) {
                    ForEach(HealthCatalog.entries.filter { $0.group == group }) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                            if let issue = model.typeIssues[entry.id] { Text(issue).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
            }
            Section("Coverage limits") { Text(HealthCatalog.limitations).font(.subheadline) }
            Section("Deletion tracking") {
                LabeledContent("Recorded locally", value: model.state.deletedIDs.count.formatted())
                Text("This server does not accept HealthKit deletion events. A record deleted from Apple Health may still exist on your server.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Data fidelity") {
                Text("Measurements keep their sample IDs, timestamps, sources, and units in the upload. Workout summaries and events are included. High-frequency workout series, routes, and raw ECG traces are not. The server decides what metadata survives normalization.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Data coverage").navigationBarTitleDisplayMode(.inline)
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section {
                Label("All available history", systemImage: "clock.arrow.circlepath").font(.headline)
                Text("Relay reads from the beginning of the data Apple Health makes available. There is no 90-day cutoff.")
                LabeledContent("Types scanned to the end", value: "\(model.state.initialScanCompleted.count) / \(HealthCatalog.entries.count)")
                LabeledContent("Total records sent", value: model.state.totalSent.formatted())
            } footer: {
                Text("An initial import can take several sessions. Keep Relay open and your phone charged for the first import. Interrupted progress resumes automatically; after an iOS force-quit, reopen Relay. Empty results cannot distinguish missing data from denied access.")
            }
            Section {
                Button("Continue import") { Task { _ = await model.sync() } }.disabled(model.busy || !model.connected || !model.healthRequested || model.isDemo)
                Button("Rescan all history") { Task { await model.rescanHistory() } }.disabled(model.busy || !model.connected || !model.healthRequested || model.isDemo)
            } footer: {
                Text("Rescan after allowing additional Health access. Existing records are sent again with the same sample IDs. This does not delete data from your server.")
            }
            if let error = model.errorMessage { Section { Text(error).foregroundStyle(.orange) } }
        }.navigationTitle("History").navigationBarTitleDisplayMode(.inline)
    }
}

struct TransferDetailsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section("On this iPhone") {
                LabeledContent("Records in current batch", value: model.pendingCount.formatted())
                LabeledContent("Records sent today", value: model.sentToday.formatted())
                LabeledContent("Accepted batches", value: model.state.acceptedBatches.formatted())
                if let date = model.state.lastAccepted { LabeledContent("Last upload", value: date.formatted()) }
                if let date = model.state.lastScan { LabeledContent("Last complete scan", value: date.formatted()) }
            }
            Section("What these numbers mean") {
                Text("Sent means your server accepted an upload into its processing queue. It does not confirm that every record has finished processing. Check Syncs in Open Wearables for the server-side outcome.")
                Text("Waiting to send counts the batch already collected on this iPhone. During history import, more records may remain in Apple Health.")
                Text("An interrupted request can be retried. Sample IDs stay stable so the server can identify the same record.")
            }.font(.subheadline)
            if let error = model.errorMessage { Section("Last issue") { Text(error).foregroundStyle(.orange) } }
        }.navigationTitle("Transfer details").navigationBarTitleDisplayMode(.inline)
    }
}
