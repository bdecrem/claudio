import SwiftUI

struct LaunchScreen: View {
    var body: some View {
        ZStack {
            // Background matching the icon: deep warm dark
            Color(hex: "180C08")
                .ignoresSafeArea()

            VStack(spacing: 28) {
                // The character — rendered as SwiftUI shapes matching the SVG
                ClaudioIcon()
                    .frame(width: 120, height: 120)

                Text("Claudio")
                    .font(.system(size: 36, weight: .bold, design: .serif))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(hex: "D4856A"),
                                Color(hex: "B85C45"),
                                Color(hex: "8C3A2A")
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

// SwiftUI recreation of the mascot icon
private struct ClaudioIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 120

            // Background
            let bgRect = CGRect(origin: .zero, size: size)
            context.fill(Path(bgRect), with: .linearGradient(
                Gradient(colors: [Color(hex: "2A1610"), Color(hex: "180C08")]),
                startPoint: .zero, endPoint: CGPoint(x: size.width * 0.6, y: size.height)
            ))

            // Ears
            drawEar(context: &context, cx: 33 * scale, cy: 24 * scale, rx: 9 * scale, ry: 13 * scale, angle: -18)
            drawEar(context: &context, cx: 87 * scale, cy: 24 * scale, rx: 9 * scale, ry: 13 * scale, angle: 18)

            // Body
            let bodyCenter = CGPoint(x: 60 * scale, y: 67 * scale)
            let bodyPath = Path(ellipseIn: CGRect(
                x: bodyCenter.x - 36 * scale, y: bodyCenter.y - 36 * scale,
                width: 72 * scale, height: 72 * scale
            ))
            context.fill(bodyPath, with: .radialGradient(
                Gradient(colors: [Color(hex: "E8A88A"), Color(hex: "B85840"), Color(hex: "7A2E1C")]),
                center: CGPoint(x: 0.38, y: 0.3), startRadius: 0, endRadius: 36 * scale
            ))

            // Eyes
            drawEye(context: &context, cx: 49 * scale, cy: 63 * scale, rx: 8.5 * scale, ry: 9.5 * scale, pupilX: 50.5 * scale, pupilY: 64 * scale, pr: 5 * scale, catchX: 52.2 * scale, catchY: 61.5 * scale, scale: scale)
            drawEye(context: &context, cx: 71 * scale, cy: 63 * scale, rx: 8.5 * scale, ry: 9.5 * scale, pupilX: 72.5 * scale, pupilY: 64 * scale, pr: 5 * scale, catchX: 74.2 * scale, catchY: 61.5 * scale, scale: scale)

            // Smile
            var smile = Path()
            smile.move(to: CGPoint(x: 52 * scale, y: 76 * scale))
            smile.addQuadCurve(to: CGPoint(x: 68 * scale, y: 76 * scale), control: CGPoint(x: 60 * scale, y: 82 * scale))
            context.stroke(smile, with: .color(Color(hex: "1C0C06").opacity(0.5)), lineWidth: 2 * scale)
        }
    }

    private func drawEar(context: inout GraphicsContext, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, angle: Double) {
        var transform = CGAffineTransform.identity
            .translatedBy(x: cx, y: cy)
            .rotated(by: angle * .pi / 180)
            .translatedBy(x: -cx, y: -cy)
        let earPath = Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)).applying(transform)
        context.fill(earPath, with: .color(Color(hex: "C0624A")))
    }

    private func drawEye(context: inout GraphicsContext, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, pupilX: CGFloat, pupilY: CGFloat, pr: CGFloat, catchX: CGFloat, catchY: CGFloat, scale: CGFloat) {
        let white = Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        context.fill(white, with: .color(.white))

        let pupil = Path(ellipseIn: CGRect(x: pupilX - pr, y: pupilY - pr, width: pr * 2, height: pr * 2))
        context.fill(pupil, with: .color(Color(hex: "1C0C06")))

        let catchlight = Path(ellipseIn: CGRect(x: catchX - 1.7 * scale, y: catchY - 1.7 * scale, width: 3.4 * scale, height: 3.4 * scale))
        context.fill(catchlight, with: .color(.white))
    }
}
