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
