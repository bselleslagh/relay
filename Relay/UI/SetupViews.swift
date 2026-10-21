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
                    Label("Your Relay Hub is paired", systemImage: "checkmark.circle").foregroundStyle(RelayTheme.mint)
                    Text(model.serverText).font(.footnote).textSelection(.enabled)
                    LabeledContent("This iPhone", value: model.deviceName)
                    Button("Check connection") { Task { await model.checkConnection() } }.disabled(model.isDemo)
                    LabeledContent("Reachability", value: model.serverStatus)
                } footer: { Text("Your iPhone must be able to reach this address, for example over your tailnet.") }
                if !model.healthRequested {
                    Section {
                        Button("Choose Apple Health access") { Task { await model.authorize(); if model.healthRequested { dismiss() } } }
                    }
                }
                Section {
                    Button("Disconnect this iPhone", role: .destructive) { confirmDisconnect = true }.disabled(model.busy || model.isDemo)
                } footer: { Text("Removes this iPhone’s device token and stops uploads. Records already on your Relay Hub remain there. To revoke the token on the server, run relay-hub revoke-device.") }
            } else {
                Section {
                    Text("Give your health data a home.").font(.title2.weight(.light))
                    Text("Relay sends Apple Health to Relay Hub, a small server you run yourself. Your assistant can read it there and log meals back.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Relay Hub address") {
                    TextField("https://hub.your-tailnet.ts.net:8443", text: $address).textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("server-address")
                }
                Section {
                    SecureField("8-character code", text: $code).textInputAutocapitalization(.characters)
                        .autocorrectionDisabled().privacySensitive().accessibilityIdentifier("pairing-code")
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("On your server, run docker compose exec relay-hub relay-hub pair-device. A code works once, for 10 minutes. The server's own secrets never go on this iPhone.")
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
            Button("Disconnect", role: .destructive) { Task { await model.disconnectLocally(); dismiss() } }
        } message: { Text("Uploads stop. Your Relay Hub keeps its records.") }
    }
}

struct HealthAccessView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section {
                Label("You choose what Relay reads", systemImage: "heart").font(.title3)
                Text("Choose which records Relay can read. It sends them only to your paired Relay Hub. Relay writes to Apple Health only to save meals your assistant logs: energy, protein, carbohydrates, fat, fiber and sugar.")
            }
            Section("What Relay can transfer") {
                ForEach(HealthGroup.allCases) { group in Label(group.rawValue, systemImage: group.symbol) }
            }
            Section {
                Button(model.healthRequested ? "Review Health access" : "Choose Health access") { Task { await model.authorize() } }
                    .disabled(!model.connected || model.isDemo)
                if !model.connected { Text("Connect your Relay Hub first.").font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Apple does not tell apps which read permissions you denied. To change an existing choice, open Health → your profile → Apps → Relay. The system may not show a new permission sheet when every type has already been requested. After allowing more data, use Settings → History → Rescan to include older records.")
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
                Text("Every type this iOS version offers in Relay's catalog. Availability does not mean you have records or have granted read access.")
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
            if !model.notShared.isEmpty {
                Section {
                    ForEach(HealthCatalog.entries.filter { model.notShared.contains($0.id) }) { Text($0.title).foregroundStyle(.secondary) }
                } header: {
                    Text("Not shared with Relay")
                } footer: {
                    Text("Apple Health has not granted these types. If Relay never asked for them, use Health access → Review Health access. Otherwise open Health → your profile → Apps → Relay.")
                }
            }
            Section("Coverage limits") { Text(HealthCatalog.limitations).font(.subheadline) }
            Section("Data fidelity") {
                Text("Records keep their HealthKit IDs, timestamps, time zones, sources and units. Deletions in Apple Health are removed from Relay Hub too. Daily totals come from HealthKit's own statistics, so iPhone and Apple Watch are not counted twice. Workout routes and high-frequency workout series are not sent.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Data coverage").navigationBarTitleDisplayMode(.inline)
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var window = HistoryWindow.month
    var body: some View {
        List {
            Section {
                Label(model.state.window.title, systemImage: "clock.arrow.circlepath").font(.headline)
                Text("The first import reads this far back. Relay then keeps syncing new records from its saved position.")
                LabeledContent("Types scanned in this import", value: "\(model.state.initialScanCompleted.count) / \(HealthCatalog.entries.count)")
                LabeledContent("Total records sent", value: model.state.totalSent.formatted())
            } footer: {
                Text("An initial import can take several sessions. Keep Relay open and your phone charged for the first import. Interrupted progress resumes automatically; after an iOS force-quit, reopen Relay. Empty results cannot distinguish missing data from denied access.")
            }
            Section {
                Picker("Import", selection: $window) {
                    ForEach(HistoryWindow.allCases) { Text($0.title).tag($0) }
                }
                Button("Continue import") { Task { _ = await model.sync() } }.disabled(model.busy || !model.connected || !model.healthRequested || model.isDemo)
                Button("Rescan \(window.title.lowercased())") { Task { await model.rescanHistory(window: window) } }
                    .disabled(model.busy || !model.connected || !model.healthRequested || model.isDemo)
            } footer: {
                Text("Rescan after allowing more Health access or to import further back. Records are sent again with the same IDs, so nothing is duplicated, and older records on your Relay Hub stay there.")
            }
            if let error = model.errorMessage { Section { Text(error).foregroundStyle(.orange) } }
        }
        .navigationTitle("History").navigationBarTitleDisplayMode(.inline)
        .onAppear { window = model.state.window }
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
                if model.state.rejected > 0 { LabeledContent("Rejected by Relay Hub", value: model.state.rejected.formatted()) }
                if let date = model.state.lastAccepted { LabeledContent("Last upload", value: date.formatted()) }
                if let date = model.state.lastScan { LabeledContent("Last complete scan", value: date.formatted()) }
            }
            Section("What these numbers mean") {
                Text("Sent means your Relay Hub stored the records. Records it rejects, for example because of an unexpected unit, are counted separately.")
                Text("Waiting to send counts the batch already collected on this iPhone. During history import, more records may remain in Apple Health.")
                Text("An interrupted request can be retried. Record IDs stay stable, so Relay Hub never stores the same record twice.")
            }.font(.subheadline)
            if let error = model.errorMessage { Section("Last issue") { Text(error).foregroundStyle(.orange) } }
        }.navigationTitle("Transfer details").navigationBarTitleDisplayMode(.inline)
    }
}
