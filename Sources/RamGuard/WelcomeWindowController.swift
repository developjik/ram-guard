import AppKit

/// First-run onboarding (v3): a gradient shield badge, a numbered three-step
/// timeline, and a single call-to-action. Shown once (flag in UserDefaults);
/// re-openable any time from the panel ("사용법").
@MainActor
final class WelcomeWindowController: NSObject {
    static let seenKey = "ramguard.welcomeShown"
    /// Internal so the uitour diagnostic can snapshot the content view.
    var window: NSWindow?

    /// Shows the window and marks the onboarding as delivered — a user who
    /// closes it with the red X still never sees it twice.
    func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.seenKey) else { return }
        show()
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        Log.ui.notice("welcome shown (first run)")
    }

    func show() {
        let win: NSWindow
        if let window {
            win = window
        } else {
            win = buildWindow()
            window = win
        }
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func startClicked() {
        window?.performClose(nil)
    }

    // MARK: - Builders

    /// Gradient hero badge: an accent glow disc behind the shield glyph.
    private static func heroBadge() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 44

        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor,
            NSColor.controlAccentColor.withAlphaComponent(0.05).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        container.layer?.addSublayer(gradient)
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor

        let shield = NSImageView()
        shield.image = NSImage(
            systemSymbolName: "shield.lefthalf.filled",
            accessibilityDescription: "RAM Guard"
        )?.withSymbolConfiguration(.init(pointSize: 34, weight: .medium))
        shield.contentTintColor = .controlAccentColor
        shield.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(shield)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 88),
            container.heightAnchor.constraint(equalToConstant: 88),
            shield.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            shield.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        // The gradient must track the container's frame (layer sublayers don't
        // participate in Auto Layout).
        gradient.frame = CGRect(x: 0, y: 0, width: 88, height: 88)
        return container
    }

    /// One timeline step: numbered disc + title + description on an inset card.
    private static func stepCard(index: Int, title: String, text: String) -> NSView {
        let disc = NSView()
        disc.wantsLayer = true
        disc.layer?.cornerRadius = 11
        disc.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        disc.translatesAutoresizingMaskIntoConstraints = false

        let number = DesignSystem.makeLabel("\(index)", size: 11, weight: .semibold, color: .controlAccentColor)
        number.font = DesignSystem.Font.rounded(11, .semibold)
        number.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(number)
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: 22),
            disc.heightAnchor.constraint(equalToConstant: 22),
            number.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            number.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
        ])

        let titleLabel = DesignSystem.makeLabel(title, size: 12.5, weight: .semibold)
        let textLabel = NSTextField(wrappingLabelWithString: text)
        textLabel.font = DesignSystem.Font.label(11)
        textLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLabel, textLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.5).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = DesignSystem.Palette.cardStroke.cgColor
        card.addSubview(disc)
        card.addSubview(textStack)
        NSLayoutConstraint.activate([
            disc.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            disc.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
            textStack.leadingAnchor.constraint(equalTo: disc.trailingAnchor, constant: 12),
            textStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            textStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
            textStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        return card
    }

    private static func primaryButton(title: String, target: NSObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.bezelColor = .controlAccentColor
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        button.keyEquivalent = "\r"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 170).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    private func buildWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "RAM Guard"
        window.isReleasedWhenClosed = false

        let title = DesignSystem.makeLabel("RAM Guard에 오신 것을 환영해요", size: 19, weight: .bold)
        title.alignment = .center
        let subtitle = NSTextField(wrappingLabelWithString: "이 앱은 메모리 바닥으로 맥이 멈추는 사고(스왑데스)를 막는 조용한 경비원이에요.")
        subtitle.font = DesignSystem.Font.label(12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        let steps: [(String, String)] = [
            ("관찰 모드로 시작", "평소에는 조용히 지켜봐요. 어떤 앱도 종료하지 않고 기록만 남겨요."),
            ("위기에 자동 개입", "메모리가 바닥나 맥이 멈출 위기가 오면, 가장 큰 앱 하나를 종료해요."),
            ("방어로 전환", "동작에 확신이 서면 패널에서 '방어'로 전환하세요. 그 뒤로는 자동으로 지켜요."),
        ]
        let cards = steps.enumerated().map { Self.stepCard(index: $0.offset + 1, title: $0.element.0, text: $0.element.1) }

        let button = Self.primaryButton(title: "시작하기", target: self, action: #selector(startClicked))
        let footnote = NSTextField(wrappingLabelWithString: "임계치와 보호할 앱은 메뉴바의 방패 아이콘 패널에서 언제든 바꿀 수 있어요.")
        footnote.font = DesignSystem.Font.label(10.5)
        footnote.textColor = .tertiaryLabelColor
        footnote.alignment = .center

        let stack = NSStackView(views: [Self.heroBadge(), title, subtitle] + cards + [button, footnote])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: subtitle)
        stack.setCustomSpacing(20, after: cards.last!)
        stack.setCustomSpacing(12, after: button)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for element in cards + [subtitle, footnote] {
            element.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }

        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -26),
        ])
        return window
    }
}
