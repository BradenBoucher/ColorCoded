import Foundation
import CoreGraphics

enum BinaryNoiseCleaner {
    static func clean(binary: [UInt8], width: Int, height: Int, spacing: CGFloat) -> [UInt8] {
        guard width > 0, height > 0, binary.count == width * height else { return binary }
        var out = binary
        out = removeIsolatedPixels(binary: out, width: width, height: height)
        out = removeSmallComponents(binary: out, width: width, height: height, spacing: spacing)
        return out
    }

    private static func removeIsolatedPixels(binary: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = binary
        guard width > 2, height > 2 else { return out }

        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let idx = row + x
                guard out[idx] != 0 else { continue }
                var neighbors = 0
                for yy in (y - 1)...(y + 1) {
                    let nRow = yy * width
                    for xx in (x - 1)...(x + 1) where !(xx == x && yy == y) {
                        if out[nRow + xx] != 0 { neighbors += 1 }
                    }
                }
                if neighbors <= 1 {
                    out[idx] = 0
                }
            }
        }
        return out
    }

    private static func removeSmallComponents(binary: [UInt8],
                                              width: Int,
                                              height: Int,
                                              spacing: CGFloat) -> [UInt8] {
        var out = binary
        let areaLimit = max(10, Int((spacing * 0.45) * (spacing * 0.45)))
        var visited = [UInt8](repeating: 0, count: width * height)
        var stack: [Int] = []
        stack.reserveCapacity(256)

        func visit(_ start: Int) {
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = 1
            var component: [Int] = []
            component.reserveCapacity(64)

            while let idx = stack.popLast() {
                component.append(idx)
                let x = idx % width
                let y = idx / width
                let x0 = max(0, x - 1)
                let x1 = min(width - 1, x + 1)
                let y0 = max(0, y - 1)
                let y1 = min(height - 1, y + 1)
                for yy in y0...y1 {
                    let row = yy * width
                    for xx in x0...x1 {
                        let nIdx = row + xx
                        if visited[nIdx] == 0 && out[nIdx] != 0 {
                            visited[nIdx] = 1
                            stack.append(nIdx)
                        }
                    }
                }
            }

            if component.count <= areaLimit {
                for idx in component { out[idx] = 0 }
            }
        }

        for idx in 0..<(width * height) where out[idx] != 0 && visited[idx] == 0 {
            visit(idx)
        }

        return out
    }
}
