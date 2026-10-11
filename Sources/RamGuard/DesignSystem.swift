import AppKit

/// The v3 visual language, in one place: color tokens, type ramp, spacing,
/// and the shared building blocks (cards, section captions, the capsule
/// segmented control) that the panel, welcome and history surfaces all use.
/// Everything resolves through semantic system colors so dark and light
/// appearances stay correct without per-surface tuning.
enum DesignSystem {
    // MARK: - Color tokens

    enum Palette {
        static let accent = NSColor.controlAccentColor

        /// Pressure bands. Yellow (not orange) marks "approaching" so the
        /// green→yellow→red ramp reads as a single severity scale.
        static let ok = NSColor.systemGreen
        static let warn = NSColor.systemYellow
        static let danger = NSColor.systemRed

        /// Inset card fill + hairline stroke, on any vibrancy/material base.
        static let cardFill = NSColor.quaternaryLabelColor.withAlphaComponent(0.5)
        static let cardFillStrong = NSColor.quaternaryLabelColor.withAlphaComponent(0.75)
        static let cardStroke = NSColor.separatorColor.withAlphaComponent(0.55)

        /// Track behind gauges and sliders.
        static let trackFill = NSColor.tertiaryLabelColor.withAlphaComponent(0.22)

        /// Hover/selected wash for interactive rows.
        static let rowHover = NSColor.quaternaryLabelColor.withAlphaComponent(0.7)
    }

    static func bandColor(_ band: StatusLine.Band) -> NSColor {
        switch band {
        case .normal: return Palette.ok
        case .approaching: return Palette.warn
        case .breached: return Palette.danger
        }
    }

    /// Severity dot per history event kind, shared by the panel's recent
    /// list and the history window.
    static func eventColor(_ kind: HistoryEvent.Kind) -> NSColor {
        switch kind {
        case .kill, .killFailed: return Palette.danger
        case .wouldKill: return Palette.warn
        case .noCandidate, .readFailed: return .systemOrange
        case .cooldownSuppressed, .pathUnresolvable: return .systemGray
        }
    }

    // MARK: - Type ramp

    enum Font {
        /// SF Rounded — friendlier numerals for hero readouts and gauges.
        static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
            return NSFont(descriptor: descriptor, size: size) ?? base
        }

        /// Tabular figures for anything that updates in place (memory values,
        /// times) so digits don't jitter between ticks.
        static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
            .monospacedDigitSystemFont(ofSize: size, weight: weight)
        }

        static func label(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
            .systemFont(ofSize: size, weight: weight)
        }
    }

    // MARK: - Metrics

    enum Radius {
        static let card: CGFloat = 14
        static let tile: CGFloat = 9
        static let row: CGFloat = 8
    }

    // MARK: - Shared builders

    /// Styles a plain NSView as an inset card (fill + hairline border).
    static func styleCard(_ view: NSView, radius: CGFloat = Radius.card) {
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.borderWidth = 1
        refreshCardChrome(view, radius: radius)
    }

    /// Appearance-sensitive chrome; call again from viewDidChangeEffectiveAppearance.
    static func refreshCardChrome(_ view: NSView, radius: CGFloat = Radius.card) {
        view.layer?.cornerRadius = radius
        view.layer?.backgroundColor = Palette.cardFill.cgColor
        view.layer?.borderColor = Palette.cardStroke.cgColor
    }

    static func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                          color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = Font.label(size, weight)
        field.textColor = color
        return field
    }

    static func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        // Must opt into Auto Layout: a translating view pinned edge-to-edge
        // injects frame-derived required constraints that poison the solve.
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.layer?.backgroundColor = Palette.cardStroke.cgColor
        return line
    }

    /// Small rounded chip behind app icons — dark icons vanish on dark
    /// surfaces, so they always sit on a neutral seat.
    static func iconChip(size: CGFloat = 22) -> NSView {
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = size / 2.6
        chip.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.55).cgColor
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.widthAnchor.constraint(equalToConstant: size).isActive = true
        chip.heightAnchor.constraint(equalToConstant: size).isActive = true
        return chip
    }
}

