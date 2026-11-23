import AppKit

/// The alpha silhouette of the window, without its shadow. Coordinates are normalized.
struct WindowOutline {
    let points: [CGPoint]
    let cornerInset: CGFloat
    func path(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: rect.minX+point.x*rect.width, y: rect.minY+point.y*rect.height)
            if index == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close(); return path
    }
    init?(image: CGImage) {
        let w = image.width, h = image.height
        guard w > 2, h > 2 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w*h*4)
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x:0,y:0,width:w,height:h)); return true
        }
        guard rendered else { return nil }
        var left: [CGPoint] = [], right: [CGPoint] = []
        // Restrict edge inspection to corner regions so translucent window contents do not punch holes in the outline.
        let reach = min(w/4,h/4,160)
        for y in 0..<h {
            var l = 0, r = w-1
            if y < reach || y >= h-reach {
                while l < reach && bytes[(y*w+l)*4+3] < 128 { l += 1 }
                while r > w-1-reach && bytes[(y*w+r)*4+3] < 128 { r -= 1 }
            }
            left.append(CGPoint(x:CGFloat(l)/CGFloat(w),y:CGFloat(y)/CGFloat(h)))
            left.append(CGPoint(x:CGFloat(l)/CGFloat(w),y:CGFloat(y+1)/CGFloat(h)))
            right.append(CGPoint(x:CGFloat(r+1)/CGFloat(w),y:CGFloat(y)/CGFloat(h)))
            right.append(CGPoint(x:CGFloat(r+1)/CGFloat(w),y:CGFloat(y+1)/CGFloat(h)))
        }
        points = left + right.reversed()
        cornerInset = max(left.first?.x ?? 0, 1-(right.first?.x ?? 1))
    }
}
