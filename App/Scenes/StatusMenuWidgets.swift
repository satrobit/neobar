import AppKit

// Custom NSView components in the status bar menu (slider row / confirm row / button / endpoint dot / tracking slider).
// Moved out of StatusMenuController.swift on 2026-09-05: a pure move, zero behavior change.

private enum StatusMenuLayout {
    static let textInsetX: CGFloat = 28
    static let trailingInsetX: CGFloat = 14
}

/// Draft ledger for the system Dock slider. It remembers the value from **before the change**, but only uses it to decide "did it actually change":
/// which tier to roll back to when a write fails is decided by `SettingsCoordinator.applyNativeDock` itself re-reading the system's true value
/// (the starting point the UI holds may have been changed by ⌥⌘D while the draft sat open; see the comment there).
///
/// The only commit source is the confirm row (the slider itself never writes the system automatically), and the **atomic** semantics of `consume()` are the key:
/// it serves as two gates at once, "don't write if the value didn't change" and "don't write if there is no starting point", and repeated calls always get nil.
struct PreferenceSliderCommitTracker {
    private var baseline: Double?
    private var pending: Double?

    var hasPending: Bool { pending != nil }

    /// Record the draft's starting point. Within one round of adjustment only the first call counts; repeated calls midway don't overwrite it (they fire repeatedly during a drag).
    mutating func begin(currentDelay: Double) {
        if baseline == nil { baseline = currentDelay }
    }

    mutating func stage(_ value: Double) {
        pending = value
    }

    /// Atomically take out the value to commit. No starting point, no change, or already consumed by someone else → nil.
    mutating func consume() -> (previous: Double, target: Double)? {
        defer {
            baseline = nil
            pending = nil
        }
        guard let baseline, let pending, baseline != pending else { return nil }
        return (baseline, pending)
    }
}


@MainActor
final class PreferenceSliderMenuItemView: NSView {
    /// Every tier change. Slider types that take effect immediately (NeoBar, local value) write the store directly here.
    var onDelayChange: ((Double) -> Void)?
    /// Draft settled (mouse released, or each keyboard step). Confirm-type sliders use it to refresh the confirm row;
    /// **it must never be used to write any persistent state**: the whole point of a draft is "not yet in effect".
    var onDraftChange: ((Double) -> Void)?
    /// Confirm commit. **Setting it enables the draft mechanism**: every write to the system Dock ends with `killall Dock`,
    /// so the screen necessarily flickers once, and that flicker may only happen after the user actively confirms.
    var onDelayCommit: ((_ target: Double) -> Void)?

    /// Small-text color of the selected end: the accent color **with a bit of transparency** (owner, 2026-08-03).
    /// The solid dot stays at full strength and the small text is one notch weaker: the dot is the primary marker and the text is its echo.
    /// Don't apply this transparency to font weight: bolding changes the label width and makes the text at both ends jump left and right.
    static let activeEndpointColor = NSColor.controlAccentColor.withAlphaComponent(0.7)

    /// Small-text color of the unselected end. **All four use sites must reference it** (one each for
    /// left and right in the initializer + one each for left and right in `updateDisplay`); when scattered
    /// as four literals, missing one only shows when "dragging to the endpoint and then back".
    /// Darkened one step from the third-level label color to this on 2026-09-01 (the owner found the whole thing too gray).
    /// The hollow stroke of the endpoint **dots** doesn't follow along: that is a graphic, not text.
    static let inactiveEndpointColor = NSColor.secondaryLabelColor

    /// The user has moved the slider and hasn't committed yet. Check it when re-reading the system's true value after the menu is shown: the dragging hand must not be jumped.
    var hasDraft: Bool { commitTracker.hasPending }

    private let accessibilityTitle: String
    private var delay = 0.0
    private var commitTracker = PreferenceSliderCommitTracker()
    private var displayString = "0.0s"
    private let leftEndpointDot = EndpointDotView()
    private let rightEndpointDot = EndpointDotView()
    private let delayLabel = NSTextField(labelWithString: "")
    // The small endpoint labels are only 34pt wide (see sliderSideInset in layout()); they are tick marks, not tier names:
    // the full tier name is shown by the large text in the middle row (delayLabel ← delayDisplayName), which has ~190pt.
    // So English uses short words: measured, "Always Visible" is 62.5pt at 9pt font and doesn't fit in 34pt.
    private let leftEndpointLabel = NSTextField(labelWithString: String(localized: "Always"))
    private let rightEndpointLabel = NSTextField(labelWithString: String(localized: "Never"))
    private let slider = MenuTrackingSlider()

