import AppKit

@MainActor
final class HiddenBarController {
    nonisolated static let separatorAutosaveName = StatusItemPersistence.OwnedItem.hiddenBarSeparator.autosaveName
    nonisolated static let toggleAutosaveName = StatusItemPersistence.OwnedItem.hiddenBarToggle.autosaveName

    private let settings: SettingsStore

    private weak var omniButton: NSStatusBarButton?
    private var separatorItem: NSStatusItem?
    private var toggleItem: NSStatusItem?
    private var collapseLength: CGFloat = HiddenBarController.boundedCollapseLength(screenWidth: nil)
    private var collapseSafetyOverrideForTests: CollapseSafety?
    private var hasAttemptedRuntimeRepairThisLaunch = false
    private var onUnsafeOrderingDetected: (() -> Void)?
    private var screenParametersObserver: NSObjectProtocol?

    private let separatorLength: CGFloat = 8
    private let toggleLength: CGFloat = 24

    private var isToggling = false

    private var isCollapsed: Bool {
        settings.hiddenBarIsCollapsed
    }

    private enum CollapseSafety {
        case safe
        case unsafe
        case unknown
    }

    init(settings: SettingsStore) {
        self.settings = settings
    }

    nonisolated static func boundedCollapseLength(screenWidth: CGFloat?) -> CGFloat {
        let resolvedWidth = screenWidth ?? 1728
        return max(500, min(resolvedWidth + 200, 4000))
    }

    nonisolated static func canCollapseSafely(
        omniMinX: CGFloat?,
        separatorMinX: CGFloat?,
        layoutDirection: NSUserInterfaceLayoutDirection
    ) -> Bool {
        collapseSafety(
            toggleMinX: nil,
            omniMinX: omniMinX,
            separatorMinX: separatorMinX,
            layoutDirection: layoutDirection
        ) == .safe
    }

    private nonisolated static func collapseSafety(
        toggleMinX: CGFloat?,
        omniMinX: CGFloat?,
        separatorMinX: CGFloat?,
        layoutDirection: NSUserInterfaceLayoutDirection
    ) -> CollapseSafety {
        guard let omniMinX, let separatorMinX else { return .unknown }
        switch layoutDirection {
        case .rightToLeft:
            guard omniMinX <= separatorMinX else { return .unsafe }
            if let toggleMinX, toggleMinX > separatorMinX { return .unsafe }
            return .safe
        default:
            guard omniMinX >= separatorMinX else { return .unsafe }
            if let toggleMinX, toggleMinX < separatorMinX { return .unsafe }
            return .safe
        }
    }

    func bind(omniButton: NSStatusBarButton, onUnsafeOrderingDetected: @escaping () -> Void) {
        self.omniButton = omniButton
        self.onUnsafeOrderingDetected = onUnsafeOrderingDetected
        updateCollapseLength()
    }

