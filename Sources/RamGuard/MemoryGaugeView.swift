import AppKit

/// Radial progress ring — the hero gauge of the v3 panel. Shows the used
/// fraction of the combined RAM+swap pool (한도 = installed RAM + allocated
/// swapfiles + storage that can still back new ones) as a band-colored arc
/// sweeping clockwise from 12 o'clock, with a light notch marking the
/// combined danger line (총 가용 under the VM 여유 임계) and a centered
/// readout (usually the used %). Layer-backed so value changes sweep
/// (0.45 s ease) instead of snapping — the panel refreshes every 10 s and
/// the motion makes the direction of change legible.
final class RingGaugeView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let notch = CALayer()
    private let centerLabel = NSTextField(labelWithString: "")

    private let lineWidth: CGFloat
    private var ringPath: CGPath?

    private var usedFraction: CGFloat = 0
    private var notchFraction: CGFloat?
    private var color: NSColor = DesignSystem.Palette.ok

    init(diameter: CGFloat, lineWidth: CGFloat = 7) {
        self.lineWidth = lineWidth
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true

        track.fillColor = nil
        track.lineWidth = lineWidth
        track.lineCap = .round
        track.strokeColor = NSColor.clear.cgColor
        layer?.addSublayer(track)

        arc.fillColor = nil
        arc.lineWidth = lineWidth
        arc.lineCap = .round
        layer?.addSublayer(arc)

        notch.cornerRadius = 1
        layer?.addSublayer(notch)

        centerLabel.font = DesignSystem.Font.rounded(12, .semibold)
        centerLabel.textColor = .labelColor
        centerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(centerLabel)
        NSLayoutConstraint.activate([
            centerLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no nib") }

    /// `thresholdUsedFraction` is the combined-pool danger line (nil hides
    /// the notch).
    func update(usedFraction: CGFloat, thresholdUsedFraction: CGFloat?, color: NSColor, animated: Bool, centerText: String) {
        let clamped = min(max(usedFraction, 0), 1)
        let changed = abs(clamped - self.usedFraction) > 0.0005 || thresholdUsedFraction != self.notchFraction
        self.usedFraction = clamped
        self.notchFraction = thresholdUsedFraction
        self.color = color
        centerLabel.stringValue = centerText
        refreshColors()
        layoutGauge(animate: animated && changed)
    }

    override func layout() {
        super.layout()
        layoutGauge(animate: false)
    }

    /// Template colors are appearance-sensitive; re-resolve on mode changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
        layoutGauge(animate: false)
    }

    private func refreshColors() {
        track.strokeColor = DesignSystem.Palette.trackFill.cgColor
        arc.strokeColor = color.cgColor
        notch.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85).cgColor
        centerLabel.attributedStringValue = NSAttributedString(
            string: centerLabel.stringValue,
            attributes: [.font: DesignSystem.Font.rounded(12, .semibold), .foregroundColor: NSColor.labelColor]
        )
    }

    private func layoutGauge(animate: Bool) {
        let size = min(bounds.width, bounds.height)
        guard size > lineWidth * 2 else { return }
        CATransaction.begin()
        if animate {
            CATransaction.setAnimationDuration(0.45)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        let center = CGPoint(x: size / 2, y: size / 2)
        let radius = (size - lineWidth) / 2
        if ringPath == nil {
            // A full circle starting at 12 o'clock, sweeping clockwise. The
            // sweep start matters: the arc reads as time passing / level
            // rising from the top, like Activity Monitor's CPU ring.
            let path = CGMutablePath()
            path.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            ringPath = path
            track.path = ringPath
            arc.path = ringPath
        }
        if let notchFraction {
            notch.isHidden = false
            // Radial tick at the defense level: θ clockwise from 12 o'clock.
            let theta = notchFraction * 2 * .pi
            notch.bounds = NSRect(x: 0, y: 0, width: 2, height: lineWidth + 5)
            notch.position = CGPoint(x: center.x + radius * sin(theta), y: center.y + radius * cos(theta))
            notch.setAffineTransform(CGAffineTransform(rotationAngle: theta))
        } else {
            notch.isHidden = true
        }
        arc.strokeEnd = usedFraction
        CATransaction.commit()
    }
}

/// Mini trend chart of the available-memory samples (one per engine tick,
/// ~10 s apart). Auto-scaled to the sampled range so even a flat 10-minute
/// window reads as movement; a dashed line marks the defense threshold
/// whenever it falls inside the visible range. Drawn with a smoothed curve
/// and a gradient fill so it reads as a designed element, not debug output.
final class SparklineView: NSView {
    private var samples: [Double] = []
    private var thresholdMiB: Double?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 40)
    }

    func update(samples: [Double], thresholdMiB: Double?) {
        self.samples = samples
        self.thresholdMiB = thresholdMiB
        needsDisplay = true
    }

    var tintColor: NSColor = DesignSystem.Palette.ok {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineColor = tintColor
        let width = bounds.width
        let height = bounds.height
        guard width > 4, height > 4 else { return }

        var values = samples
        if values.isEmpty { values = [0] }
        if values.count == 1 { values = [values[0], values[0]] }

        var low = values.min() ?? 0
        var high = values.max() ?? 1
        if let thresholdMiB, thresholdMiB < low { low = thresholdMiB }
        if let thresholdMiB, thresholdMiB > high { high = thresholdMiB }
        let span = max(high - low, 1)
        low -= span * 0.12
        high += span * 0.12

        func point(_ index: Int) -> NSPoint {
            let t = (values[index] - low) / (high - low)
            let x = width * CGFloat(index) / CGFloat(values.count - 1)
            return NSPoint(x: x, y: CGFloat(1 - t) * (height - 8) + 4)
        }

        let linePath = NSBezierPath()
        linePath.move(to: point(0))
        // Quadratic smoothing through segment midpoints keeps the curve soft
        // without overshooting (a full Catmull-Rom can dip below the floor).
        for index in 1..<values.count {
            let current = point(index)
            let previous = point(index - 1)
            let mid = NSPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            linePath.curve(to: mid, controlPoint1: NSPoint(x: (previous.x + mid.x) / 2, y: previous.y),
                           controlPoint2: NSPoint(x: (previous.x + mid.x) / 2, y: mid.y))
            linePath.curve(to: current, controlPoint1: NSPoint(x: (mid.x + current.x) / 2, y: mid.y),
                           controlPoint2: NSPoint(x: (mid.x + current.x) / 2, y: current.y))
        }

        // Fill under the curve.
        let fillPath = linePath.copy() as! NSBezierPath
        fillPath.line(to: NSPoint(x: width, y: 0))
        fillPath.line(to: NSPoint(x: 0, y: 0))
        fillPath.close()
        NSGradient(colors: [lineColor.withAlphaComponent(0.22), lineColor.withAlphaComponent(0.02)])?
            .draw(in: fillPath, angle: -90)

        // The line itself.
        lineColor.withAlphaComponent(0.95).setStroke()
        linePath.lineWidth = 1.5
        linePath.lineCapStyle = .round
        linePath.lineJoinStyle = .round
        linePath.stroke()

        // Threshold marker when inside the visible range.
        if let thresholdMiB, thresholdMiB >= low, thresholdMiB <= high {
            let t = (thresholdMiB - low) / (high - low)
            let ty = CGFloat(1 - t) * (height - 8) + 4
            let dashed = NSBezierPath()
            dashed.move(to: NSPoint(x: 0, y: ty))
            dashed.line(to: NSPoint(x: width, y: ty))
            NSColor.systemRed.withAlphaComponent(0.6).setStroke()
            dashed.lineWidth = 1
            dashed.setLineDash([3, 3], count: 2, phase: 0)
            dashed.stroke()
        }

        // Endpoint dot — makes the newest sample readable at a glance.
        let last = point(values.count - 1)
        NSColor.systemRed.withAlphaComponent(0).setFill()
        let dot = NSBezierPath(ovalIn: NSRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5))
        lineColor.setFill()
        dot.fill()
    }
}