    init(accessibilityTitle: String) {
        self.accessibilityTitle = accessibilityTitle
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        autoresizingMask = [.width]
        configureSubviews()
        updateDisplay()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityValue() -> Any? {
        displayString
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let width = window?.frame.width, width > frame.width {
            frame.size.width = width
        }
    }

    func sync(delay: Double) {
        let index = AppSettingsStore.sliderIndexFromDelay(delay)
        self.delay = AppSettingsStore.delayFromSliderIndex(index)
        slider.integerValue = index
        updateDisplay()
    }

    private func configureSubviews() {
        wantsLayer = true

        leftEndpointDot.setAccessibilityElement(false)
        addSubview(leftEndpointDot)

        rightEndpointDot.setAccessibilityElement(false)
        addSubview(rightEndpointDot)

        delayLabel.font = .systemFont(ofSize: 11)
        delayLabel.textColor = .secondaryLabelColor
        delayLabel.alignment = .center
        addSubview(delayLabel)

        leftEndpointLabel.font = .systemFont(ofSize: 9)
        leftEndpointLabel.textColor = Self.inactiveEndpointColor
        leftEndpointLabel.alignment = .center
        leftEndpointLabel.setAccessibilityElement(false)
        addSubview(leftEndpointLabel)

        rightEndpointLabel.font = .systemFont(ofSize: 9)
        rightEndpointLabel.textColor = Self.inactiveEndpointColor
        rightEndpointLabel.alignment = .center
        rightEndpointLabel.setAccessibilityElement(false)
        addSubview(rightEndpointLabel)

        slider.minValue = 0
        slider.maxValue = Double(AppSettingsStore.sliderIndexMax)
        slider.integerValue = AppSettingsStore.sliderIndexFromDelay(delay)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.onTrackingStarted = { [weak self] in
            guard let self else { return }
            self.commitTracker.begin(currentDelay: self.delay)
        }
        slider.onTrackingEnded = { [weak self] in
            // Never touch the confirm row during the whole drag: adding/removing a menu item at every tier crossed would make the whole menu re-layout repeatedly.
            // Refresh only once, on release.
            guard let self else { return }
            self.onDraftChange?(self.delay)
        }
        addSubview(slider)

        setAccessibilityRole(.group)
    }

    override func layout() {
        super.layout()
        let dotSize: CGFloat = 8
        let contentX = StatusMenuLayout.textInsetX
        let contentWidth = bounds.width - contentX - StatusMenuLayout.trailingInsetX
        let labelY: CGFloat = 28
        let sliderY: CGFloat = 10

        let sliderSideInset: CGFloat = 34
        let sliderX = contentX + sliderSideInset
        let sliderWidth = max(0, contentWidth - sliderSideInset * 2)
        delayLabel.frame = NSRect(x: sliderX, y: labelY, width: sliderWidth, height: 14)

        let dotY = sliderY + 6
        leftEndpointDot.frame = NSRect(x: contentX + 14, y: dotY, width: dotSize, height: dotSize)
        slider.frame = NSRect(x: sliderX, y: sliderY, width: sliderWidth, height: 20)
        rightEndpointDot.frame = NSRect(x: slider.frame.maxX + 12, y: dotY, width: dotSize, height: dotSize)
        leftEndpointLabel.frame = NSRect(x: contentX, y: labelY, width: sliderSideInset, height: 14)
        rightEndpointLabel.frame = NSRect(x: slider.frame.maxX, y: labelY, width: sliderSideInset, height: 14)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let index = min(max(Int(sender.doubleValue.rounded()), 0), AppSettingsStore.sliderIndexMax)
        sender.integerValue = index
        let previousDelay = delay
        delay = AppSettingsStore.delayFromSliderIndex(index)
        updateDisplay()
        onDelayChange?(delay)

        guard onDelayCommit != nil else { return }
        // Keyboard / VoiceOver adjustments don't go through mouseDown and have no tracking start, so add one here
        // (on the mouse path, begin has already been called by onTrackingStarted; repeated calls don't overwrite the starting point).
        commitTracker.begin(currentDelay: previousDelay)
        commitTracker.stage(delay)
        // Keyboard / VoiceOver have no "release" moment, so the confirm row can only be refreshed on the spot. They therefore take
        // the same confirmation path as the mouse, no longer need a debounced auto-commit, and so are no longer silently dropped.
        if !slider.isMouseTracking {
            onDraftChange?(delay)
        }
    }

    /// The user presses the confirm row. The **only** commit entry: the slider itself never writes the system under any circumstances.
    func commitDraft() {
        guard let commit = commitTracker.consume() else { return }
        onDelayCommit?(commit.target)
    }

    /// Discard the unconfirmed draft and set the slider back to the effective value from before the draft began.
    /// The call site is **when the menu opens** (`menuWillOpen`), not when it closes; see the reason there.
    /// If it was already consumed by `commitDraft`, it gets nil and won't set the just-confirmed new value back.
    func discardDraft() {
        guard let discarded = commitTracker.consume() else { return }
        sync(delay: discarded.previous)
    }

    private func updateDisplay() {
        let index = slider.integerValue
        displayString = displayString(for: index)
        delay = AppSettingsStore.delayFromSliderIndex(index)
        delayLabel.stringValue = displayString
        // The small texts at the two ends, "Always On / Don't Wake", are always visible; when selected the dot turns solid and **the small text is tinted with the accent color at the same time**
        // (owner, 2026-08-03: the dot alone wasn't noticeable enough). **Only change color, don't bold**: bolding would change this row's
        // layout width and make the labels at both ends jump left and right.
        // When the middle value text reaches an endpoint it is hidden, to avoid showing the same word twice with the always-visible endpoint small text.
        let isAtLeftEnd = index == 0
        let isAtRightEnd = index == AppSettingsStore.sliderIndexMax
        delayLabel.isHidden = isAtLeftEnd || isAtRightEnd
        leftEndpointDot.isOn = isAtLeftEnd
        rightEndpointDot.isOn = isAtRightEnd
        leftEndpointLabel.textColor = isAtLeftEnd ? Self.activeEndpointColor : Self.inactiveEndpointColor
        rightEndpointLabel.textColor = isAtRightEnd ? Self.activeEndpointColor : Self.inactiveEndpointColor
        setAccessibilityLabel("\(accessibilityTitle)，\(displayString)")
        setAccessibilityValue(displayString)
        slider.displayString = displayString
    }

    /// Share one tier convention with the confirm row, so what the confirm row says is never different from what the slider shows.
    private func displayString(for index: Int) -> String {
        AutoHideToggleMenuModel.delayDisplayName(sliderIndex: index)
    }
}

/// Taskbar height row: Small — slider — Large. Live while the mouse is down: every whole point
/// goes out through `onHeightChange`, bracketed by `onEditingChanged` so the bars resize inside
/// one height-resize transaction (`size-tiers.md`).
@MainActor
final class TaskbarSizeMenuItemView: NSView {
    var onEditingChanged: ((Bool) -> Void)?
    var onHeightChange: ((DockPanelHeight) -> Void)?

