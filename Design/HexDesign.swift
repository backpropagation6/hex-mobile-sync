import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// Shared visual language for the app, the keyboard and the widgets.
//
// Monochrome only: black, near-black surfaces, dark grays for cards and
// separators, white text. The only color is system red, reserved for the
// recording dot and errors. The motif is a set of concentric hexagons.

/// The monochrome palette. Colors adapt to light mode by inverting, so the
/// UI stays monochrome either way.
enum HexPalette {
    /// Window background: #0A0A0A (dark) / #FFFFFF (light).
    static let background = adaptive(dark: 0x0A0A0A, light: 0xFFFFFF)
    /// Content panels and bars: #141414 / #F4F4F4.
    static let surface = adaptive(dark: 0x141414, light: 0xF4F4F4)
    /// Panel outline: #232323 / #E2E2E2.
    static let surfaceBorder = adaptive(dark: 0x232323, light: 0xE2E2E2)
    /// Grouped cards and rows: #171717 / #F0F0F0.
    static let card = adaptive(dark: 0x171717, light: 0xF0F0F0)
    /// Card outline and hairlines: #262626 / #DADADA.
    static let separator = adaptive(dark: 0x262626, light: 0xDADADA)
    /// Selected item pill: #262626 / #E4E4E4.
    static let selection = adaptive(dark: 0x262626, light: 0xE4E4E4)
    /// Inset chip for example text: #0E0E0E / #EAEAEA.
    static let inset = adaptive(dark: 0x0E0E0E, light: 0xEAEAEA)
    /// Primary text and the hexagon mark: white / black.
    static let foreground = adaptive(dark: 0xFFFFFF, light: 0x000000)
    /// Secondary text: #8E8E8E / #6E6E6E.
    static let secondary = adaptive(dark: 0x8E8E8E, light: 0x6E6E6E)
    /// Section header text: #C8C8C8 / #3A3A3A.
    static let header = adaptive(dark: 0xC8C8C8, light: 0x3A3A3A)
    /// Primary button fill: light gray #E6E6E6 / #1C1C1C.
    static let buttonFill = adaptive(dark: 0xE6E6E6, light: 0x1C1C1C)
    /// Text on `foreground` or `buttonFill`.
    static let onForeground = adaptive(dark: 0x0A0A0A, light: 0xFFFFFF)
    /// Recording dot and errors only.
    static let alert = Color.red

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .light ? light : dark)
        })
        #else
        Color(hex: dark)
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif

extension Color {
    /// A fixed sRGB color from `0xRRGGBB`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A regular, pointy-top hexagon inscribed in the rect.
struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for index in 0..<6 {
            let angle = (Double(index) * 60 - 90) * .pi / 180
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// The three states the hexagon mark can show.
enum HexMarkState: Equatable, Sendable {
    case idle
    case recording
    case processing
}

/// Concentric hexagons: outer outline, middle outline, solid inner hexagon.
///
/// - idle: static rings.
/// - recording: the outer and middle rings breathe with `level`.
/// - processing: the rings take turns lighting up, inward.
///
/// Pass `animated: false` in widgets, where timeline animations do not run.
struct ConcentricHexagons: View {
    var state: HexMarkState = .idle
    /// Microphone level, 0...1. Used only while recording.
    var level: Float = 0
    var animated = true
    var color: Color = HexPalette.foreground

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if animated && state == .processing && !reduceMotion {
            TimelineView(.animation) { timeline in
                rings(processingPhase: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            rings(processingPhase: nil)
        }
    }

    private func rings(processingPhase: TimeInterval?) -> some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let line = max(1, side * 0.035)
            let boost = state == .recording && !reduceMotion ? CGFloat(min(max(level, 0), 1)) : 0
            ZStack {
                Hexagon()
                    .stroke(color.opacity(ringOpacity(0, phase: processingPhase, base: 0.45 + boost * 0.55)),
                            style: StrokeStyle(lineWidth: line, lineJoin: .round))
                    .frame(width: side * 0.96, height: side * 0.96)
                    .scaleEffect(1 + boost * 0.04)
                Hexagon()
                    .stroke(color.opacity(ringOpacity(1, phase: processingPhase, base: 0.75 + boost * 0.25)),
                            style: StrokeStyle(lineWidth: line, lineJoin: .round))
                    .frame(width: side * 0.70, height: side * 0.70)
                    .scaleEffect(1 + boost * 0.12)
                ParticleBlob(state: state, level: level, animated: animated, color: color)
                    .opacity(ringOpacity(2, phase: processingPhase, base: 1))
                    .frame(width: side * 0.42, height: side * 0.42)
                    .scaleEffect(state == .recording ? 0.86 + boost * 0.14 : 1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(animated && !reduceMotion ? .easeOut(duration: 0.12) : nil, value: level)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// While processing, a highlight travels from the outer ring inward.
    private func ringOpacity(_ index: Int, phase: TimeInterval?, base: Double) -> Double {
        guard state == .processing else { return base }
        guard let phase else { return index == 2 ? 0.6 : 0.35 }
        let position = (phase * 1.6).truncatingRemainder(dividingBy: 3)
        let distance = min(abs(position - Double(index)), 3 - abs(position - Double(index)))
        return 0.25 + 0.75 * max(0, 1 - distance)
    }
}

/// A small red dot that marks recording (the only use of color).
struct RecordingDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(HexPalette.alert)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Secondary label style: small caps, monospaced, tracked.
struct HexCaption: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption.monospaced().smallCaps())
            .tracking(0.6)
            .foregroundStyle(HexPalette.secondary)
    }
}

extension View {
    /// Small-caps monospaced secondary label.
    func hexCaption() -> some View { modifier(HexCaption()) }

    /// A grouped card: #171717 with a 1pt #262626 outline.
    func hexCard(cornerRadius: CGFloat = 12) -> some View {
        background(HexPalette.card, in: .rect(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(HexPalette.separator, lineWidth: 1)
            )
    }

    /// A content panel: #141414 with a subtle #232323 outline.
    func hexPanel(cornerRadius: CGFloat = 14) -> some View {
        background(HexPalette.surface, in: .rect(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(HexPalette.surfaceBorder, lineWidth: 1)
            )
    }
}

/// Monochrome buttons: primary is a light-gray rounded fill with dark text,
/// secondary is plain text.
struct HexButtonStyle: ButtonStyle {
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        HexButtonBody(configuration: configuration, filled: filled)
    }

    private struct HexButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let filled: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.subheadline.weight(filled ? .semibold : .medium))
                .padding(.horizontal, filled ? 16 : 6)
                .padding(.vertical, 9)
                .foregroundStyle(filled ? HexPalette.onForeground : HexPalette.foreground)
                .background(filled ? HexPalette.buttonFill : Color.clear, in: .rect(cornerRadius: 10))
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
                .contentShape(.rect(cornerRadius: 10))
        }
    }
}

/// Section header like Hex's settings: title on the left, a muted caption
/// right-aligned on the same line.
struct HexSectionHeader: View {
    let title: LocalizedStringKey
    var caption: LocalizedStringKey?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(HexPalette.header)
            Spacer(minLength: 12)
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(HexPalette.secondary)
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }
}

/// A settings row: thin outline symbol, title, gray subtitle, trailing value.
struct HexRow<Trailing: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.light))
                .foregroundStyle(HexPalette.foreground)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(HexPalette.foreground)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(HexPalette.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
                .font(.subheadline)
                .foregroundStyle(HexPalette.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

extension HexRow where Trailing == EmptyView {
    init(symbol: String, title: LocalizedStringKey, subtitle: String? = nil) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Monospaced example text in a dark inset, with a "›" prompt glyph.
struct HexChip: View {
    let text: String
    var isPlaceholder = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "›")
                .foregroundStyle(HexPalette.secondary)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .foregroundStyle(isPlaceholder ? HexPalette.secondary : HexPalette.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.monospaced())
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HexPalette.inset, in: .rect(cornerRadius: 8))
    }
}

