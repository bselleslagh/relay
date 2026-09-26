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
                    Button { sheet = .connection } label: { RelayRow(title: "Open Wearables", symbol: "externaldrive") }
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
                    Button { sheet = .history } label: { RelayRow(title: "History", symbol: "clock", detail: "All available") }.buttonStyle(.plain)
                }.smoked()
                Text("Uploads resume when your server is reachable.").font(.caption).foregroundStyle(RelayTheme.muted).padding(.horizontal, 6)
                SectionCaption(text: "Apple Health").padding(.top, 12)
                VStack(spacing: 0) {
                    Button { sheet = .health } label: { RelayRow(title: "Health access", symbol: "heart") }
                    Divider().padding(.horizontal, 18)
                    Button { sheet = .coverage } label: { RelayRow(title: "Data coverage", symbol: "externaldrive") }
                }.smoked().buttonStyle(.plain)
                HStack(spacing: 15) { PixelHeartMark(); Text("Your data. Your server.").font(.subheadline) }.padding(.top, 8)
                Text("Relay 1.0 · Made for your iPhone").font(.caption2).foregroundStyle(RelayTheme.muted)
            }.padding(.horizontal, 22).padding(.bottom, 26)
        }.relayScreen().sheet(item: $sheet) { RelaySheetContent(sheet: $0) }
    }
}
