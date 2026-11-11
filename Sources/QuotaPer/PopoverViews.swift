import AppKit
import Combine

private let popoverWidth: CGFloat = 285
private let errorRed = NSColor(red: 0.90, green: 0.28, blue: 0.30, alpha: 1)

private extension NSStackView {
    /// Adds `view` stretched to this stack's width (minus the stack's horizontal insets).
    func addFilled(_ view: NSView) {
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor,
                                    constant: -(edgeInsets.left + edgeInsets.right)).isActive = true
    }
}

// MARK: - Popover content

@MainActor
final class PopoverController: NSViewController {
    private let store: QuotaStore
    private let stack = NSStackView()
    private var subscription: AnyCancellable?
    private var timer: Timer?

    init(store: QuotaStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            root.widthAnchor.constraint(equalToConstant: popoverWidth),
        ])
        view = root
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Live updates while open: data changes, and relative times ("Resets 1h") tick over.
        subscription = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        subscription = nil
        timer?.invalidate()
        timer = nil
    }

    private func render() {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (i, state) in store.states.enumerated() {
            if i > 0 { stack.addFilled(separator()) }
            stack.addFilled(section(state))
        }
        stack.addFilled(separator())
        stack.addFilled(refreshRow())
        stack.addFilled(separator())
        stack.addFilled(MenuRow(title: "Quit QuotaPer") { NSApplication.shared.terminate(nil) })
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: popoverWidth, height: view.fittingSize.height)
    }

    private func refreshRow() -> NSView {
        var trailing: NSView?
        if store.refreshing {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            trailing = spinner
        } else if let t = store.lastUpdate {
            trailing = Pill(text: "Updated \(ago(t))")
        }
        return MenuRow(title: "Refresh", trailing: trailing) { [store] in
            Task { await store.refresh(force: true) }
        }
    }

    private func section(_ state: ProviderState) -> NSView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 10
        s.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)

        let head = NSStackView()
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 1
        head.addArrangedSubview(label(state.id, size: 13, weight: .semibold))
        if let sub = subtitle(state) { head.addArrangedSubview(label(sub, size: 10.5, secondary: true)) }
        s.addFilled(head)

        for w in state.windows { s.addFilled(windowRow(w, dimmed: state.closed)) }

        if let err = state.error {
            let text = "⚠︎ " + (state.isStale ? "\(err) (showing older data)" : err)
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = .systemFont(ofSize: 10.5)
            l.textColor = errorRed
            l.preferredMaxLayoutWidth = popoverWidth - 28
            s.addFilled(l)
        }
        return s
    }

    private func subtitle(_ state: ProviderState) -> String? {
        guard state.closed else { return nil }
        guard !state.windows.isEmpty, let t = state.lastGood else { return "Not running" }
        return "Closed · seen \(ago(t))"
    }

    private func windowRow(_ w: QuotaWindow, dimmed: Bool) -> NSView {
        let title = label(w.title, size: 12)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let value = label("\(Int(w.pct.rounded()))% · Resets \(w.resetShort)", size: 11, secondary: true)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)

        value.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [title, value])
        top.orientation = .horizontal
        top.distribution = .fill
        top.spacing = 8

        let bar = UsageBar(pct: w.pct, color: w.color)
        bar.alphaValue = dimmed ? 0.5 : 1

        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 5
        row.addFilled(top)
        row.addFilled(bar)
        return row
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        let wrap = NSStackView()
        wrap.orientation = .vertical
        wrap.alignment = .leading
        wrap.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 12)
        wrap.addFilled(box)
        return wrap
    }
}

private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                   secondary: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = secondary ? .secondaryLabelColor : .labelColor
    l.lineBreakMode = .byTruncatingTail
    return l
}

// MARK: - Building blocks

final class UsageBar: NSView {
    private let pct: Double
    private let color: NSColor

    init(pct: Double, color: NSColor) {
        self.pct = pct
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 5) }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let radius = h / 2
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let w = max(h, bounds.width * min(max(pct, 0), 100) / 100)
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: radius, yRadius: radius).fill()
    }
}

final class Pill: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        let l = label(text, size: 10.5, weight: .semibold, secondary: true)
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            l.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            l.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
    }
}

/// A clickable menu-style row with a hover highlight.
final class MenuRow: NSView {
    private let action: () -> Void
    private let highlight = NSView()

    init(title: String, trailing: NSView? = nil, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        let titleLabel = label(title, size: 12)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing?.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [titleLabel] + (trailing.map { [$0] } ?? []))
        row.orientation = .horizontal
        row.distribution = .fill
        row.edgeInsets = NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9)
        row.translatesAutoresizingMaskIntoConstraints = false
        highlight.addSubview(row)

        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: highlight.topAnchor),
            row.bottomAnchor.constraint(equalTo: highlight.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: highlight.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: highlight.trailingAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { setHighlighted(true) }
    override func mouseExited(with event: NSEvent) { setHighlighted(false) }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    private func setHighlighted(_ on: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.layer?.backgroundColor = on ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : nil
        }
    }
}
