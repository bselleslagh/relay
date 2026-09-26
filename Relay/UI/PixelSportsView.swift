import SwiftUI

/// Decorative flipbook: eight frames per second, four seconds per sport.
/// Its clock lives here so the sync dashboard does not redraw on every tick.
struct PixelSportsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var started = Date()

    var body: some View {
        Group {
            if reduceMotion {
                PixelArtwork(frame: .heart)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 8, paused: !visible || scenePhase != .active)) { timeline in
                    let tick = max(0, Int(timeline.date.timeIntervalSince(started) * 8))
                    let sport = PixelSport.allCases[(tick / 32) % PixelSport.allCases.count]
                    PixelArtwork(frame: sport.frames[tick % 8])
                }
            }
        }
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
        .onAppear { started = Date(); visible = true }
        .onDisappear { visible = false }
    }
}

struct PixelHeartMark: View {
    var body: some View {
        PixelArtwork(frame: .heart).frame(width: 56, height: 56).accessibilityHidden(true)
    }
}

private struct PixelArtwork: View {
    @Environment(\.displayScale) private var displayScale
    let frame: PixelFrame

    var body: some View {
        Canvas { context, size in
            // Snap cell edges to physical pixels, including at 3x display scale.
            let cell = floor(min(size.width, size.height) * displayScale / 32) / displayScale
            let originX = (size.width - cell * 32) / 2
            let originY = (size.height - cell * 32) / 2
            for (index, color) in PixelFrame.palette.enumerated() where index > 0 {
                var path = Path()
                for (offset, ink) in frame.pixels.enumerated() where Int(ink) == index {
                    path.addRect(CGRect(x: originX + CGFloat(offset % 32) * cell,
                                        y: originY + CGFloat(offset / 32) * cell,
                                        width: cell, height: cell))
                }
                context.fill(path, with: .color(color), style: FillStyle(antialiased: false))
            }
        }
    }
}

private enum PixelSport: Int, CaseIterable {
    case gym, running, cycling, tennis

    // All geometry is rasterized once, not recalculated on animation ticks.
    private static let flipbooks = allCases.map { sport in
        (0..<8).map { frame in
            switch sport {
            case .gym: PixelFrame.gym(frame)
            case .running: PixelFrame.running(frame)
            case .cycling: PixelFrame.cycling(frame)
            case .tennis: PixelFrame.tennis(frame)
            }
        }
    }
    var frames: [PixelFrame] { Self.flipbooks[rawValue] }
}

/// Tiny integer-grid drawing vocabulary shared by the four hand-built flipbooks.
private struct PixelFrame {
    // 0 clear, 1 ivory, 2 skin, 3 mint, 4 jade, 5 deep teal, 6 amber, 7 shadow.
    static let palette: [Color] = [
        .clear, Color(red: 0.93, green: 0.96, blue: 0.85),
        Color(red: 0.84, green: 0.77, blue: 0.60), RelayTheme.mint,
        Color(red: 0.25, green: 0.65, blue: 0.53), Color(red: 0.12, green: 0.36, blue: 0.34),
        Color(red: 1, green: 0.76, blue: 0.43), Color(red: 0.11, green: 0.24, blue: 0.25)
    ]
    var pixels = [UInt8](repeating: 0, count: 32 * 32)

