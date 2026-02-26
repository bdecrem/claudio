import SwiftUI

struct LaunchScreen: View {
    var body: some View {
        ZStack {
            Color(hex: "110604")
                .ignoresSafeArea()

            VStack(spacing: 28) {
                ClaudioCharacter()
                    .frame(width: 148, height: 165)

                Text("Claudio")
                    .font(.system(size: 36, weight: .bold, design: .serif))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(hex: "D4856A"),
                                Color(hex: "B05238"),
                                Color(hex: "8C3020")
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text("VOICE & TEXT")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(Color.white.opacity(0.25))
            }
        }
    }
}

/// v3 character: antennae, arms, legs, dark eyes with amber catchlights
private struct ClaudioCharacter: View {
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 148
            let sy = size.height / 165

            // Antennae
            drawAntenna(context: &context, sx: sx, sy: sy,
                        stem: (CGPoint(x: 60, y: 14), CGPoint(x: 59, y: 8), CGPoint(x: 53, y: 2), CGPoint(x: 55, y: -3)),
                        tip: CGPoint(x: 55, y: -4))
            drawAntenna(context: &context, sx: sx, sy: sy,
                        stem: (CGPoint(x: 88, y: 14), CGPoint(x: 89, y: 8), CGPoint(x: 95, y: 2), CGPoint(x: 93, y: -3)),
                        tip: CGPoint(x: 93, y: -4))

            // Arms
            let armColor = Color(hex: "9A3820")
            fillEllipse(context: &context, cx: 10 * sx, cy: 74 * sy, rx: 14 * sx, ry: 12 * sy, color: armColor)
            fillEllipse(context: &context, cx: 138 * sx, cy: 74 * sy, rx: 14 * sx, ry: 12 * sy, color: armColor)

            // Legs
            let legColor = Color(hex: "7A2A18")
            fillRoundedRect(context: &context, x: 48 * sx, y: 128 * sy, w: 18 * sx, h: 30 * sy, r: 7 * sx, color: legColor)
            fillRoundedRect(context: &context, x: 82 * sx, y: 128 * sy, w: 18 * sx, h: 30 * sy, r: 7 * sx, color: legColor)

            // Body
            let bodyCenter = CGPoint(x: 74 * sx, y: 74 * sy)
            let bodyR = 68 * sx
            let bodyPath = Path(ellipseIn: CGRect(x: bodyCenter.x - bodyR, y: bodyCenter.y - bodyR, width: bodyR * 2, height: bodyR * 2))
            context.fill(bodyPath, with: .radialGradient(
                Gradient(colors: [Color(hex: "EAB090"), Color(hex: "C86040"), Color(hex: "9A3820"), Color(hex: "621808")]),
                center: CGPoint(x: bodyCenter.x * 0.75, y: bodyCenter.y * 0.6),
                startRadius: 0, endRadius: bodyR
            ))

            // Specular
            fillEllipse(context: &context, cx: 50 * sx, cy: 48 * sy, rx: 30 * sx, ry: 20 * sy, color: .white.opacity(0.12))

            // Eyes (dark sockets)
            let eyeColor = Color(hex: "1A0806")
            fillCircle(context: &context, cx: 55 * sx, cy: 72 * sy, r: 17 * sx, color: eyeColor)
            fillCircle(context: &context, cx: 93 * sx, cy: 72 * sy, r: 17 * sx, color: eyeColor)

            // Amber catchlights
            let amber = Color(hex: "FFD060")
            fillCircle(context: &context, cx: 59 * sx, cy: 67 * sy, r: 5.5 * sx, color: amber)
            fillCircle(context: &context, cx: 97 * sx, cy: 67 * sy, r: 5.5 * sx, color: amber)

            // Small secondary catchlights
            fillCircle(context: &context, cx: 52 * sx, cy: 75 * sy, r: 1.8 * sx, color: amber.opacity(0.25))
            fillCircle(context: &context, cx: 90 * sx, cy: 75 * sy, r: 1.8 * sx, color: amber.opacity(0.25))

            // Mic badge
            fillCircle(context: &context, cx: 113 * sx, cy: 115 * sy, r: 16 * sx, color: Color(hex: "0E0604"))
            fillRoundedRect(context: &context, x: 110 * sx, y: 105 * sy, w: 7 * sx, h: 11 * sy, r: 3.5 * sx, color: .white)

            // Mic arc
            var micArc = Path()
            micArc.move(to: CGPoint(x: 107 * sx, y: 113 * sy))
            micArc.addQuadCurve(to: CGPoint(x: 113 * sx, y: 121 * sy), control: CGPoint(x: 107 * sx, y: 121 * sy))
            micArc.addQuadCurve(to: CGPoint(x: 119 * sx, y: 113 * sy), control: CGPoint(x: 119 * sx, y: 121 * sy))
            context.stroke(micArc, with: .color(.white), lineWidth: 1.9 * sx)

            // Mic stand
            var stand = Path()
            stand.move(to: CGPoint(x: 113 * sx, y: 121 * sy))
            stand.addLine(to: CGPoint(x: 113 * sx, y: 124.5 * sy))
            context.stroke(stand, with: .color(.white), style: StrokeStyle(lineWidth: 1.9 * sx, lineCap: .round))
        }
    }

    private func drawAntenna(context: inout GraphicsContext, sx: CGFloat, sy: CGFloat,
                             stem: (CGPoint, CGPoint, CGPoint, CGPoint), tip: CGPoint) {
        var path = Path()
        path.move(to: CGPoint(x: stem.0.x * sx, y: stem.0.y * sy))
        path.addCurve(to: CGPoint(x: stem.3.x * sx, y: stem.3.y * sy),
                       control1: CGPoint(x: stem.1.x * sx, y: stem.1.y * sy),
                       control2: CGPoint(x: stem.2.x * sx, y: stem.2.y * sy))
        context.stroke(path, with: .color(Color(hex: "C05A3C")), style: StrokeStyle(lineWidth: 2.2 * sx, lineCap: .round))
        fillCircle(context: &context, cx: tip.x * sx, cy: tip.y * sy, r: 3 * sx, color: Color(hex: "D4856A"))
        fillCircle(context: &context, cx: tip.x * sx, cy: tip.y * sy, r: 1.8 * sx, color: Color(hex: "EAA882"))
    }

    private func fillCircle(context: inout GraphicsContext, cx: CGFloat, cy: CGFloat, r: CGFloat, color: Color) {
        context.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)), with: .color(color))
    }

    private func fillEllipse(context: inout GraphicsContext, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, color: Color) {
        context.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)), with: .color(color))
    }

    private func fillRoundedRect(context: inout GraphicsContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, color: Color) {
        context.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r), with: .color(color))
    }
}