    private let smallLabel = NSTextField(labelWithString: String(localized: "Small"))
    private let largeLabel = NSTextField(labelWithString: String(localized: "Large"))
    private let slider = MenuTrackingSlider()

    init(accessibilityTitle: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        autoresizingMask = [.width]

        for label in [smallLabel, largeLabel] {
            label.font = .systemFont(ofSize: 9)
            label.textColor = PreferenceSliderMenuItemView.inactiveEndpointColor
            label.alignment = .center
            label.setAccessibilityElement(false)
            addSubview(label)
        }

        slider.minValue = Double(DockPanelHeight.minimum)
        slider.maxValue = Double(DockPanelHeight.maximum)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.onTrackingStarted = { [weak self] in self?.onEditingChanged?(true) }
        slider.onTrackingEnded = { [weak self] in self?.onEditingChanged?(false) }
        slider.setAccessibilityLabel(accessibilityTitle)
        addSubview(slider)
        sync(height: .default)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let width = window?.frame.width, width > frame.width {
            frame.size.width = width
        }
    }

    func sync(height: DockPanelHeight) {
        slider.doubleValue = Double(height.points)
        slider.displayString = "\(Int(height.points))"
    }

    override func layout() {
        super.layout()
        let contentX = StatusMenuLayout.textInsetX
        let contentWidth = bounds.width - contentX - StatusMenuLayout.trailingInsetX
        // 34pt lines the track up with the wake sliders above; longer words (es `Pequeño`)
        // widen both slots instead of clipping.
        let labelWidth = max(smallLabel.intrinsicContentSize.width, largeLabel.intrinsicContentSize.width)
        let sideInset = max(34, ceil(labelWidth) + 6)
        let sliderY = (bounds.height - 20) / 2
        slider.frame = NSRect(x: contentX + sideInset, y: sliderY, width: max(0, contentWidth - sideInset * 2), height: 20)
        let labelY = (bounds.height - 12) / 2
        smallLabel.frame = NSRect(x: contentX, y: labelY, width: sideInset, height: 12)
        largeLabel.frame = NSRect(x: slider.frame.maxX, y: labelY, width: sideInset, height: 12)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let height = DockPanelHeight(clamping: CGFloat(sender.doubleValue))
        slider.displayString = "\(Int(height.points))"
        onHeightChange?(height)
    }
}

/// Confirm button row for the system Dock slider. Making it a **button** rather than an ordinary menu text row is deliberate:
/// a menu row has the same visual weight as its neighbors, and the user's eyes are still on the slider right after dragging it, so the whole row is easy to miss;
/// once missed, the menu just closes, and the result is "thought it was set but it never took effect", which is worse than the original flicker.
/// The button's form itself says "this is something to click".
///
/// The small gray text on the left is not decoration: the `killall Dock` flicker can't be eliminated, and explaining it up front keeps it from looking odd.
@MainActor
final class NativeDockApplyRowView: NSView {
    var onApply: (() -> Void)?