    func setup() {
        guard separatorItem == nil else { return }

        // Two owned items: a fixed-width clickable toggle and an expanding
        // separator. On collapse the separator expands to push items into
        // overflow; the toggle and main item must sit on the surviving side to
        // stay visible. Required order is not enforced automatically: if the
        // user drags them into an unsafe arrangement, collapseSafety refuses
        // and the repair path rebuilds.
        let ownedToggleItem = NSStatusBar.system.statusItem(withLength: toggleLength)
        StatusItemPersistence.configureMandatoryItem(ownedToggleItem, as: .hiddenBarToggle)
        toggleItem = ownedToggleItem
        setupToggle()

        let ownedSeparatorItem = NSStatusBar.system.statusItem(withLength: separatorLength)
        StatusItemPersistence.configureMandatoryItem(ownedSeparatorItem, as: .hiddenBarSeparator)
        separatorItem = ownedSeparatorItem
        setupSeparator()

        installScreenParametersObserverIfNeeded()
        updateCollapseLength()

        if settings.hiddenBarIsCollapsed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.collapse()
            }
        }
    }

    private func setupToggle() {
        guard let button = toggleItem?.button else { return }
        button.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Toggle Hidden Bar")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(toggleClicked)
        button.sendAction(on: [.leftMouseUp])
    }

    @objc private func toggleClicked() {
        toggle()
    }

    private func setupSeparator() {
        guard let button = separatorItem?.button else { return }
        button.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Separator")
        button.image?.isTemplate = true
        button.appearsDisabled = true
    }

    func toggle() {
        guard !isToggling else { return }
        isToggling = true

        guard separatorItem != nil else {
            settings.hiddenBarIsCollapsed.toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isToggling = false
            }
            return
        }

        if isCollapsed {
            expand()
        } else {
            collapse()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isToggling = false
        }
    }

    private func collapse() {
        applyCollapseSafety(collapseSafety(), repairUnknownOrdering: true)
    }

    private func expand() {
        guard isCollapsed else { return }

        separatorItem?.length = separatorLength
        settings.hiddenBarIsCollapsed = false
    }

    func cleanup() {
        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
            screenParametersObserver = nil
        }
        if let item = separatorItem {
            NSStatusBar.system.removeStatusItem(item)
            separatorItem = nil
        }
        if let item = toggleItem {
            NSStatusBar.system.removeStatusItem(item)
            toggleItem = nil
        }
        omniButton = nil
        onUnsafeOrderingDetected = nil
    }

    func separatorAutosaveNameForTests() -> String? {
        separatorItem?.autosaveName
    }

    func separatorIsVisibleForTests() -> Bool? {
        separatorItem?.isVisible
    }

    func updateCollapseLengthForTests() {
        updateCollapseLength()
    }

    func runPersistedCollapseSafetyCheckForTests() {
        collapse()
    }

    func setCollapseSafetyForTests(
        toggleMinX: CGFloat? = nil,
        omniMinX: CGFloat?,
        separatorMinX: CGFloat?,
        layoutDirection: NSUserInterfaceLayoutDirection
    ) {
        collapseSafetyOverrideForTests = Self.collapseSafety(
            toggleMinX: toggleMinX,
            omniMinX: omniMinX,
            separatorMinX: separatorMinX,
            layoutDirection: layoutDirection
        )
    }

    private func updateCollapseLength() {
        collapseLength = Self.boundedCollapseLength(screenWidth: currentScreenWidth())
        guard isCollapsed, separatorItem != nil else { return }

        applyCollapseSafety(collapseSafety(), repairUnknownOrdering: false)
    }

    private func applyCollapseSafety(_ safety: CollapseSafety, repairUnknownOrdering: Bool) {
        switch safety {
        case .safe:
            separatorItem?.length = collapseLength
            settings.hiddenBarIsCollapsed = true
        case .unsafe:
            settings.hiddenBarIsCollapsed = false
            requestRuntimeRepairIfNeeded()
        case .unknown:
            if repairUnknownOrdering {
                settings.hiddenBarIsCollapsed = false
                requestRuntimeRepairIfNeeded()
            }
        }
    }

    private func currentScreenWidth() -> CGFloat? {
        omniButton?.window?.screen?.frame.width ??
            separatorItem?.button?.window?.screen?.frame.width ??
            NSScreen.main?.frame.width
    }

    private func collapseSafety() -> CollapseSafety {
        if let collapseSafetyOverrideForTests {
            return collapseSafetyOverrideForTests
        }

        let layoutDirection = NSApp?.userInterfaceLayoutDirection ?? .leftToRight
        return Self.collapseSafety(
            toggleMinX: toggleItem?.button?.window?.frame.minX,
            omniMinX: omniButton?.window?.frame.minX,
            separatorMinX: separatorItem?.button?.window?.frame.minX,
            layoutDirection: layoutDirection
        )
    }

    private func requestRuntimeRepairIfNeeded() {
        guard !hasAttemptedRuntimeRepairThisLaunch else { return }
        hasAttemptedRuntimeRepairThisLaunch = true
        onUnsafeOrderingDetected?()
    }

    private func installScreenParametersObserverIfNeeded() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCollapseLength()
            }
        }
    }
}