/// A sliding-pill segmented control used for the posture toggle (관찰/방어)
/// and the panel's section tabs. Pure AppKit, no private styling tricks:
/// a capsule container, a highlight layer that eases between segments, and
/// borderless text buttons on top. Color providers let callers tint the
/// selected pill per index (e.g. green for "방어").
@MainActor
final class CapsuleSegmentedControl: NSView {
    private let highlight = NSView()
    private var buttons: [NSButton] = []
    private let inset: CGFloat = 2

    private(set) var selectedIndex: Int = 0
    var onSelect: ((Int) -> Void)?
    /// Fill color of the pill for a selected index (defaults to a neutral wash).
    var selectedFill: ((Int) -> NSColor)?
    /// Text color for a selected index (defaults to labelColor).
    var selectedText: ((Int) -> NSColor)?
    /// Consumed by layout(): frame changes ease instead of snapping.
    private var animateNextLayout = false

    private let itemSpacing: CGFloat
    private let height: CGFloat

    init(labels: [String], symbols: [String?] = [], itemSpacing: CGFloat = 0, height: CGFloat = 26) {
        self.itemSpacing = itemSpacing
        self.height = height
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: height))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = height / 2
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = DesignSystem.Palette.cardStroke.cgColor

        highlight.wantsLayer = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.layer?.cornerRadius = (height - inset * 2) / 2
        addSubview(highlight)
        // Required self-height so the capsule can never collapse in a
        // stretched/stacked context.
        heightAnchor.constraint(equalToConstant: height).isActive = true

        for (index, label) in labels.enumerated() {
            let button = NSButton(title: label, target: self, action: #selector(itemClicked(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = (height - inset * 2) / 2
            button.tag = index
            if index < symbols.count, let symbol = symbols[index] {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
            }
            button.font = DesignSystem.Font.label(11.5, .medium)
            button.contentTintColor = .secondaryLabelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            buttons.append(button)
        }
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no nib") }

    var preferredHeight: CGFloat { height }

    func select(_ index: Int, animated: Bool = true) {
        guard index != selectedIndex else { return }
        selectedIndex = index
        refreshColors()
        animateNextLayout = animated
        needsLayout = true
    }

    private func refreshColors() {
        highlight.layer?.backgroundColor = (selectedFill?(selectedIndex)
            ?? NSColor.quaternaryLabelColor.withAlphaComponent(0.9)).cgColor
        for (index, button) in buttons.enumerated() {
            if index == selectedIndex {
                button.contentTintColor = selectedText?(index) ?? .labelColor
                button.attributedTitle = NSAttributedString(
                    string: button.title,
                    attributes: [
                        .font: DesignSystem.Font.label(11.5, .semibold),
                        .foregroundColor: selectedText?(index) ?? .labelColor,
                    ]
                )
            } else {
                button.contentTintColor = .secondaryLabelColor
                button.attributedTitle = NSAttributedString(
                    string: button.title,
                    attributes: [
                        .font: DesignSystem.Font.label(11.5, .medium),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                )
            }
        }
    }

    override func layout() {
        super.layout()
        guard !buttons.isEmpty else { return }
        CATransaction.begin()
        if animateNextLayout {
            animateNextLayout = false
            CATransaction.setAnimationDuration(0.22)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        let pad = (bounds.width - inset * 2 - itemSpacing * CGFloat(buttons.count - 1)) / CGFloat(buttons.count)
        let pillY = inset
        let pillH = height - inset * 2
        highlight.frame = NSRect(x: inset + CGFloat(selectedIndex) * (pad + itemSpacing), y: pillY, width: pad, height: pillH)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: inset + CGFloat(index) * (pad + itemSpacing), y: pillY, width: pad, height: pillH)
        }
        CATransaction.commit()
    }

    /// Width that fits all titles plus the capsule insets.
    override var intrinsicContentSize: NSSize {
        let textWidths = buttons.reduce(0) { $0 + $1.intrinsicContentSize.width }
        let symbolAllowance: CGFloat = buttons.contains { $0.image != nil } ? 16 * CGFloat(buttons.count) : 0
        return NSSize(width: textWidths + symbolAllowance + 24 + inset * 2, height: height)
    }

    @objc private func itemClicked(_ sender: NSButton) {
        guard sender.tag != selectedIndex else { return }
        select(sender.tag)
        onSelect?(sender.tag)
    }
}
