import CoreGraphics

extension CGFloat {
    /// Rounds toward the nearest pixel for crisp 1x drawing.
    public func pixelAligned(scale: CGFloat = 1) -> CGFloat {
        guard scale > 0 else { return self }
        return (self * scale).rounded() / scale
    }
}

extension CGRect {
    public func pixelAligned(scale: CGFloat = 1) -> CGRect {
        let minX = origin.x.pixelAligned(scale: scale)
        let minY = origin.y.pixelAligned(scale: scale)
        let maxX = (origin.x + size.width).pixelAligned(scale: scale)
        let maxY = (origin.y + size.height).pixelAligned(scale: scale)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension CGPoint {
    public func pixelAligned(scale: CGFloat = 1) -> CGPoint {
        CGPoint(x: x.pixelAligned(scale: scale), y: y.pixelAligned(scale: scale))
    }
}
