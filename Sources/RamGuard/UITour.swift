import AppKit

/// Headless UI renderer for QA (`ramguard uitour [outdir]`): builds the v3
/// surfaces with realistic state, renders them offscreen through the layer
/// tree, and writes PNG artifacts. No screen-recording permission and no
/// window flashing — the same view hierarchy the live app shows, laid out
/// and rasterized in-process under the dark appearance.
@MainActor
enum UITour {
    static func run(outputDirectory: URL) -> Never {
        // Render under darkAqua so artifacts match the shipping dark-mode look;
        // init-time cgColor conversions in the design system resolve dark.
        NSAppearance.current = NSAppearance(named: .darkAqua)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let outputDirectoryURL = URL(fileURLWithPath: outputDirectory.path, isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)

        // Isolated fake stores (never touch real user config or defaults).
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ramguard-uitour-\(UUID().uuidString)", isDirectory: true)
        let exclusions = ExclusionsStore(url: tempDir.appendingPathComponent("exclusions.txt"))
        exclusions.add("Whale")
        let suite = UserDefaults(suiteName: "ramguard.uitour") ?? .standard
        suite.removePersistentDomain(forName: "ramguard.uitour")
        suite.set(1200.0, forKey: SettingsStore.thresholdKey)
        let settings = SettingsStore(defaults: suite)
        let history = HistoryStore()
        seedHistory(history)

        // Real memory numbers keep the panel copy believable.
        let memory = (try? MemoryPressure.read()) ?? MemoryPressure(availableMiB: 2450, freePages: 0, speculativePages: 0, swap: nil)
        let available = max(memory.availableMiB, 1800)
        let samples: [Double] = (0..<60).map { i in
            available + sin(Double(i) / 5.5) * 260 + Double(i) * 2.0
        }

        var failures = 0

        // --- Panel: one render per tab ------------------------------------
        let panel = PopoverPanelController(settings: settings, history: history, exclusions: exclusions)
        _ = panel.view
        panel.apply(state: PopoverPanelController.PanelState(
            availableMiB: available,
            thresholdMiB: 1200,
            posture: .observe,
            triggered: false,
            lastEventName: nil,
            lastEventWasKill: false,
            swap: memory.swap,
            history: samples
        ))
        panel.prepareForOpen()
        let panelSize = panel.preferredContentSize
        // Host the panel in a real (floating) window so AppKit runs the full
        // display lifecycle and every backing layer gets contents before the
        // offscreen rasterization.
        let panelWindow = NSWindow(
            contentRect: NSRect(x: 60, y: 120, width: panelSize.width, height: panelSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panelWindow.isReleasedWhenClosed = false
        panelWindow.level = .floating
        panelWindow.backgroundColor = .windowBackgroundColor
        panelWindow.contentView = panel.view
        panelWindow.orderFrontRegardless()
        pump(0.6)
        let tabArtifacts = ["apps", "threshold", "history"]
        for (index, name) in tabArtifacts.enumerated() {
            panel.showTab(index, animated: false)
            panel.view.layoutSubtreeIfNeeded()
            pump(0.5) // let the ring/bar animations settle at their final values
            if writeSnapshot(of: panel.view, to: outputDirectoryURL.appendingPathComponent("qa-ui3-panel-\(name).png")) == false {
                failures += 1
            }
        }
        panelWindow.orderOut(nil)

        // --- Welcome --------------------------------------------------------
        let welcome = WelcomeWindowController()
        welcome.show()
        pump(0.4)
        if let contentView = welcome.window?.contentView {
            contentView.wantsLayer = true
            contentView.appearance = NSAppearance(named: .darkAqua)
            if writeSnapshot(of: contentView, to: outputDirectoryURL.appendingPathComponent("qa-ui3-welcome.png")) == false {
                failures += 1
            }
        }
        welcome.window?.performClose(nil)

        // --- History window --------------------------------------------------
        let historyWindow = HistoryWindowController(store: history)
        historyWindow.show()
        pump(0.4)
        if let contentView = historyWindow.window?.contentView {
            contentView.wantsLayer = true
            contentView.appearance = NSAppearance(named: .darkAqua)
            if writeSnapshot(of: contentView, to: outputDirectoryURL.appendingPathComponent("qa-ui3-history.png")) == false {
                failures += 1
            }
        }
        historyWindow.window?.performClose(nil)

        print("uitour: wrote \(tabArtifacts.count + 2) artifacts to \(outputDirectoryURL.path)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func seedHistory(_ store: HistoryStore) {
        let now = Date()
        store.append(HistoryEvent(kind: .kill, pid: 4213, name: "bomb", footprintKiB: 2_845_120, reason: "", timestamp: now.addingTimeInterval(-540)))
        store.append(HistoryEvent(kind: .cooldownSuppressed, pid: 4213, name: "bomb", footprintKiB: 2_845_120, reason: "", timestamp: now.addingTimeInterval(-480)))
        store.append(HistoryEvent(kind: .wouldKill, pid: 887, name: "Whale Helper (Renderer)", footprintKiB: 1_420_880, reason: "", timestamp: now.addingTimeInterval(-300)))
        store.append(HistoryEvent(kind: .noCandidate, pid: nil, name: nil, footprintKiB: nil, reason: "", timestamp: now.addingTimeInterval(-120)))
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Rasterizes a laid-out layer-backed view at 2x into a PNG-ready rep,
    /// through a raw CG bitmap context (layer coordinates are y-down).
    private static func snapshot(_ view: NSView, scale: CGFloat = 2) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        CATransaction.flush()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1, let layer = view.layer else { return nil }
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard let cg = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        cg.setAllowsAntialiasing(true)
        cg.setShouldAntialias(true)
        // render(in:) draws in the context's own (y-up) coordinates, same as
        // AppKit drawing — only scaling is needed, no flip.
        cg.scaleBy(x: scale, y: scale)
        layer.render(in: cg)
        guard let image = cg.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    private static func writeSnapshot(of view: NSView, to url: URL) -> Bool {
        guard let rep = snapshot(view) else {
            print("uitour: FAILED to render \(url.lastPathComponent)")
            return false
        }
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("uitour: FAILED to encode \(url.lastPathComponent)")
            return false
        }
        do {
            try data.write(to: url)
            print("uitour: \(url.path)")
            return true
        } catch {
            print("uitour: FAILED to write \(url.path): \(error)")
            return false
        }
    }
}