/// An empty state: one muted sentence in a card.
struct HexEmptyCard: View {
    let message: LocalizedStringKey

    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(HexPalette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .hexCard()
    }
}

extension ButtonStyle where Self == HexButtonStyle {
    static var hex: HexButtonStyle { HexButtonStyle() }
    static var hexFilled: HexButtonStyle { HexButtonStyle(filled: true) }
}

extension View {
    /// Near-black list/form background (rows use `HexPalette.card`).
    func hexListBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(HexPalette.background)
    }
}

/// The dot-matrix waveform of Hex's recording pill: a grid of round dots
/// whose brightness follows a waveform mirrored around the middle row.
///
/// - idle/ready: a flat, dim line.
/// - recording: the wave with bright crests (animated with `level` in the app,
///   a fixed shape in widgets).
/// - processing: a bright band that travels left to right.
struct DotMatrixWave: View {
    var state: HexMarkState = .recording
    var columns = 72
    var rows = 13
    /// Microphone level, 0...1 (app only).
    var level: Float = 0.6
    var animated = true
    /// Shows only part of the wave (Dynamic Island halves): 0...1 range.
    var span: ClosedRange<Double> = 0...1
    var color: Color = .white
    /// Static frames (widgets): varies the wave shape between updates.
    var seed: Double = 0
    /// Dynamic Island halves: each half is a self-contained, symmetric wave
    /// that tapers towards the camera and the screen edge.
    var compact = false
    /// Voice level for compact waves in the Live Activity, 0...1.
    var compactLevel: Double? = nil
    /// Which Dynamic Island half this wave is.
    var compactSide: CompactSide = .symmetric

    enum CompactSide: Sendable { case symmetric, leading, trailing }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if animated && !reduceMotion && state != .idle {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                grid(time: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            grid(time: animated ? nil : seed)
        }
    }