    mutating func dot(_ x: Int, _ y: Int, _ ink: UInt8) {
        guard (0..<32).contains(x), (0..<32).contains(y) else { return }
        pixels[y * 32 + x] = ink
    }
    mutating func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ ink: UInt8) {
        for row in y..<(y + height) {
            for column in x..<(x + width) { dot(column, row, ink) }
        }
    }
    mutating func line(_ a: (Int, Int), _ b: (Int, Int), _ ink: UInt8, _ width: Int = 1) {
        let count = max(abs(b.0 - a.0), abs(b.1 - a.1))
        for step in 0...max(1, count) {
            let t = Double(step) / Double(max(1, count))
            let x = Int((Double(a.0) + Double(b.0 - a.0) * t).rounded())
            let y = Int((Double(a.1) + Double(b.1 - a.1) * t).rounded())
            rect(x - width / 2, y - width / 2, width, width, ink)
        }
    }
    mutating func ring(_ x: Int, _ y: Int, _ rx: Int, _ ry: Int, _ ink: UInt8) {
        for step in 0..<64 {
            let angle = Double(step) * .pi / 32
            dot(x + Int((cos(angle) * Double(rx)).rounded()),
                y + Int((sin(angle) * Double(ry)).rounded()), ink)
        }
    }
    mutating func head(_ x: Int, _ y: Int, helmet: Bool = false) {
        rect(x - 2, y - 2, 5, 5, 2)
        rect(x, y - 1, 3, 3, 1)
        rect(x - 2, y - 3, 5, 2, helmet ? 1 : 5)
        if helmet { rect(x - 3, y - 2, 7, 1, 3) }
        dot(x + 2, y, 5)
        rect(x - 1, y + 3, 2, 2, 2)
    }
    mutating func shoe(_ x: Int, _ y: Int) {
        rect(x - 1, y - 1, 3, 2, 1)
        rect(x - 1, y + 1, 5, 1, 3)
    }

    static let heart: PixelFrame = {
        let rows = [
            "..hhhh...hhhh..", ".hllllh.hllllh.", "hllllllhllllllh",
            "hllwwlllllllllh", "hllwllllllllllh", "hlllllllllllllh",
            ".hlllllllllllh.", "..hlllllllllh..", "...hlllllllh...",
            "....hlllllh....", ".....hlllh.....", "......hlh......", ".......h......."
        ]
        var art = PixelFrame()
        for (y, row) in rows.enumerated() {
            for (x, pixel) in row.enumerated() where pixel != "." {
                art.rect(1 + x * 2, 3 + y * 2, 2, 2, pixel == "h" ? 4 : pixel == "w" ? 1 : 3)
            }
        }
        return art
    }()

    static func gym(_ frame: Int) -> PixelFrame {
        var art = PixelFrame()
        let bar = [5, 5, 7, 11, 16, 16, 11, 7][frame]
        // Planted stance and a controlled overhead press.
        art.line((13, 23), (11, 29), 2, 3)
        art.line((18, 23), (20, 29), 2, 3)
        art.shoe(10, 29); art.shoe(20, 29)
        art.rect(12, 21, 8, 4, 5)
        art.rect(12, 16, 8, 7, 4)
        art.rect(13, 16, 6, 6, 3)
        art.line((12, 17), (8, bar + 4), 3, 3)
        art.line((8, bar + 4), (7, bar), 2, 2)
        art.line((19, 17), (23, bar + 4), 4, 3)
        art.line((23, bar + 4), (24, bar), 2, 2)
        art.head(16, 11)
        art.line((3, bar), (28, bar), 1)
        for x in [3, 26] {
            art.rect(x, bar - 3, 3, 7, 5)
            art.rect(x, bar - 3, 1, 7, 3)
            art.rect(x + 1, bar - 4, 1, 9, 4)
        }
        art.rect(1, bar - 1, 2, 3, 6); art.rect(29, bar - 1, 2, 3, 6)
        art.rect(6, bar, 2, 2, 2); art.rect(23, bar, 2, 2, 2)
        return art
    }

    static func running(_ frame: Int) -> PixelFrame {
        var art = PixelFrame()
        let bob = [0, 0, -1, -1, 0, 0, -1, -1][frame]
        let knees = [(19, 22), (18, 23), (14, 24), (10, 22), (8, 21), (10, 23), (14, 24), (18, 23)]
        let feet = [(16, 27), (21, 28), (17, 29), (7, 27), (4, 24), (8, 26), (13, 29), (18, 28)]
        let far = (frame + 4) % 8
        art.line((14, 20 + bob), knees[far], 5, 3)
        art.line(knees[far], feet[far], 2, 2)
        art.shoe(feet[far].0, feet[far].1)
        let arm = [0, 2, 3, 2, 0, -2, -3, -2][frame]
        art.line((17, 13 + bob), (20 - arm, 17 + bob), 4, 3)
        art.line((20 - arm, 17 + bob), (23 - arm, 14 + bob), 2, 2)
        art.line((17, 12 + bob), (14, 19 + bob), 4, 6)
        art.line((17, 12 + bob), (15, 18 + bob), 3, 4)
        art.line((13, 20 + bob), knees[frame], 2, 3)
        art.line(knees[frame], feet[frame], 2, 2)
        art.line((13, 19 + bob), (16, 21 + bob), 5, 4)
        art.shoe(feet[frame].0, feet[frame].1)
        art.line((15, 13 + bob), (11 + arm, 16 + bob), 3, 3)
        art.line((11 + arm, 16 + bob), (8 + arm, 13 + bob), 1, 2)
        art.head(19, 7 + bob, helmet: true)
        art.rect(21, 5 + bob, 3, 1, 6)
        return art
    }

    static func cycling(_ frame: Int) -> PixelFrame {
        var art = PixelFrame()
        let angle = Double(frame) * .pi / 4
        for x in [7, 25] {
            art.ring(x, 24, 6, 6, 4)
            art.ring(x, 24, 5, 5, 7)
            let dx = Int((cos(angle) * 4).rounded()), dy = Int((sin(angle) * 4).rounded())
            art.line((x - dx, 24 - dy), (x + dx, 24 + dy), 5)
            art.line((x + dy, 24 - dx), (x - dy, 24 + dx), 5)
            art.dot(x, 24, 1)
        }
        art.line((7, 24), (13, 16), 6)
        art.line((13, 16), (17, 24), 6)
        art.line((17, 24), (7, 24), 6)
        art.line((13, 16), (23, 16), 6)
        art.line((23, 16), (17, 24), 6)
        art.line((22, 13), (25, 24), 1)
        art.line((22, 13), (26, 13), 1)
        art.rect(10, 15, 5, 1, 1)
        let pedal = (17 + Int((cos(angle) * 3).rounded()), 23 + Int((sin(angle) * 3).rounded()))
        let farPedal = (34 - pedal.0, 46 - pedal.1)
        art.line((13, 16), (16, 19), 5, 3)
        art.line((16, 19), farPedal, 2, 2)
        art.line((18, 11), (13, 15), 4, 5)
        art.line((18, 10), (14, 13), 3, 3)
        art.line((13, 15), (18 + (pedal.0 - 17) / 2, 18), 5, 3)
        art.line((18 + (pedal.0 - 17) / 2, 18), pedal, 2, 2)
        art.line((17, 23), pedal, 1)
        art.rect(pedal.0 - 1, pedal.1, 4, 1, 1)
        art.line((19, 12), (21, 15), 3, 2)
        art.line((21, 15), (25, 14), 1, 2)
        art.head(21, 7, helmet: true)
        art.rect(21, 4, 2, 1, 6)
        return art
    }

    static func tennis(_ frame: Int) -> PixelFrame {
        var art = PixelFrame()
        let hands = [(22, 18), (23, 16), (22, 13), (19, 10), (16, 10), (17, 13), (19, 16), (21, 18)]
        let racket = [(27, 16), (28, 12), (25, 7), (21, 4), (13, 5), (13, 9), (22, 12), (26, 16)]
        let bob = frame == 2 || frame == 3 ? -1 : 0
        art.line((12, 22), (8, 28), 2, 3)
        art.line((16, 22), (20, 28), 2, 3)
        art.shoe(7, 29); art.shoe(20, 29)
        art.rect(10, 20, 9, 4, 1)
        art.line((14, 14 + bob), (14, 20), 4, 7)
        art.line((14, 14 + bob), (14, 19), 3, 5)
        art.line((11, 15 + bob), (7, 18), 3, 3)
        art.line((7, 18), (5, 15), 1, 2)
        art.line((17, 15 + bob), (19, 18 + bob), 4, 3)
        art.line((19, 18 + bob), hands[frame], 2, 2)
        art.line(hands[frame], racket[frame], 6)
        art.ring(racket[frame].0, racket[frame].1, 3, 4, 1)
        art.line((racket[frame].0, racket[frame].1 - 2), (racket[frame].0, racket[frame].1 + 2), 4)
        art.line((racket[frame].0 - 2, racket[frame].1), (racket[frame].0 + 2, racket[frame].1), 4)
        art.head(14, 9 + bob)
        art.rect(12, 7 + bob, 5, 1, 1)
        let ball = [(29, 4), (29, 7), (28, 10), (29, 6), (30, 3), (30, 3), (30, 3), (30, 3)][frame]
        art.rect(ball.0, ball.1, 2, 2, 6)
        return art
    }
}

#Preview("Sports flipbook") {
    HStack(spacing: 14) {
        PixelSportsView()
        Text("You move.\nRelay keeps up.").font(.subheadline).lineSpacing(4)
    }.foregroundStyle(.white).padding(24).background(RelayTheme.ink)
}

#Preview("Reduce Motion") {
    PixelArtwork(frame: .heart).frame(width: 72, height: 72).padding().background(RelayTheme.ink)
}