    private let hintLabel = NSTextField(labelWithString: String(localized: "The Dock will restart"))
    private let applyButton = MenuActionButton(title: String(localized: "Apply"))

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 42))
        autoresizingMask = [.width]
        configureSubviews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The button title is always "Apply" and the target tier is conveyed only through accessibility: the slider already shows the tier,
    /// but VoiceOver users can't hear the slider, so this line is their only source of information.
    func updateTarget(description: String) {
        applyButton.setAccessibilityLabel(description)
        setAccessibilityLabel(description)
    }

    /// Start from the resting state every time it pops out: the last round may have stopped in the hover state, and when the menu reopens the mouse isn't necessarily still on the button.
    func resetInteractionState() {
        applyButton.resetInteractionState()
    }

    private func configureSubviews() {
        wantsLayer = true

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.setAccessibilityElement(false)
        addSubview(hintLabel)

        applyButton.onClick = { [weak self] in
            self?.onApply?()
        }
        addSubview(applyButton)

        setAccessibilityRole(.group)
    }

    override func layout() {
        super.layout()
        let contentX = StatusMenuLayout.textInsetX
        let rightEdge = bounds.width - StatusMenuLayout.trailingInsetX

        let buttonSize = applyButton.intrinsicContentSize
        applyButton.frame = NSRect(
            x: rightEdge - buttonSize.width,
            y: (bounds.height - buttonSize.height) / 2,
            width: buttonSize.width,
            height: buttonSize.height
        )

        let hintWidth = max(0, applyButton.frame.minX - 8 - contentX)
        hintLabel.frame = NSRect(x: contentX, y: (bounds.height - 14) / 2, width: hintWidth, height: 14)
    }

}

/// Accent button in the menu, **custom drawn**.
///
/// I tried `NSButton`: once `bezelColor` is set to change the fill to the accent color, AppKit's own
/// press-darkening is largely covered up; and while the menu is open the run loop is in event-tracking mode,
/// and the standard button's hover / pressed states are unreliable here: pressing it feels like a dead image (owner, 2026-08-02: "why does the button have no feedback / interaction").
/// With custom drawing, all three states are fully controllable: rest / hover (brighten) / pressed (darken).
final class MenuActionButton: NSView {
    var onClick: (() -> Void)?

