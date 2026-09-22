import SwiftUI
import OnwardCore

/// Passive horizontal light around the compact arrow. It never takes input.
struct HUDGlow: View {
    let status: FocusStatus
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var visible: Bool { [.focused, .drifting, .distracted].contains(status) }

    var body: some View {
        if visible {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !animated)) { timeline in
                Canvas { context, size in
                    let time = reduceMotion || !animated ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    draw(in: context, size: size, time: time)
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let red = status == .distracted, yellow = status == .drifting
        let primary = red ? Color(red: 1, green: 0.12, blue: 0.035)
            : yellow ? Color(red: 1, green: 0.65, blue: 0.05)
            : Color(red: 0.15, green: 0.93, blue: 0.68)
        let highlight = red ? Color(red: 1, green: 0.52, blue: 0.07)
            : yellow ? Color(red: 1, green: 0.89, blue: 0.30)
            : Color(red: 0.22, green: 0.81, blue: 0.92)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let cycle = time * 2 * .pi / (red ? 2.6 : yellow ? 4.2 : 7)
        let breath = 0.88 + 0.12 * sin(cycle)
        let extent = min(size.width / 2 - 10, (red ? 111 : yellow ? 99 : 91) + 5 * sin(cycle))

        for sign: CGFloat in [-1, 1] {
            let start = CGPoint(x: center.x + sign * 18, y: center.y)
            let end = CGPoint(x: center.x + sign * extent, y: center.y)
            if !reduceTransparency {
                var haze = context
                haze.addFilter(.blur(radius: red ? 7 : 9))
                var beam = Path(); beam.move(to: start); beam.addLine(to: end)
                haze.stroke(beam, with: .linearGradient(Gradient(colors: [primary.opacity((red ? 0.56 : 0.38) * breath),
                                                                                         highlight.opacity(0.18 * breath), .clear]),
                    startPoint: start, endPoint: end), style: StrokeStyle(lineWidth: red ? 23 : 19, lineCap: .round))
            }

            // Curved strands form gentle wings in green and a sharper, ember-lit eye in red.
            for strand in 0..<(red ? 4 : 2) {
                let upper: CGFloat = strand.isMultiple(of: 2) ? -1 : 1
                let spread: CGFloat = (red ? 18 : yellow ? 12 : 8) + CGFloat(strand / 2) * 3
                let drift = CGFloat(sin(cycle + Double(strand) * 0.9)) * (red ? 3.5 : 2)
                var ribbon = Path()
                ribbon.move(to: CGPoint(x: center.x + sign * 22, y: center.y + upper * 5))
                ribbon.addCurve(to: CGPoint(x: center.x + sign * extent, y: center.y + drift),
                    control1: CGPoint(x: center.x + sign * 47, y: center.y + upper * spread),
                    control2: CGPoint(x: center.x + sign * 77, y: center.y + upper * spread * 0.7 + drift))
                let alpha = reduceTransparency ? 0.8 : (red ? 0.60 : yellow ? 0.43 : 0.30)
                context.stroke(ribbon, with: .linearGradient(Gradient(colors: [primary.opacity(alpha), highlight.opacity(alpha * 0.7), .clear]),
                    startPoint: start, endPoint: end), style: StrokeStyle(lineWidth: red ? 1.4 : 1, lineCap: .round))
            }

            guard !reduceMotion, !reduceTransparency else { continue }
            for index in 0..<(red ? 7 : yellow ? 4 : 3) {
                let duration = red ? 2.1 : yellow ? 3.6 : 5.8
                let progress = (time / duration + Double(index) * 0.173).truncatingRemainder(dividingBy: 1)
                let distance = 26 + CGFloat(progress) * (extent - 26)
                let offset = sin(progress * .pi * 1.5 + Double(index)) * (red ? 12 : yellow ? 7 : 4)
                let point = CGPoint(x: center.x + sign * distance, y: center.y + offset)
                let radius: CGFloat = red ? 1.3 : 1
                let alpha = sin(progress * .pi) * (red ? 0.9 : 0.5)
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .color(highlight.opacity(alpha)))
            }
        }
    }
}
