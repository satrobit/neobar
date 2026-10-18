import CoreGraphics

enum AccessoryWindowPresentation {
    static func repairedFrame(
        windowFrame: CGRect,
        titlebarHeight: CGFloat,
        visibleFrames: [CGRect],
        preferredVisibleFrame: CGRect?,
        isFirstPresentation: Bool
    ) -> CGRect? {
        guard !visibleFrames.isEmpty else { return nil }
        let target = targetFrame(
            windowFrame: windowFrame,
            visibleFrames: visibleFrames,
            preferredVisibleFrame: preferredVisibleFrame,
            preferExplicit: isFirstPresentation
        )

        let size = CGSize(
            width: min(windowFrame.width, target.width),
            height: min(windowFrame.height, target.height)
        )
        if isFirstPresentation {
            return centeredFrame(size: size, in: target)
        }

        let titlebar = CGRect(
            x: windowFrame.minX,
            y: windowFrame.maxY - max(1, titlebarHeight),
            width: windowFrame.width,
            height: max(1, titlebarHeight)
        )
        let minimumReachableHeight = min(max(1, titlebarHeight), 16)
        let titlebarReachable = visibleFrames.contains {
            titlebar.intersection($0).height >= minimumReachableHeight
        }
        let intersectsAnyScreen = visibleFrames.contains { windowFrame.intersects($0) }
        let fitsTarget = windowFrame.width <= target.width && windowFrame.height <= target.height
        if titlebarReachable && intersectsAnyScreen && fitsTarget { return nil }

        return clampedFrame(origin: windowFrame.origin, size: size, in: target)
    }

    private static func targetFrame(
        windowFrame: CGRect,
        visibleFrames: [CGRect],
        preferredVisibleFrame: CGRect?,
        preferExplicit: Bool
    ) -> CGRect {
        if preferExplicit, let preferredVisibleFrame,
           visibleFrames.contains(preferredVisibleFrame) {
            return preferredVisibleFrame
        }
        let best = visibleFrames.max {
            intersectionArea(windowFrame, $0) < intersectionArea(windowFrame, $1)
        }
        if let best, intersectionArea(windowFrame, best) > 0 { return best }
        if let preferredVisibleFrame, visibleFrames.contains(preferredVisibleFrame) {
            return preferredVisibleFrame
        }
        return visibleFrames[0]
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func centeredFrame(size: CGSize, in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func clampedFrame(origin: CGPoint, size: CGSize, in bounds: CGRect) -> CGRect {
        CGRect(
            x: min(max(origin.x, bounds.minX), bounds.maxX - size.width),
            y: min(max(origin.y, bounds.minY), bounds.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }
}
