import CoreGraphics

enum BinaryConnectedComponents {
    struct Scratch {
        var visited: [UInt8] = []
        var stack: [Int] = []
    }

    struct Component {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
        let area: Int
        let sumX: Int
        let sumY: Int

        var rect: CGRect {
            CGRect(
                x: minX,
                y: minY,
                width: max(1, maxX - minX + 1),
                height: max(1, maxY - minY + 1)
            )
        }
    }

    static func label(
        binary: [UInt8],
        width: Int,
        height: Int,
        roi: CGRect? = nil,
        scratch: inout Scratch
    ) -> [Component] {
        guard width > 0, height > 0, binary.count >= width * height else { return [] }

        let roiRect = roi?.integral ?? CGRect(x: 0, y: 0, width: width, height: height)
        let x0 = max(0, Int(roiRect.minX))
        let y0 = max(0, Int(roiRect.minY))
        let x1 = min(width, Int(roiRect.maxX))
        let y1 = min(height, Int(roiRect.maxY))
        if x1 <= x0 || y1 <= y0 { return [] }

        let roiArea = max(1, (x1 - x0) * (y1 - y0))
        let maxComponentArea = Int(Double(roiArea) * 0.05)
        let hugeArea = Int(Double(roiArea) * 0.20)

        if scratch.visited.count != width * height {
            scratch.visited = [UInt8](repeating: 0, count: width * height)
        }
        for y in y0..<y1 {
            let row = y * width
            scratch.visited.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                let start = row + x0
                base.advanced(by: start).update(repeating: 0, count: x1 - x0)
            }
        }
        var components: [Component] = []
        components.reserveCapacity(256)

        scratch.stack.removeAll(keepingCapacity: true)
        scratch.stack.reserveCapacity(1024)
        for y in y0..<y1 {
            let rowStart = y * width
            for x in x0..<x1 {
                let idx = rowStart + x
                if binary[idx] == 0 || scratch.visited[idx] != 0 { continue }

                scratch.visited[idx] = 1
                scratch.stack.removeAll(keepingCapacity: true)
                scratch.stack.append(idx)

                var minX = x
                var maxX = x
                var minY = y
                var maxY = y
                var area = 0
                var sumX = 0
                var sumY = 0
                var tooLarge = false

                while let current = scratch.stack.popLast() {
                    let cy = current / width
                    let cx = current - (cy * width)

                    area += 1
                    if area > maxComponentArea {
                        tooLarge = true
                        break
                    }

                    sumX += cx
                    sumY += cy
                    if cx < minX { minX = cx }
                    if cx > maxX { maxX = cx }
                    if cy < minY { minY = cy }
                    if cy > maxY { maxY = cy }

                    let ny0 = max(y0, cy - 1)
                    let ny1 = min(y1 - 1, cy + 1)
                    let nx0 = max(x0, cx - 1)
                    let nx1 = min(x1 - 1, cx + 1)

                    for ny in ny0...ny1 {
                        let nRow = ny * width
                        for nx in nx0...nx1 {
                            let nIdx = nRow + nx
                            if scratch.visited[nIdx] != 0 { continue }
                            if binary[nIdx] == 0 { continue }
                            scratch.visited[nIdx] = 1
                            scratch.stack.append(nIdx)
                        }
                    }
                }

                if tooLarge { continue }

                let compWidth = maxX - minX + 1
                let compHeight = maxY - minY + 1
                if area < 6 || compWidth < 2 || compHeight < 2 { continue }

                if compWidth > Int(Double(width) * 0.9),
                   compHeight > Int(Double(height) * 0.05) {
                    continue
                }
                if area > hugeArea { continue }

                components.append(
                    Component(
                        minX: minX,
                        minY: minY,
                        maxX: maxX,
                        maxY: maxY,
                        area: area,
                        sumX: sumX,
                        sumY: sumY
                    )
                )
            }
        }

        return components
    }

    static func label(
        binary: [UInt8],
        width: Int,
        height: Int,
        roi: CGRect? = nil
    ) -> [Component] {
        var scratch = Scratch()
        return label(binary: binary, width: width, height: height, roi: roi, scratch: &scratch)
    }
}
