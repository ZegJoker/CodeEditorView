import Foundation

/// Values stored in a ``RangeStore`` must be equatable for run coalescing.
public protocol RangeStoreElement: Equatable, Sendable {}

extension Optional: RangeStoreElement where Wrapped: RangeStoreElement {}
