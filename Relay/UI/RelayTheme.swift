import SwiftUI

enum RelayTheme {
    static let mint = Color(red: 0.53, green: 0.91, blue: 0.76)
    static let ink = Color(red: 0.025, green: 0.075, blue: 0.085)
    static let muted = Color(red: 0.74, green: 0.81, blue: 0.81)
}

struct Atmosphere: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { proxy in
            if reduceTransparency { RelayTheme.ink }
            else {
                Image("TrackAtmosphere").resizable().scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    .overlay(LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.25), RelayTheme.ink.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            }
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}

struct SmokedSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat = 26
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(reduceTransparency ? AnyShapeStyle(RelayTheme.ink) : AnyShapeStyle(.ultraThinMaterial))
                    .overlay(RoundedRectangle(cornerRadius: radius).fill(Color(red: 0.09, green: 0.2, blue: 0.21).opacity(0.32)))
                    .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7))
            }
    }
}

extension View {
    func smoked(_ radius: CGFloat = 26) -> some View { modifier(SmokedSurface(radius: radius)) }
    func relayScreen() -> some View {
        background { Atmosphere() }
            .toolbarBackground(.hidden, for: .navigationBar)
            .foregroundStyle(.white)
    }
}

struct MetricTile: View {
    let title: String
    let symbol: String
    let value: String
    var caption: String = ""
    var positive = false
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 20, weight: .light))
                    .frame(width: 40, height: 40)
                    .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 0.7))
                Text(title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if positive { Circle().fill(RelayTheme.mint).frame(width: 8, height: 8) }
                    Text(value).font(.system(size: value.count > 8 ? 23 : 34, weight: .light, design: .default))
                        .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                }
                if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(RelayTheme.muted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .smoked()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) \(caption)")
    }
}

struct RelayRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let title: String
    let symbol: String
    var detail: String = ""
    var chevron = true
    var body: some View {
        Group {
        if dynamicType.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 22, weight: .light))
                    Spacer()
                    if chevron { Image(systemName: "chevron.right").font(.system(size: 16)).foregroundStyle(RelayTheme.muted) }
                }
                Text(title).font(.body).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(RelayTheme.muted).fixedSize(horizontal: false, vertical: true) }
            }.padding(18)
        } else {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20, weight: .light)).frame(width: 26)
            Text(title).font(.body)
            Spacer(minLength: 4)
            if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(RelayTheme.muted) }
            if chevron { Image(systemName: "chevron.right").font(.caption).foregroundStyle(RelayTheme.muted) }
        }.padding(.horizontal, 18).padding(.vertical, 17).contentShape(Rectangle())
        }
        }.accessibilityElement(children: .combine)
    }
}

struct RelayToggle: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let title: String
    let symbol: String
    let identifier: String
    @Binding var value: Bool
    var body: some View {
        Group {
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    Label(title, systemImage: symbol).fixedSize(horizontal: false, vertical: true)
                    Toggle(title, isOn: $value).labelsHidden().accessibilityLabel(title).accessibilityIdentifier(identifier)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Toggle(isOn: $value) { Label(title, systemImage: symbol) }.accessibilityIdentifier(identifier)
            }
        }.padding(.horizontal, 18).padding(.vertical, 13)
    }
}

struct SectionCaption: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.caption).tracking(0.8).foregroundStyle(RelayTheme.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8) }
}
