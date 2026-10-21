import SwiftUI

struct MealLogView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section {
                Label("Log meals with your assistant", systemImage: "fork.knife").font(.title3)
                Text("Your assistant queues meals in Relay Hub over MCP. Relay saves each one to Apple Health as a food entry and reports back, so the assistant can track your intake.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Write access", value: writeAccess)
                Button(model.healthRequested ? "Review Health access" : "Choose Health access") { Task { await model.authorize() } }
                    .disabled(!model.connected || model.isDemo).accessibilityIdentifier("meal-access-button")
                if model.waitingForAccess > 0 {
                    Label("\(model.waitingForAccess) queued \(model.waitingForAccess == 1 ? "entry is" : "entries are") waiting for write access", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Apple Health")
            } footer: {
                Text("Relay writes only meals queued in your Relay Hub, and only energy, protein, carbohydrates, fat, fiber and sugar. While Relay is open it checks every 90 seconds; otherwise iOS decides when it runs. Change access in Health → your profile → Apps → Relay.")
            }
            if !model.state.activity.isEmpty {
                Section("Recent entries") {
                    ForEach(model.state.activity) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.title, systemImage: symbol(item.outcome))
                            Text("\(item.detail) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(item.outcome == .failed ? .orange : .secondary)
                        }
                    }
                }
            }
            if let error = model.errorMessage { Section { Text(error).foregroundStyle(.orange).font(.subheadline) } }
        }.navigationTitle("Meal logging").navigationBarTitleDisplayMode(.inline)
    }
    private var writeAccess: String {
        switch model.writeAccess {
        case .authorized: "Allowed"
        case .partial: "Partly allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not requested"
        }
    }
    private func symbol(_ outcome: WriteActivity.Outcome) -> String {
        switch outcome {
        case .saved: "checkmark.circle"
        case .removed: "trash"
        case .failed: "exclamationmark.triangle"
        case .waiting: "hourglass"
        }
    }
}
