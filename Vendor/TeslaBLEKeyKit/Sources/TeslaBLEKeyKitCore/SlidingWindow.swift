import Foundation

public struct SlidingWindow {
    private var top: UInt32 = 0
    private var seen: UInt64 = 0
    private let size: UInt32

    public init(size: UInt32 = 32) {
        self.size = min(size, 64)
    }

    @discardableResult
    public mutating func update(_ counter: UInt32) -> Bool {
        if counter > top {
            let shift = counter - top
            if shift >= size {
                seen = 0
            } else {
                seen <<= UInt64(shift)
            }
            seen |= 1
            top = counter
            return true
        }

        let distance = top - counter
        guard distance < size else {
            return false
        }
        let mask = UInt64(1) << UInt64(distance)
        if (seen & mask) != 0 {
            return false
        }
        seen |= mask
        return true
    }
}
