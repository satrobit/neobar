import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · Space (desktop) related: repair of the membership that keeps panels on all desktops (issue #19) and pinning into the private space.
// Split out of PanelCoordinator.swift as an extension on 2026-09-05; moved only, not changed.
extension PanelCoordinator {
    /// Read back the membership and restore panels that "should be on all desktops but are actually left on only the current one".
    ///
    /// For the mechanism and why only this one shape works, see `AllSpacesMembership`. None of these three things here can be omitted:
    /// (1) read back before deciding whether to act -- zero side effects when healthy; (2) the value change must be assigned back after one runloop turn,
    /// since changing it back within the same turn is the same as not changing it; (3) read again after assigning back, since a **single repair is not guaranteed to succeed**.
    func repairAllSpacesMembershipIfNeeded(attempt: Int = 1) {
        guard Self.spaceMembershipRepairEnabled, !isSuspendedForPermissionLoss else { return }
        if attempt == 1 && spaceMembershipRepairInFlight { return }
        guard let dock = dockPanel else { return }
        // A panel pinned into the private space is not on any desktop, and this repair would treat it as having "lost membership" and clear and reassign it repeatedly;
        // so repair only those not pinned (when the host is unavailable = all of them, same behavior as before).
        let repairCandidates = allSpacesPanels.filter { panel in
            !(overlaySpaceHost?.isPinned(windowNumber: panel.windowNumber) ?? false)
        }
        guard !repairCandidates.isEmpty else {
            spaceMembershipRepairInFlight = false
            return
        }

        guard let uuid = DisplayIdentity.uuidString(for: panelCurrentScreen(panel: dock)),
              let layout = ManagedSpaceLayoutReader.layout(forDisplayUUID: uuid) else {
            spaceMembershipRepairInFlight = false
            return
        }
        let desktops = layout.orderedSpaceIDs.filter { !layout.fullscreenSpaceIDs.contains($0) }

        let broken = repairCandidates.filter { panel in
            guard let owned = WindowSpaceMembershipReader.spaceIDs(forWindowNumber: panel.windowNumber)
            else { return false }   // can't read = don't know; must not be treated as "lost"
            return !AllSpacesMembership.missingSpaceIDs(
                windowSpaceIDs: owned,
                desktopSpaceIDs: desktops
            ).isEmpty
        }
        guard !broken.isEmpty else {
            if attempt > 1 {
                logger.info("[space-membership] repaired attempts=\(attempt - 1, privacy: .public)")
            }
            spaceMembershipRepairInFlight = false
            return
        }
        guard AllSpacesMembership.shouldRetry(attempt: attempt - 1) else {
            logger.error("[space-membership] give up after \(attempt - 1, privacy: .public) attempts")
            spaceMembershipRepairInFlight = false
            return
        }

        spaceMembershipRepairInFlight = true
        for panel in broken { panel.collectionBehavior = [] }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for panel in broken { panel.collectionBehavior = PanelCollectionBehavior.standard }
            DispatchQueue.main.asyncAfter(deadline: .now() + AllSpacesMembership.verifyDelay) { [weak self] in
                self?.repairAllSpacesMembershipIfNeeded(attempt: attempt + 1)
            }
        }
    }

    // MARK: - Pin persistent panels into the private space (so the base doesn't turn gray when sliding between desktops)

    /// Pin the taskbar / glass base / capsule into the process's one private space. For the mechanism and measured boundaries see `OverlaySpaceHost`.
    func pinResidentPanelsIfNeeded() {
        guard let host = overlaySpaceHost, !isSuspendedForPermissionLoss else { return }
        let windowNumbers = allSpacesPanels.map(\.windowNumber)
        guard !windowNumbers.isEmpty else { return }
        if !host.pin(windowNumbers: windowNumbers) {
            logger.error("[overlay-space] pin failed windows=\(windowNumbers, privacy: .public)")
        }
    }

    /// Transient panels (drawer / popup / name bubble) **must also be pinned into the same space** -- they all overlap the extent of the taskbar's windows
    ///(including the 20pt transparent shadow edge), and windows left in the desktop space are composited **below** the private space regardless of `level`:
    /// the drawer's bottom row pressed into the capsule window's shadow edge goes dark, and brightens again when the launch bounce lifts it (owner 2026-09-03,
    /// confirmed by the `DOCK_OVERLAY_SPACE=0` A/B). Pin once more after each order front; for one already pinned it's just a cheap read-back.
    func pinOverlappingPanelIfNeeded(_ panel: NSPanel) {
        guard let host = overlaySpaceHost, !isSuspendedForPermissionLoss, panel.windowNumber > 0 else { return }
        if !host.pin(windowNumbers: [panel.windowNumber]) {
            logger.error("[overlay-space] pin failed window=\(panel.windowNumber, privacy: .public)")
        }
    }
}
