import SwiftUI

struct HealthDataView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var sheet: RelaySheet?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Health data").font(.system(size: 42, weight: .light)).tracking(-1)
                    Text("A little more of the whole picture.").font(.subheadline).foregroundStyle(RelayTheme.muted)
                }.padding(.top, 24).padding(.bottom, 8)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: dynamicType.isAccessibilitySize ? 1 : 2), spacing: 10) {
                    ForEach([HealthGroup.activity, .vitals, .sleep, .workouts]) { group in
                        NavigationLink {
                            CategoryDetailView(group: group)
                        } label: {
                            MetricTile(title: group.rawValue, symbol: group.symbol,
                                       value: model.connected ? todayCount(group).formatted() : "—", caption: "records sent today")
                        }.buttonStyle(.plain)
                    }
                }
                VStack(spacing: 0) {
                    Button { sheet = .coverage } label: { RelayRow(title: "All data types", symbol: "list.bullet.rectangle") }
                    Divider().padding(.horizontal, 18)
                    Button { sheet = .health } label: { RelayRow(title: "Manage Health access", symbol: "lock") }
                }.smoked().buttonStyle(.plain)
                Text("Only data you allow is shared. Some Apple Health types are not supported by this server.")
                    .font(.caption).foregroundStyle(RelayTheme.muted).padding(.horizontal, 6)
            }.padding(.horizontal, 22).padding(.bottom, 28)
        }.relayScreen()
            .sheet(item: $sheet) { RelaySheetContent(sheet: $0) }
    }
    private func todayCount(_ group: HealthGroup) -> Int {
        Calendar.current.isDateInToday(model.state.day) ? model.state.sentByGroup[group, default: 0] : 0
    }
}

struct CategoryDetailView: View {
    let group: HealthGroup
    var body: some View {
        List {
            Section {
                ForEach(HealthCatalog.entries.filter { $0.group == group }) { entry in
                    Label(entry.title, systemImage: group.symbol)
                }
            } footer: {
                Text("Relay requests read access. Apple does not reveal which read permissions were denied; no records may mean no data or no access.")
            }
        }.navigationTitle(group.rawValue).scrollContentBackground(.hidden).relayScreen()
    }
}