    private func grid(time: TimeInterval?) -> some View {
        Canvas { context, size in
            let pitchX = size.width / CGFloat(columns)
            let pitchY = size.height / CGFloat(rows)
            let pitch = min(pitchX, pitchY)
            let middle = Double(rows - 1) / 2
            var particles: [(rect: CGRect, intensity: Double)] = []
            particles.reserveCapacity(columns * rows)
            for column in 0..<columns {
                let x = span.lowerBound + (span.upperBound - span.lowerBound) * (Double(column) + 0.5) / Double(columns)
                let local = (Double(column) + 0.5) / Double(columns)
                let amplitude = compact
                    ? Self.compactAmplitude(at: local, state: state, seed: time ?? seed, level: compactLevel, side: compactSide)
                    : Self.amplitude(at: x, state: state, level: Double(level), time: time)
                for row in 0..<rows {
                    let distance = abs(Double(row) - middle) / max(middle, 1)
                    // Soft edge: particles fade out across the wave boundary.
                    let inside = max(0, min(1, (amplitude - distance) * 4 + 0.5))
                    // Fine sparkle so the field never looks like a flat grid.
                    let seed = Double(column * 31 + row * 17)
                    let sparkle = 0.85 + 0.15 * sin(seed * 12.9898 + (time ?? 0) * (2 + seed.truncatingRemainder(dividingBy: 5)))
                    let intensity = inside * (1 - distance * 0.45) * sparkle
                    // Bright particles are larger, the dim grid stays a pinpoint.
                    let diameter = pitch * (0.30 + 0.58 * intensity)
                    let centre = CGPoint(x: (CGFloat(column) + 0.5) * pitchX, y: (CGFloat(row) + 0.5) * pitchY)
                    let rect = CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2, width: diameter, height: diameter)
                    particles.append((rect, intensity))
                }
            }
            // Glow pass: the bright particles, blurred, under the sharp ones.
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: pitch * 0.9))
                for particle in particles where particle.intensity > 0.45 {
                    glow.fill(Path(ellipseIn: particle.rect.insetBy(dx: -pitch * 0.25, dy: -pitch * 0.25)),
                              with: .color(color.opacity(0.55 * particle.intensity)))
                }
            }
            for particle in particles {
                context.fill(Path(ellipseIn: particle.rect),
                             with: .color(color.opacity(0.08 + 0.92 * particle.intensity)))
            }
        }
        .accessibilityHidden(true)
    }

    /// A small symmetric wave for one half of the Dynamic Island.
    static func compactAmplitude(at x: Double, state: HexMarkState, seed: Double, level: Double? = nil,
                                 side: DotMatrixWave.CompactSide = .symmetric) -> Double {
        // Halves of one wave that passes behind the camera: tallest at the
        // camera edge, tapering towards the screen edge.
        let envelope: Double = switch side {
        case .symmetric: pow(sin(.pi * x), 0.7)
        case .leading: pow(sin(.pi / 2 * x), 0.8)
        case .trailing: pow(sin(.pi / 2 * (1 - x)), 0.8)
        }
        switch state {
        case .idle:
            return 0.12 + 0.18 * envelope
        case .processing:
            return 0.15 + 0.35 * envelope * (0.6 + 0.4 * sin(x * 9 + seed))
        case .recording:
            let ripple = 0.45 + 0.55 * abs(sin(x * .pi * 2.5 + seed * 0.9))
            // With a level (Live Activity updates) the height follows the voice.
            let gain = level.map { 0.15 + 0.85 * min(max($0 * 2.2, 0), 1) } ?? 1
            return 0.12 + 0.88 * envelope * ripple * gain
        }
    }

    /// Height of the wave at `x` (0...1), as a fraction of the half height.
    static func amplitude(at x: Double, state: HexMarkState, level: Double, time: TimeInterval?) -> Double {
        switch state {
        case .idle:
            return 0.05
        case .processing:
            let head = time.map { ($0 * 0.8).truncatingRemainder(dividingBy: 1.4) - 0.2 } ?? 0.5
            return 0.05 + 0.55 * max(0, 1 - abs(x - head) * 6)
        case .recording:
            let t = time ?? 0
            let gain = 0.45 + 0.55 * min(max(level, 0), 1)
            // A narrow centre burst plus slower side swells, like the pill.
            let centre = exp(-pow((x - 0.5) * 9, 2)) * (0.85 + 0.15 * sin(t * 9))
            let swell = 0.32 + 0.18 * sin(x * 19 + t * 4) * sin(x * 7 - t * 2.3)
            return max(0.05, min(1, gain * max(centre, swell)))
        }
    }
}

/// Hex's black recording pill with the dot-matrix waveform inside.
struct DotWavePill: View {
    var state: HexMarkState = .recording
    var level: Float = 0.6
    var animated = true

