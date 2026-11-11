import AppKit
import Combine
import Darwin

@main
@MainActor
enum Main {
    private static let delegate = AppDelegate()   // NSApplication only keeps a weak reference

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Status item + popover. The popover's views exist only while it is open, so an idle QuotaPer
/// keeps no view hierarchy in memory.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = QuotaStore()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var iconSubscription: AnyCancellable?
    private var shownProgress: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        iconSubscription = store.$states.sink { [weak self] _ in self?.updateIcon() }
        updateIcon()
    }

    private func updateIcon() {
        let progress = store.iconProgress
        let key = progress.map { Int(($0 * 100).rounded()) }
        guard key != shownProgress || statusItem.button?.image == nil else { return }
        shownProgress = key
        statusItem.button?.image = ringIcon(progress: progress)
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        popover.contentViewController = PopoverController(store: store)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil   // free all the views
        // Ask malloc to hand the now-unused pages back to the system.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = malloc_zone_pressure_relief(nil, 0) }
    }
}
