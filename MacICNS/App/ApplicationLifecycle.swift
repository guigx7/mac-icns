import AppKit

@MainActor
final class ApplicationLifecycleController {
    typealias SetActivationPolicy = (NSApplication.ActivationPolicy) -> Bool

    private let setActivationPolicy: SetActivationPolicy

    init(
        setActivationPolicy: @escaping SetActivationPolicy = {
            NSApplication.shared.setActivationPolicy($0)
        }
    ) {
        self.setActivationPolicy = setActivationPolicy
    }

    func showApplication() {
        _ = setActivationPolicy(.regular)
    }

    func windowsDidChange(hasVisibleWindows: Bool) {
        _ = setActivationPolicy(hasVisibleWindows ? .regular : .accessory)
    }
}

@MainActor
final class MacICNSApplicationDelegate: NSObject, NSApplicationDelegate {
    let lifecycleController: ApplicationLifecycleController
    private let visibleWindowProvider: () -> Bool

    override init() {
        self.lifecycleController = ApplicationLifecycleController()
        self.visibleWindowProvider = {
            NSApplication.shared.windows.contains { window in
                window.isVisible && !window.isMiniaturized && !(window is NSPanel)
            }
        }
        super.init()
    }

    init(
        lifecycleController: ApplicationLifecycleController,
        visibleWindowProvider: @escaping () -> Bool
    ) {
        self.lifecycleController = lifecycleController
        self.visibleWindowProvider = visibleWindowProvider
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowVisibilityDidChange),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowVisibilityDidChange),
            name: NSWindow.didDeminiaturizeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowVisibilityDidChange),
            name: NSWindow.didMiniaturizeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    @objc private func windowVisibilityDidChange(_ notification: Notification) {
        synchronizeWindowVisibility()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.synchronizeWindowVisibility()
        }
    }

    private func synchronizeWindowVisibility() {
        lifecycleController.windowsDidChange(
            hasVisibleWindows: visibleWindowProvider()
        )
    }
}