    var body: some View {
        DotMatrixWave(state: state, level: level, animated: animated)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(LinearGradient(colors: [Color(hex: 0x1C1C1C), Color(hex: 0x050505)],
                                              startPoint: .top, endPoint: .bottom))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

/// The shaded cube at the centre of the Hex mark: three faces of a pointy-top
/// hexagon meeting in the middle, lit from above.
struct HexCube: View {
    var color: Color = HexPalette.foreground

    var body: some View {
        ZStack {
            CubeFace(face: .top).fill(color)
            CubeFace(face: .left).fill(color.opacity(0.74))
            CubeFace(face: .right).fill(color.opacity(0.52))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct CubeFace: Shape {
    enum Face { case top, left, right }
    var face: Face

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // Pointy-top vertices, clockwise from the top (screen coordinates).
        func v(_ i: Int) -> CGPoint {
            let a = (Double(i) * 60 - 90) * .pi / 180
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        let points: [CGPoint] = switch face {
        case .top: [v(0), v(1), c, v(5)]
        case .right: [v(1), v(2), v(3), c]
        case .left: [c, v(3), v(4), v(5)]
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

/// A blob of particles that breathes with the voice: a sunflower disc of
/// dots whose outline wobbles with soft waves and swells with the
/// microphone level; louder means bigger, brighter and more scattered.
///
/// Smoothness: the level is eased every frame (not on each 50 ms meter
/// sample) and rotation/wobble use accumulated phases, so speed changes
/// never make the particles jump.
struct ParticleBlob: View {
    var state: HexMarkState = .idle
    /// Microphone level, 0...1.
    var level: Float = 0
    var animated = true
    var color: Color = HexPalette.foreground
    var count = 420

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = BlobMotion()

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation) { timeline in
                    blob(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                blob(time: nil)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var targetEnergy: Double {
        switch state {
        // sqrt: normal speech already moves the blob a lot.
        case .recording: 0.18 + 0.82 * Double(min(max(level, 0), 1)).squareRoot()
        case .processing: 0.4
        case .idle: 0.1
        }
    }

    private func blob(time: TimeInterval?) -> some View {
        let frame = motion.advance(to: time, target: targetEnergy)
        return Canvas { context, size in
            let energy = frame.energy
            let radius = min(size.width, size.height) / 2
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let golden = Double.pi * (3 - 5.squareRoot())
            let w = frame.wobble
            var glow = Path()
            for index in 0..<count {
                let u = (Double(index) + 0.5) / Double(count)
                let angle = Double(index) * golden + frame.spin
                let wobble = 1
                    + energy * 0.20 * sin(angle * 3 + w * 1.0)
                    + energy * 0.12 * sin(angle * 5 - w * 1.6)
                    + energy * 0.06 * sin(angle * 8 + w * 2.3)
                let seed = Double(index) * 0.618
                let drift = 1 + energy * 0.06 * sin(seed * 40 + w * (1.2 + seed.truncatingRemainder(dividingBy: 1)))
                let r = radius * (0.6 + 0.4 * energy) * u.squareRoot() * wobble * drift * 0.8
                let point = CGPoint(x: centre.x + r * cos(angle), y: centre.y + r * sin(angle))
                let brightness = (1 - u * 0.65) * (0.55 + 0.45 * energy)
                let diameter = radius * (0.032 + 0.03 * energy) * (1.2 - u * 0.5)
                let rect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(brightness)))
                if u < 0.45 { glow.addEllipse(in: rect.insetBy(dx: -diameter, dy: -diameter)) }
            }
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: radius * 0.1))
                layer.blendMode = .plusLighter
                layer.fill(glow, with: .color(color.opacity(0.10 + 0.15 * energy)))
            }
        }
    }
}

/// Per-frame easing state for ``ParticleBlob`` (a class so the Canvas
/// frame can advance it without re-rendering the view).
final class BlobMotion {
    private var lastTime: TimeInterval?
    private var energy: Double = 0.1
    private var spin: Double = 0
    private var wobble: Double = 0

    struct Frame {
        var energy: Double
        var spin: Double
        var wobble: Double
    }

    func advance(to time: TimeInterval?, target: Double) -> Frame {
        guard let time else { return Frame(energy: target, spin: 0, wobble: 0) }
        let dt = min(max(time - (lastTime ?? time), 0), 1.0 / 20)
        lastTime = time
        // Fast attack, slower release, frame-rate independent.
        let rate = target > energy ? 14.0 : 4.0
        energy += (target - energy) * (1 - exp(-dt * rate))
        spin += dt * (0.15 + 0.5 * energy)
        wobble += dt * (1.2 + 3.5 * energy)
        return Frame(energy: energy, spin: spin, wobble: wobble)
    }
}
