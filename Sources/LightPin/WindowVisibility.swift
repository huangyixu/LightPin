import Foundation

enum WindowVisibility {
    /// Subtract the union of all foreground opaque window rectangles, including multiple occluders.
    static func visibleIndices(_ frames: [CGRect], within screen: CGRect, opaque: [Bool]? = nil) -> [Int] {
        var covers: [CGRect] = [], result: [Int] = []
        for (index, frame) in frames.enumerated() {
            let clipped = frame.intersection(screen)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            var remaining = [clipped]
            for cover in covers {
                remaining = remaining.flatMap { subtract(cover, from:$0) }
                if remaining.isEmpty { break }
            }
            if !remaining.isEmpty { result.append(index) }
            if opaque?[index] ?? true { covers.append(clipped) }
        }
        return result
    }
    private static func subtract(_ cover: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = rect.intersection(cover)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return [rect] }
        return [CGRect(x:rect.minX,y:rect.minY,width:rect.width,height:overlap.minY-rect.minY),
                CGRect(x:rect.minX,y:overlap.maxY,width:rect.width,height:rect.maxY-overlap.maxY),
                CGRect(x:rect.minX,y:overlap.minY,width:overlap.minX-rect.minX,height:overlap.height),
                CGRect(x:overlap.maxX,y:overlap.minY,width:rect.maxX-overlap.maxX,height:overlap.height)]
            .filter { $0.width > 0 && $0.height > 0 }
    }
}
