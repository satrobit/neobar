import Foundation

/// Spring-loading the drawer for a drag that comes from outside the app (an app bundle dragged
/// from Finder): rest on the capsule → the drawer opens; leave both capsule and drawer → it closes
/// after a short grace; drop anywhere that takes it → it stays open showing where the app landed.
///
/// The bar's own card drags have the same hand-feel in `PanelCoordinator.updateSpringLoad`, driven
/// by `DragController`'s pointer; an AppKit drag session never reaches that pointer, so this one is
/// driven by the two drop receivers' enter / exit instead. Both share the two delays below and the
/// coordinator's two timer slots, so one drawer is never run by two clocks at once.
enum ExternalDragSpringLoad {
    /// Resting on the capsule this long opens the drawer.
    static let openDelay: TimeInterval = 0.4
    /// Being off both capsule and drawer this long closes it (a brush past the bar does not).
    static let closeDelay: TimeInterval = 0.35

    enum Surface: Equatable { case capsule, drawer }

    enum Event: Equatable {
        /// A receiver's targeted state changed. A repeat of the current state is a no-op.
        case hover(Surface, Bool)
        case openTimerFired
        case closeTimerFired
        /// A receiver accepted the drop: the drawer stays as it is.
        case dropped
    }

    enum Effect: Equatable {
        case armOpenTimer, cancelOpenTimer
        case armCloseTimer, cancelCloseTimer
        case openDrawer, closeDrawer
    }

    struct State: Equatable {
        var overCapsule = false
        var overDrawer = false
        var openArmed = false
        var closeArmed = false

        var isOver: Bool { overCapsule || overDrawer }
    }

    /// Applies `event` and returns what the coordinator must do, in order. `drawerOpen` is the
    /// drawer's logical state at the moment of the event, however it was opened.
    static func reduce(_ state: inout State, _ event: Event, drawerOpen: Bool) -> [Effect] {
        var effects: [Effect] = []
        func cancelOpen() { if state.openArmed { state.openArmed = false; effects.append(.cancelOpenTimer) } }
        func cancelClose() { if state.closeArmed { state.closeArmed = false; effects.append(.cancelCloseTimer) } }

        switch event {
        case .hover(let surface, let over):
            switch surface {
            case .capsule:
                guard state.overCapsule != over else { return [] }
                state.overCapsule = over
            case .drawer:
                guard state.overDrawer != over else { return [] }
                state.overDrawer = over
            }
            if state.isOver {
                cancelClose()
                if drawerOpen {
                    cancelOpen()
                } else if state.overCapsule, !state.openArmed {
                    state.openArmed = true
                    effects.append(.armOpenTimer)
                }
            } else {
                cancelOpen()
                if drawerOpen, !state.closeArmed {
                    state.closeArmed = true
                    effects.append(.armCloseTimer)
                }
            }
        case .openTimerFired:
            guard state.openArmed else { return [] }
            state.openArmed = false
            if state.overCapsule, !drawerOpen { effects.append(.openDrawer) }
        case .closeTimerFired:
            guard state.closeArmed else { return [] }
            state.closeArmed = false
            if !state.isOver, drawerOpen { effects.append(.closeDrawer) }
        case .dropped:
            cancelOpen()
            cancelClose()
            state.overCapsule = false
            state.overDrawer = false
        }
        return effects
    }
}
