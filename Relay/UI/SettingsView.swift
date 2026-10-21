import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: RelaySheet?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings").font(.system(size: 42, weight: .light)).tracking(-1).padding(.top, 24).padding(.bottom, 12)
                SectionCaption(text: "Connection")
                VStack(spacing: 0) {
                    Button { sheet = .connection } label: { RelayRow(title: "Relay Hub", symbol: "externaldrive") }
                    Divider().padding(.horizontal, 18)
                    Button { Task { await model.checkConnection() } } label: {
                        RelayRow(title: "Private connection", symbol: "wifi", detail: model.serverStatus)
                    }.disabled(model.isDemo)
                }.smoked().buttonStyle(.plain)
                SectionCaption(text: "Sync").padding(.top, 12)
                VStack(spacing: 0) {
                    RelayToggle(title: "Automatic sync", symbol: "arrow.triangle.2.circlepath", identifier: "automatic-toggle", value: Binding(get: { model.automatic }, set: model.setAutomatic))
                    Divider().padding(.horizontal, 18)
                    RelayToggle(title: "Wi-Fi only", symbol: "wifi", identifier: "wifi-toggle", value: Binding(get: { model.wifiOnly }, set: model.setWiFiOnly))
                    Divider().padding(.horizontal, 18)
                    Button { sheet = .history } label: { RelayRow(title: "History", symbol: "clock", detail: model.state.window.title) }.buttonStyle(.plain)
                }.smoked()
                Text("Uploads resume when your Relay Hub is reachable.").font(.caption).foregroundStyle(RelayTheme.muted).padding(.horizontal, 6)
                SectionCaption(text: "Apple Health").padding(.top, 12)
                VStack(spacing: 0) {
                    Button { sheet = .health } label: { RelayRow(title: "Health access", symbol: "heart") }
                    Divider().padding(.horizontal, 18)
                    Button { sheet = .coverage } label: { RelayRow(title: "Data coverage", symbol: "externaldrive") }
                }.smoked().buttonStyle(.plain)
                SectionCaption(text: "AI assistant").padding(.top, 12)
                VStack(spacing: 0) {
                    Button { sheet = .meals } label: { RelayRow(title: "Meal logging", symbol: "fork.knife", detail: mealStatus) }
                        .accessibilityIdentifier("meal-log-row")
                }.smoked().buttonStyle(.plain)
                Text("Meals your assistant logs in Relay Hub are saved to Apple Health.").font(.caption).foregroundStyle(RelayTheme.muted).padding(.horizontal, 6)
                HStack(spacing: 15) { PixelHeartMark(); Text("Your data. Your server.").font(.subheadline) }.padding(.top, 8)
                Text("Relay 1.0 · Made for your iPhone").font(.caption2).foregroundStyle(RelayTheme.muted)
            }.padding(.horizontal, 22).padding(.bottom, 26)
        }.relayScreen().sheet(item: $sheet) { RelaySheetContent(sheet: $0) }
    }
    private var mealStatus: String {
        if !model.healthRequested { return "Off" }
        if model.waitingForAccess > 0 { return "Needs access" }
        return model.writeAccess == .authorized ? "On" : "Allow access"
    }
}
