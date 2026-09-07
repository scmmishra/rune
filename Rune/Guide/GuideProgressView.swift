import AppKit
import SwiftUI

struct GuideProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Indicator(isAnimating: !reduceMotion)
            .frame(width: 16, height: 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
    }

    private struct Indicator: NSViewRepresentable {
        let isAnimating: Bool

        func makeNSView(context: Context) -> IndicatorView { IndicatorView() }

        func updateNSView(_ view: IndicatorView, context: Context) {
            view.isAnimating = isAnimating
            view.updateAnimation()
        }

        static func dismantleNSView(_ view: IndicatorView, coordinator: ()) {
            view.isAnimating = false
            view.updateAnimation()
        }
    }

    private final class IndicatorView: NSView {
        var isAnimating = true
        private let ring = CAShapeLayer()
        private static let animationKey = "rotation"

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            ring.fillColor = nil
            ring.lineWidth = 1.5
            ring.lineCap = .round
            ring.strokeEnd = 0.75
            layer?.addSublayer(ring)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = bounds
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateColor()
            updateAnimation()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColor()
        }

        private func updateColor() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.strokeColor = NSColor.secondaryLabelColor.cgColor
            }
        }

        func updateAnimation() {
            guard isAnimating, window != nil else {
                ring.removeAnimation(forKey: Self.animationKey)
                return
            }
            guard ring.animation(forKey: Self.animationKey) == nil else { return }
            // The native progress indicator steps through 24 discrete frames in 0.8s.
            // Animate a layer continuously so guide loading stays smooth on fast displays
            // without asking SwiftUI to redraw the panel on every frame.
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = Double.pi * 2
            rotation.duration = 0.8
            rotation.repeatCount = .infinity
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            ring.add(rotation, forKey: Self.animationKey)
        }
    }
}
