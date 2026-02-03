import CoreGraphics

struct DirectionalStrokeMask {
    let origin: CGPoint
    let width: Int
    let height: Int
    let verticalMask: [UInt8]
    let horizontalMask: [UInt8]
    let diagMask: [UInt8]
    let combinedMask: [UInt8]

    static func build(from bin: [UInt8],
                      pageWidth: Int,
                      pageHeight: Int,
                      roi: CGRect,
                      spacing: CGFloat) -> DirectionalStrokeMask {
        let roiInt = roi.intersection(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        let x0 = max(0, Int(floor(roiInt.minX)))
        let y0 = max(0, Int(floor(roiInt.minY)))
        let x1 = min(pageWidth, Int(ceil(roiInt.maxX)))
        let y1 = min(pageHeight, Int(ceil(roiInt.maxY)))

        let w = max(0, x1 - x0)
        let h = max(0, y1 - y0)
        let count = w * h

        var vertical = [UInt8](repeating: 0, count: count)
        var horizontal = [UInt8](repeating: 0, count: count)
        var diagonal = [UInt8](repeating: 0, count: count)

        let minRunV = max(3, Int(spacing * 0.65))
        let minRunH = max(4, Int(spacing * 0.80))
        let minRunD = max(3, Int(spacing * 0.60))
        let maxGap = 2

        func binAt(_ localX: Int, _ localY: Int) -> UInt8 {
            let px = x0 + localX
            let py = y0 + localY
            return bin[py * pageWidth + px]
        }

        func markRun(_ indices: [Int], axisMark: (Int) -> Void, minRun: Int) {
            guard indices.count >= minRun else { return }
            for idx in indices { axisMark(idx) }
        }

        // Vertical scans
        if w > 0 && h > 0 {
            for x in 0..<w {
                var run: [Int] = []
                var gap = 0
                for y in 0..<h {
                    if binAt(x, y) != 0 {
                        run.append(y)
                        gap = 0
                    } else if !run.isEmpty {
                        gap += 1
                        if gap > maxGap {
                            markRun(run, axisMark: { yy in vertical[yy * w + x] = 1 }, minRun: minRunV)
                            run.removeAll(keepingCapacity: true)
                            gap = 0
                        }
                    }
                }
                markRun(run, axisMark: { yy in vertical[yy * w + x] = 1 }, minRun: minRunV)
            }

            // Horizontal scans
            for y in 0..<h {
                var run: [Int] = []
                var gap = 0
                let row = y * w
                for x in 0..<w {
                    if binAt(x, y) != 0 {
                        run.append(x)
                        gap = 0
                    } else if !run.isEmpty {
                        gap += 1
                        if gap > maxGap {
                            markRun(run, axisMark: { xx in horizontal[row + xx] = 1 }, minRun: minRunH)
                            run.removeAll(keepingCapacity: true)
                            gap = 0
                        }
                    }
                }
                markRun(run, axisMark: { xx in horizontal[row + xx] = 1 }, minRun: minRunH)
            }
        }

        func diagMaskWrite(x: Int, y: Int) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            diagonal[y * w + x] = 1
        }

        // Diagonal scans (top-left to bottom-right)
        if w > 0 && h > 0 {
            for startX in 0..<w {
                var run: [Int] = []
                var gap = 0
                var x = startX
                var y = 0
                var step = 0
                while x < w && y < h {
                    if binAt(x, y) != 0 {
                        run.append(step)
                        gap = 0
                    } else if !run.isEmpty {
                        gap += 1
                        if gap > maxGap {
                            markRun(run, axisMark: { s in
                                let mx = startX + s
                                let my = s
                                diagMaskWrite(x: mx, y: my)
                            }, minRun: minRunD)
                            run.removeAll(keepingCapacity: true)
                            gap = 0
                        }
                    }
                    x += 1
                    y += 1
                    step += 1
                }
                markRun(run, axisMark: { s in
                    let mx = startX + s
                    let my = s
                    diagMaskWrite(x: mx, y: my)
                }, minRun: minRunD)
            }

            for startY in 1..<h {
                var run: [Int] = []
                var gap = 0
                var x = 0
                var y = startY
                var step = 0
                while x < w && y < h {
                    if binAt(x, y) != 0 {
                        run.append(step)
                        gap = 0
                    } else if !run.isEmpty {
                        gap += 1
                        if gap > maxGap {
                            markRun(run, axisMark: { s in
                                let mx = s
                                let my = startY + s
                                diagMaskWrite(x: mx, y: my)
                            }, minRun: minRunD)
                            run.removeAll(keepingCapacity: true)
                            gap = 0
                        }
                    }
                    x += 1
                    y += 1
                    step += 1
                }
                markRun(run, axisMark: { s in
                    let mx = s
                    let my = startY + s
                    diagMaskWrite(x: mx, y: my)
                }, minRun: minRunD)
            }

            // Diagonal scans (top-right to bottom-left)
            for startX in 0..<w {
                var run: [Int] = []
                var gap = 0
                var x = startX
                var y = 0
                var step = 0
                while x >= 0 && x < w && y < h {
                    if binAt(x, y) != 0 {
                        run.append(step)
                        gap = 0
                    } else if !run.isEmpty {
                        gap += 1
                        if gap > maxGap {
                            markRun(run, axisMark: { s in
                                let mx = startX - s
                                let my = s
                                diagMaskWrite(x: mx, y: my)
                            }, minRun: minRunD)
                            run.removeAll(keepingCapacity: true)
                            gap = 0
                        }
                    }
                    x -= 1
                    y += 1
                    step += 1
                }
                markRun(run, axisMark: { s in
                    let mx = startX - s
                    let my = s
                    diagMaskWrite(x: mx, y: my)
                }, minRun: minRunD)
            }

            if w > 1 {
                for startY in 1..<h {
                    var run: [Int] = []
                    var gap = 0
                    var x = w - 1
                    var y = startY
                    var step = 0
                    while x >= 0 && y < h {
                        if binAt(x, y) != 0 {
                            run.append(step)
                            gap = 0
                        } else if !run.isEmpty {
                            gap += 1
                            if gap > maxGap {
                                markRun(run, axisMark: { s in
                                    let mx = (w - 1) - s
                                    let my = startY + s
                                    diagMaskWrite(x: mx, y: my)
                                }, minRun: minRunD)
                                run.removeAll(keepingCapacity: true)
                                gap = 0
                            }
                        }
                        x -= 1
                        y += 1
                        step += 1
                    }
                    markRun(run, axisMark: { s in
                        let mx = (w - 1) - s
                        let my = startY + s
                        diagMaskWrite(x: mx, y: my)
                    }, minRun: minRunD)
                }
            }
        }

        var combined = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            combined[i] = (vertical[i] | horizontal[i] | diagonal[i])
        }

        return DirectionalStrokeMask(
            origin: CGPoint(x: x0, y: y0),
            width: w,
            height: h,
            verticalMask: vertical,
            horizontalMask: horizontal,
            diagMask: diagonal,
            combinedMask: combined
        )
    }
}
