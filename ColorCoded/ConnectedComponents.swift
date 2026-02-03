import CoreGraphics

struct ConnectedComponent {
    let pixelsCount: Int
    let bbox: CGRect
    let centroid: CGPoint
    let fill: CGFloat
    let aspect: CGFloat
    let eccentricity: CGFloat

    func isLikelyNotehead(spacing: CGFloat) -> Bool {
        let minW = 0.35 * spacing
        let maxW = 1.60 * spacing
        let minH = 0.35 * spacing
        let maxH = 1.80 * spacing
        let area = spacing * spacing
        let minPixels = 0.10 * area
        let maxPixels = 1.60 * area

        if bbox.width < minW || bbox.width > maxW { return false }
        if bbox.height < minH || bbox.height > maxH { return false }
        if CGFloat(pixelsCount) < minPixels || CGFloat(pixelsCount) > maxPixels { return false }
        if fill < 0.18 || fill > 0.85 { return false }
        if aspect < 0.45 || aspect > 2.20 { return false }
        if eccentricity > 5.5 { return false }
        return true
    }
}

enum ConnectedComponents {
    static func extract(from bin: [UInt8],
                        width: Int,
                        height: Int,
                        origin: CGPoint) -> [ConnectedComponent] {
        guard width > 0, height > 0 else { return [] }
        let count = width * height
        guard bin.count >= count else { return [] }

        var visited = [UInt8](repeating: 0, count: count)
        var components: [ConnectedComponent] = []
        components.reserveCapacity(128)

        var queueX: [Int] = []
        var queueY: [Int] = []
        queueX.reserveCapacity(256)
        queueY.reserveCapacity(256)

        func index(_ x: Int, _ y: Int) -> Int { y * width + x }

        for y in 0..<height {
            for x in 0..<width {
                let idx = index(x, y)
                if bin[idx] == 0 || visited[idx] != 0 { continue }

                visited[idx] = 1
                queueX.removeAll(keepingCapacity: true)
                queueY.removeAll(keepingCapacity: true)
                queueX.append(x)
                queueY.append(y)

                var minX = x
                var maxX = x
                var minY = y
                var maxY = y

                var sumX = 0.0
                var sumY = 0.0
                var sumXX = 0.0
                var sumYY = 0.0
                var sumXY = 0.0
                var pixels = 0

                var qIndex = 0
                while qIndex < queueX.count {
                    let cx = queueX[qIndex]
                    let cy = queueY[qIndex]
                    qIndex += 1

                    pixels += 1
                    sumX += Double(cx)
                    sumY += Double(cy)
                    sumXX += Double(cx * cx)
                    sumYY += Double(cy * cy)
                    sumXY += Double(cx * cy)

                    if cx < minX { minX = cx }
                    if cx > maxX { maxX = cx }
                    if cy < minY { minY = cy }
                    if cy > maxY { maxY = cy }

                    for ny in max(0, cy - 1)...min(height - 1, cy + 1) {
                        for nx in max(0, cx - 1)...min(width - 1, cx + 1) {
                            let nidx = index(nx, ny)
                            if bin[nidx] != 0 && visited[nidx] == 0 {
                                visited[nidx] = 1
                                queueX.append(nx)
                                queueY.append(ny)
                            }
                        }
                    }
                }

                guard pixels > 0 else { continue }
                let meanX = sumX / Double(pixels)
                let meanY = sumY / Double(pixels)
                let covXX = (sumXX / Double(pixels)) - meanX * meanX
                let covYY = (sumYY / Double(pixels)) - meanY * meanY
                let covXY = (sumXY / Double(pixels)) - meanX * meanY

                let trace = covXX + covYY
                let det = (covXX * covYY) - (covXY * covXY)
                let temp = max(0.0, (trace * trace) * 0.25 - det)
                let root = sqrt(temp)
                let l1 = max(1e-6, (trace * 0.5) + root)
                let l2 = max(1e-6, (trace * 0.5) - root)
                let ecc = sqrt(max(l1, l2) / max(min(l1, l2), 1e-6))

                let bboxW = maxX - minX + 1
                let bboxH = maxY - minY + 1
                let fill = CGFloat(pixels) / CGFloat(max(1, bboxW * bboxH))
                let aspect = CGFloat(bboxW) / CGFloat(max(1, bboxH))

                let bbox = CGRect(x: origin.x + CGFloat(minX),
                                  y: origin.y + CGFloat(minY),
                                  width: CGFloat(bboxW),
                                  height: CGFloat(bboxH))
                let centroid = CGPoint(x: origin.x + CGFloat(meanX),
                                       y: origin.y + CGFloat(meanY))

                components.append(ConnectedComponent(
                    pixelsCount: pixels,
                    bbox: bbox,
                    centroid: centroid,
                    fill: fill,
                    aspect: aspect,
                    eccentricity: CGFloat(ecc)
                ))
            }
        }

        return components
    }
}
