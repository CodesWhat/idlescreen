import CoreGraphics

/// Keeps the renderer surface at the selected display's aspect ratio while
/// treating the fixed navigation rail and divider as window chrome.
enum IdleScreenPreviewWindowGeometry {
    static let navigationRailWidth: CGFloat = 80
    static let navigationDividerWidth: CGFloat = 1
    static let leadingChromeWidth = navigationRailWidth
        + navigationDividerWidth
    static let absoluteMinimumContentSize = CGSize(width: 900, height: 600)

    static func minimumContentSize(
        previewAspectRatio: CGFloat
    ) -> CGSize {
        guard validAspectRatio(previewAspectRatio) else {
            return absoluteMinimumContentSize
        }
        let minimumHeight = max(
            absoluteMinimumContentSize.height,
            (absoluteMinimumContentSize.width - leadingChromeWidth)
                / previewAspectRatio
        )
        return CGSize(
            width: minimumHeight * previewAspectRatio + leadingChromeWidth,
            height: minimumHeight
        )
    }

    static func constrainedContentSize(
        proposed: CGSize,
        current: CGSize,
        previewAspectRatio: CGFloat
    ) -> CGSize {
        guard validSize(proposed),
              validSize(current),
              validAspectRatio(previewAspectRatio) else {
            return normalizedContentSize(
                current: current,
                previewAspectRatio: previewAspectRatio
            )
        }

        let widthDelta = abs(proposed.width - current.width)
            / max(1, current.width)
        let heightDelta = abs(proposed.height - current.height)
            / max(1, current.height)
        let candidate: CGSize
        if widthDelta >= heightDelta {
            let width = max(leadingChromeWidth + 1, proposed.width)
            candidate = CGSize(
                width: width,
                height: (width - leadingChromeWidth) / previewAspectRatio
            )
        } else {
            let height = max(1, proposed.height)
            candidate = CGSize(
                width: height * previewAspectRatio + leadingChromeWidth,
                height: height
            )
        }
        return boundedMinimum(
            candidate,
            previewAspectRatio: previewAspectRatio
        )
    }

    static func normalizedContentSize(
        current: CGSize,
        previewAspectRatio: CGFloat
    ) -> CGSize {
        let minimum = minimumContentSize(
            previewAspectRatio: previewAspectRatio
        )
        guard validSize(current),
              validAspectRatio(previewAspectRatio) else {
            return minimum
        }
        let width = max(minimum.width, current.width)
        return boundedMinimum(
            CGSize(
                width: width,
                height: (width - leadingChromeWidth) / previewAspectRatio
            ),
            previewAspectRatio: previewAspectRatio
        )
    }

    private static func boundedMinimum(
        _ candidate: CGSize,
        previewAspectRatio: CGFloat
    ) -> CGSize {
        let minimum = minimumContentSize(
            previewAspectRatio: previewAspectRatio
        )
        guard candidate.width >= minimum.width,
              candidate.height >= minimum.height else {
            return minimum
        }
        return candidate
    }

    private static func validAspectRatio(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0
    }

    private static func validSize(_ value: CGSize) -> Bool {
        value.width.isFinite && value.height.isFinite
            && value.width > 0 && value.height > 0
    }
}