    private let title: String
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private var isHovering = false { didSet { if isHovering != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }

    private static let cornerRadius: CGFloat = 6
    private static let horizontalPadding: CGFloat = 12
    private static let iconTitleGap: CGFloat = 5
    private static let height: CGFloat = 25

    /// Translucent rather than solid (owner's call, 2026-08-02): the menu itself is a translucent material, and laying a solid accent fill
    /// on it looks thick and heavy. Changed to a light accent fill + accent text: the color is still there, the weight is reduced.
    private static let restingAlpha: CGFloat = 0.16
    private static let hoverAlpha: CGFloat = 0.30
    private static let pressedAlpha: CGFloat = 0.42

    init(title: String) {
        self.title = title
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 92, height: Self.height))
        wantsLayer = true

        // Regular font weight (owner's call, 2026-08-02); the text takes the accent color itself rather than white:
        // white text needs a solid fill to stand up, and on a translucent fill only accent-colored text is clear enough.
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .controlAccentColor
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)

        iconView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        iconView.contentTintColor = .controlAccentColor
        iconView.setAccessibilityElement(false)
        addSubview(iconView)

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let titleWidth = titleLabel.intrinsicContentSize.width
        let iconWidth = iconView.image?.size.width ?? 0
        return NSSize(
            width: Self.horizontalPadding * 2 + iconWidth + Self.iconTitleGap + titleWidth,
            height: Self.height
        )
    }

    /// A custom view in the menu doesn't belong to the key window, and without overriding this the first click is swallowed entirely:
    /// the user would think the button is broken. `MenuTrackingSlider` is the same.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Subviews (text, icon) must not intercept mouse events, otherwise the middle of the button can't be clicked.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    func resetInteractionState() {
        isHovering = false
        isPressed = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.activeAlways`: the menu panel isn't the key window, and `.activeInKeyWindow` never fires here.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// During menu event tracking `mouseUp` doesn't naturally come back here, so we must run a round of tracking ourselves:
    /// this is the same reasoning as `MenuTrackingSlider` blocking in `super.mouseDown` until release.
    /// During it we track whether the pointer is inside the button: dragging out and then releasing = cancel, consistent with system buttons.
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        var releasedInside = true

        window?.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { trackedEvent, stop in
            guard let trackedEvent else {
                stop.pointee = true
                return
            }
            let local = self.convert(trackedEvent.locationInWindow, from: nil)
            releasedInside = self.bounds.contains(local)
            self.isPressed = releasedInside
            if trackedEvent.type == .leftMouseUp {
                stop.pointee = true
            }
        }

        isPressed = false
        isHovering = releasedInside
        if releasedInside {
            onClick?()
        }
    }

    /// Unit test entry: the real path is the tracking loop above, and the test environment can't run an event loop.
    func performClickForTesting() {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The three states only change opacity, not hue: the fill is always the same accent color, and pressing just makes it "more solid".
        let alpha: CGFloat
        if isPressed {
            alpha = Self.pressedAlpha
        } else if isHovering {
            alpha = Self.hoverAlpha
        } else {
            alpha = Self.restingAlpha
        }
        let shape = NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
        shape.fill()
    }

    override func layout() {
        super.layout()
        let iconSize = iconView.image?.size ?? .zero
        let titleSize = titleLabel.intrinsicContentSize
        let contentWidth = iconSize.width + Self.iconTitleGap + titleSize.width
        let startX = (bounds.width - contentWidth) / 2

        iconView.frame = NSRect(
            x: startX,
            y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )
        titleLabel.frame = NSRect(
            x: iconView.frame.maxX + Self.iconTitleGap,
            y: (bounds.height - titleSize.height) / 2,
            width: titleSize.width,
            height: titleSize.height
        )
    }
}

final class EndpointDotView: NSView {
    var isOn = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(ovalIn: rect)
        (isOn ? NSColor.controlAccentColor : .clear).setFill()
        path.fill()
        (isOn ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

final class MenuTrackingSlider: NSSlider {
    var displayString = "0.0s"
    var onTrackingStarted: (() -> Void)?
    var onTrackingEnded: (() -> Void)?
    /// `mouseDown` doesn't return during the whole drag, so this flag is the accurate answer to "is this currently a mouse drag",
    /// used to route the keyboard / accessibility path to the debounced commit.
    private(set) var isMouseTracking = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isMouseTracking = true
        onTrackingStarted?()
        super.mouseDown(with: event)
        isMouseTracking = false
        onTrackingEnded?()
    }

    override func accessibilityValue() -> Any? {
        displayString
    }
}
