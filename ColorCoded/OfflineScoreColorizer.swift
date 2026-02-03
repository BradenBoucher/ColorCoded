import Foundation
import PDFKit
@preconcurrency import Vision
import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum OfflineScoreColorizer {
    private static let debugStrokeErase = true

    private struct StrokeCleanResult {
        let image: PlatformImage
        let binary: [UInt8]
        let width: Int
        let height: Int
        let strokeMask: [UInt8]
        let protectMask: [UInt8]
    }

    private struct DebugMaskData {
        let strokeMask: [UInt8]
        let protectMask: [UInt8]
        let width: Int
        let height: Int
    }

    private static var debugMaskData: DebugMaskData?
    private enum RejectTuning {
        static let ledgerRunFrac: Double = 0.70
        static let ledgerFillMax: Double = 0.12
        static let tailFillMax: Double = 0.10
        static let tailAsymMin: Double = 0.55
        static let axisRatioMin: Double = 3.2
        static let overlapExpandedMin: Double = 0.22
    }

    private struct PatchMetrics {
        let fillRatio: Double
        let centerRowMaxRunFrac: Double
        let lrAsymmetry: Double
    }

    enum ColorizeError: LocalizedError {
        case cannotOpenPDF
        case cannotRenderPage
        case cannotWriteOutput

        var errorDescription: String? {
            switch self {
            case .cannotOpenPDF: return "Could not open the PDF."
            case .cannotRenderPage: return "Could not render one of the pages."
            case .cannotWriteOutput: return "Could not write the output PDF."
            }
        }
    }

    static func colorizePDF(inputURL: URL) async throws -> URL {
        guard let doc = PDFDocument(url: inputURL) else { throw ColorizeError.cannotOpenPDF }

        let outDoc = PDFDocument()

        for pageIndex in 0..<doc.pageCount {
            try await withCheckedThrowingContinuation { continuation in
                autoreleasepool {
                    guard let page = doc.page(at: pageIndex) else {
                        continuation.resume(returning: ())
                        return
                    }

                    guard let image = render(page: page, scale: 2.0) else {
                        continuation.resume(throwing: ColorizeError.cannotRenderPage)
                        return
                    }

                    Task {
                        let staffModel = await StaffDetector.detectStaff(in: image)
                        let systems = SystemDetector.buildSystems(from: staffModel, imageSize: image.size)

                        let baseImage = image
                        let strokeClean = await buildStrokeCleanedImage(
                            baseImage: baseImage,
                            staffModel: staffModel,
                            systems: systems
                        )
                        let cleanedImage = strokeClean?.image
                        if debugStrokeErase {
                            print("StrokeErase cleanedImage used: \(cleanedImage != nil)")
                        }
                        if cleanedImage == nil {
                            debugMaskData = nil
                        }

                        // High recall note candidates
                        let detection = await NoteheadDetector.detectDebug(in: cleanedImage ?? baseImage)

                        // Barlines
                        let barlines = image.cgImageSafe.map { BarlineDetector.detectBarlines(in: $0, systems: systems) } ?? []

                        let filtered = filterNoteheadsHighRecall(
                            detection.noteRects,
                            systems: systems,
                            barlines: barlines,
                            fallbackSpacing: staffModel?.lineSpacing ?? 12.0,
                            cgImage: image.cgImageSafe,
                            binaryOverride: strokeClean.map { ($0.binary, $0.width, $0.height) }
                        )

                        let colored = drawOverlays(
                            on: image,
                            staff: staffModel,
                            noteheads: filtered,
                            barlines: barlines
                        )

                        if let pdfPage = PDFPage(image: colored) {
                            outDoc.insert(pdfPage, at: outDoc.pageCount)
                        }
                        continuation.resume(returning: ())
                    }
                }
            }
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("colored-offline-\(UUID().uuidString).pdf")

        guard outDoc.write(to: outURL) else { throw ColorizeError.cannotWriteOutput }
        return outURL
    }

    // MARK: - Render PDF page

    private static func render(page: PDFPage, scale: CGFloat) -> PlatformImage? {
        #if canImport(UIKit)
        let bounds = page.bounds(for: .mediaBox)

        let maxLongSide: CGFloat = 2200
        let baseW = bounds.width
        let baseH = bounds.height

        var s = scale
        let longSide = max(baseW, baseH) * s
        if longSide > maxLongSide {
            s *= (maxLongSide / longSide)
        }
        s = max(1.0, s)

        let size = CGSize(width: baseW * s, height: baseH * s)

        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1.0

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            ctx.cgContext.saveGState()
            ctx.cgContext.scaleBy(x: s, y: s)

            ctx.cgContext.translateBy(x: 0, y: bounds.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)

            page.draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
        #else
        return nil
        #endif
    }

    // MARK: - Stroke erasing (pre-contour cleanup)

    private static func buildStrokeCleanedImage(baseImage: PlatformImage,
                                                staffModel: StaffModel?,
                                                systems: [SystemBlock]) async -> StrokeCleanResult? {
        guard let cg = baseImage.cgImageSafe, !systems.isEmpty else { return nil }
        let spacing = max(6.0, staffModel?.lineSpacing ?? 12.0)

        let rawCandidates = await NoteheadDetector.detectNoteheads(in: baseImage)

        return buildStrokeCleanedImage(
            cgImage: cg,
            spacing: spacing,
            systems: systems,
            protectRects: rawCandidates
        )
    }

    private static func buildStrokeCleanedImage(cgImage: CGImage,
                                                spacing: CGFloat,
                                                systems: [SystemBlock],
                                                protectRects: [CGRect]) -> StrokeCleanResult? {
        let (bin, w, h) = buildBinaryInkMap(from: cgImage, lumThreshold: 175)
        var binary = bin

        var protectMask = [UInt8](repeating: 0, count: w * h)
        var strokeMask = [UInt8](repeating: 0, count: w * h)
        let u = max(7.0, spacing)
        let minDim = 0.35 * u
        let maxDim = 1.8 * u

        let vMasks = systems.map { system in
            VerticalStrokeMask.build(from: bin, width: w, height: h, roi: system.bbox, minRun: max(3, Int((spacing * 0.80).rounded())))
        }

        for rect in protectRects {
            guard rect.width >= minDim, rect.height >= minDim else { continue }
            guard rect.width <= maxDim, rect.height <= maxDim else { continue }
            let expanded = rect.insetBy(dx: -0.20 * u, dy: -0.20 * u)
            if shouldProtectRect(rect: rect,
                                 expanded: expanded,
                                 binary: bin,
                                 pageW: w,
                                 pageH: h,
                                 vMasks: vMasks,
                                 systems: systems,
                                 spacing: spacing) {
                markMask(&protectMask, rect: expanded, width: w, height: h)
            }
        }

        for (idx, system) in systems.enumerated() {
            let before = countInk(in: binary, width: w, height: h, rect: system.bbox)
            let result = VerticalStrokeEraser.eraseStrokes(
                binary: binary,
                width: w,
                height: h,
                systemRect: system.bbox,
                spacing: spacing,
                protectMask: protectMask
            )
            binary = result.binaryWithoutStrokes
            mergeMask(&strokeMask, with: result.strokeMask)
            let after = countInk(in: binary, width: w, height: h, rect: system.bbox)
            if debugStrokeErase {
                let delta = before - after
                print("StrokeErase system \(idx): before=\(before) after=\(after) Δ=\(delta)")
            }
        }

        guard let cleanedCG = buildBinaryCGImage(from: binary, width: w, height: h) else { return nil }
        guard let image = makePlatformImage(from: cleanedCG) else { return nil }
        if debugStrokeErase {
            print("StrokeErase cleanedImage base=\(cgImage.width)x\(cgImage.height) cleaned=\(cleanedCG.width)x\(cleanedCG.height)")
        }
        debugMaskData = DebugMaskData(strokeMask: strokeMask, protectMask: protectMask, width: w, height: h)
        return StrokeCleanResult(image: image, binary: binary, width: w, height: h, strokeMask: strokeMask, protectMask: protectMask)
    }

    private static func markMask(_ mask: inout [UInt8], rect: CGRect, width: Int, height: Int) {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clipped.width > 0, clipped.height > 0 else { return }
        let x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        let x1 = min(width, Int(ceil(clipped.maxX)))
        let y1 = min(height, Int(ceil(clipped.maxY)))
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 {
                mask[row + x] = 1
            }
        }
    }

    private static func mergeMask(_ mask: inout [UInt8], with addition: [UInt8]) {
        guard !addition.isEmpty, mask.count == addition.count else { return }
        for i in 0..<mask.count where addition[i] != 0 {
            mask[i] = 1
        }
    }

    private static func countInk(in binary: [UInt8], width: Int, height: Int, rect: CGRect) -> Int {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clipped.width > 0, clipped.height > 0 else { return 0 }
        let x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        let x1 = min(width, Int(ceil(clipped.maxX)))
        let y1 = min(height, Int(ceil(clipped.maxY)))
        var count = 0
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 {
                if binary[row + x] != 0 { count += 1 }
            }
        }
        return count
    }

    private static func shouldProtectRect(rect: CGRect,
                                          expanded: CGRect,
                                          binary: [UInt8],
                                          pageW: Int,
                                          pageH: Int,
                                          vMasks: [VerticalStrokeMask?],
                                          systems: [SystemBlock],
                                          spacing: CGFloat) -> Bool {
        let u = max(7.0, spacing)
        let expandedRect = expanded.insetBy(dx: -0.30 * u, dy: -0.15 * u)
        let overlap = bestOverlap(rect: expandedRect, vMasks: vMasks, systems: systems)
        if overlap >= 0.12 { return false }

        let pca = lineLikenessPCA(rect, bin: binary, pageW: pageW, pageH: pageH)
        if pca.eccentricity >= 3.8 { return false }

        let fill = rectInkExtent(rect, bin: binary, pageW: pageW, pageH: pageH)
        if fill <= 0.12 { return false }

        return true
    }

    private static func bestOverlap(rect: CGRect,
                                    vMasks: [VerticalStrokeMask?],
                                    systems: [SystemBlock]) -> CGFloat {
        var best: CGFloat = 0
        for (idx, system) in systems.enumerated() {
            guard system.bbox.intersects(rect), let mask = vMasks[idx] else { continue }
            best = max(best, mask.overlapRatio(with: rect))
        }
        return best
    }

    private static func buildBinaryCGImage(from binary: [UInt8], width: Int, height: Int) -> CGImage? {
        guard binary.count == width * height else { return nil }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = y * width
            let rowRGBA = y * width * 4
            for x in 0..<width {
                let idx = row + x
                if binary[idx] != 0 {
                    let rgbaIdx = rowRGBA + x * 4
                    rgba[rgbaIdx] = 0
                    rgba[rgbaIdx + 1] = 0
                    rgba[rgbaIdx + 2] = 0
                    rgba[rgbaIdx + 3] = 255
                }
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }

    private static func makePlatformImage(from cgImage: CGImage) -> PlatformImage? {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return nil
        #endif
    }

    // MARK: - Filtering (high recall, targeted noise suppression)

    private static func filterNoteheadsHighRecall(_ noteheads: [CGRect],
                                                  systems: [SystemBlock],
                                                  barlines: [CGRect],
                                                  fallbackSpacing: CGFloat,
                                                  cgImage: CGImage?,
                                                  binaryOverride: ([UInt8], Int, Int)?) -> [CGRect] {
        guard !noteheads.isEmpty else { return [] }

        // If systems not found, only do dedupe (avoid losing notes)
        guard !systems.isEmpty else {
            return DuplicateSuppressor.suppress(noteheads, spacing: fallbackSpacing)
        }

        // Build binary page once (reused across systems)
        let binaryPage: ([UInt8], Int, Int)? = binaryOverride ?? {
            guard let cgImage else { return nil }
            return buildBinaryInkMap(from: cgImage, lumThreshold: 175)
        }()

        var out: [CGRect] = []
        var consumed = Set<Int>()

        for system in systems {
            let spacing = max(6.0, system.spacing)

            // barline Xs within system (used for penalties + barline veto)
            let barlineXs = barlines
                .filter { $0.maxY >= system.bbox.minY && $0.minY <= system.bbox.maxY }
                .map { $0.midX }

            // Symbol zone (clef/key/time region)
            let symbolZone: CGRect = {
                let bbox = system.bbox
                let baseWidth = max(12.0, spacing * 7.5)

                var zone = CGRect(
                    x: bbox.minX,
                    y: bbox.minY,
                    width: min(baseWidth, bbox.width * 0.33),
                    height: bbox.height
                )

                // Extend to first detected barline if present
                let candidates = barlines.filter { br in
                    br.maxY >= bbox.minY && br.minY <= bbox.maxY &&
                    br.maxX > bbox.minX && br.minX < bbox.maxX
                }
                if let nearest = candidates.min(by: { $0.minX < $1.minX }) {
                    let clampedX = max(bbox.minX, min(nearest.minX, bbox.maxX))
                    zone.size.width = max(zone.width, clampedX - bbox.minX)
                }

                // widen zone a bit to eat left-side clutter
                zone.size.width = min(bbox.width * 0.45, zone.width + spacing * 2.5)

                return zone
            }()

            // Build vertical stroke mask in this system (stems/tails detector)
            let vMask: VerticalStrokeMask? = {
                guard let binaryPage else { return nil }
                let (bin, w, h) = binaryPage

                // More sensitive than before (helps stem fragments)
                let minRun = max(3, Int((spacing * 0.80).rounded()))
                return VerticalStrokeMask.build(from: bin, width: w, height: h, roi: system.bbox, minRun: minRun)
            }()

            // Collect candidates in system bbox
            let systemRects: [CGRect] = noteheads.enumerated().compactMap { idx, r in
                let c = CGPoint(x: r.midX, y: r.midY)
                guard system.bbox.contains(c) else { return nil }
                consumed.insert(idx)
                return r
            }

            // Remove symbol zone only (safe)
            let noSymbols = systemRects.filter { r in
                !symbolZone.contains(CGPoint(x: r.midX, y: r.midY))
            }

            // Staff-step gate
            let scored0 = noSymbols.map { ScoredHead(rect: $0) }
            let gated0 = StaffStepGate.filterCandidates(scored0, system: system)

            // ✅ NEW: compute shapeScore BEFORE clustering/suppression so junk loses
            let gated = gated0.map { head -> ScoredHead in
                var h = head
                guard let binaryPage else { return h }

                let (bin, pageW, pageH) = binaryPage
                let ext = rectInkExtent(h.rect, bin: bin, pageW: pageW, pageH: pageH)
                let colStem = isStemLikeByColumnDominance(h.rect, bin: bin, pageW: pageW, pageH: pageH)

                let ov = vMask?.overlapRatio(with: h.rect) ?? 0
                let pca = lineLikenessPCA(h.rect, bin: bin, pageW: pageW, pageH: pageH)
                let thickness = meanStrokeThickness(h.rect, bin: bin, pageW: pageW, pageH: pageH)

                h.inkExtent = ext
                h.strokeOverlap = ov

                // Shape score: 0..1
                // - Prefer mid fill (noteheads are not empty, not fully solid)
                // - Penalize vertical stroke overlap
                // - Penalize column-stem dominance
                // - Penalize being a thin line (slurs/ties/tails)
                let fillTarget: CGFloat = 0.48
                let fillScore = 1.0 - min(1.0, abs(ext - fillTarget) / 0.40)

                var s: CGFloat = 0
                s += 0.55 * fillScore
                s += 0.25 * (1.0 - min(1.0, ov / 0.35))
                s += 0.20 * (colStem ? 0.0 : 1.0)

                // Line-like penalty (diagonal/curved tails)
                // pca.eccentricity ~ 1 (blob) to large (line)
                // thickness low means stroke-like
                let ecc = pca.eccentricity
                let thin = thickness < max(1.0, spacing * 0.10)
                if ecc > 6.0 && thin {
                    s *= 0.12
                } else if ecc > 4.5 && thin {
                    s *= 0.35
                }

                // Clamp
                h.shapeScore = max(0, min(1, s))
                return h
            }

            // Chord-aware suppression early (now informed by shapeScore)
            let clustered = ClusterSuppressor.suppress(gated, spacing: spacing)

            // ✅ Targeted pruning: remove stems/tails/slurs/flat junk
            let pruned = clustered.filter { head in
                !shouldRejectAsStemOrLine(head,
                                         system: system,
                                         spacing: spacing,
                                         vMask: vMask,
                                         binaryPage: binaryPage,
                                         barlineXs: barlineXs)
            }

            // ✅ Consolidate (stepIndex + X bin) keeps true head, drops duplicates
            let consolidated = consolidateByStepAndX(
                pruned,
                spacing: spacing,
                barlineXs: barlineXs,
                binaryPage: binaryPage
            )

            // Final light dedupe
            let deduped = DuplicateSuppressor.suppress(consolidated, spacing: spacing)
            out.append(contentsOf: deduped)
        }

        // Remaining outside systems: only dedupe (do not drop notes)
        if consumed.count < noteheads.count {
            let remaining = noteheads.enumerated().compactMap { idx, r -> CGRect? in
                guard !consumed.contains(idx) else { return nil }
                return r
            }
            out.append(contentsOf: DuplicateSuppressor.suppress(remaining, spacing: fallbackSpacing))
        }

        return out
    }

    // MARK: - Stem/tail + hanging-line rejection

    /// NOTE: now takes ScoredHead so we can use shapeScore + strokeOverlap consistently.
    private static func shouldRejectAsStemOrLine(_ head: ScoredHead,
                                                system: SystemBlock,
                                                spacing: CGFloat,
                                                vMask: VerticalStrokeMask?,
                                                binaryPage: ([UInt8], Int, Int)?,
                                                barlineXs: [CGFloat]) -> Bool {
        let rect = head.rect
        let w = rect.width
        let h = rect.height
        if w <= 1 || h <= 1 { return true }

        let aspect = w / max(1.0, h)

        let inkExtent = head.inkExtent ?? 0
        let strokeOverlap = head.strokeOverlap ?? (vMask?.overlapRatio(with: rect) ?? 0)

        var colStem = false
        var lineLike = false
        var ecc: Double = 1.0
        var thickness: Double = 999

        if let binaryPage {
            let (bin, pageW, pageH) = binaryPage
            colStem = isStemLikeByColumnDominance(rect, bin: bin, pageW: pageW, pageH: pageH)
            let pca = lineLikenessPCA(rect, bin: bin, pageW: pageW, pageH: pageH)
            ecc = pca.eccentricity
            lineLike = pca.isLineLike
            thickness = meanStrokeThickness(rect, bin: bin, pageW: pageW, pageH: pageH)
        }

        let u = max(7.0, spacing)
        let overlapExpanded = vMask.map {
            let expanded = rect.insetBy(dx: -0.35 * u, dy: -0.20 * u).intersection(system.bbox)
            return Double($0.overlapRatio(with: expanded))
        } ?? 0

        // If something is very notehead-like, be reluctant to reject it.
        // (This protects recall.)
        let strongNotehead = head.shapeScore > 0.72 && strokeOverlap < 0.18 && !colStem

        let ledgerMetrics: PatchMetrics? = {
            guard let binaryPage else { return nil }
            let (bin, pageW, pageH) = binaryPage
            let ledgerRect = rect.insetBy(dx: -0.25 * u, dy: -0.10 * u).intersection(system.bbox)
            return computePatchMetrics(rect: ledgerRect, bin: bin, pageW: pageW, pageH: pageH)
        }()

        if let ledgerMetrics, !strongNotehead {
            if ledgerMetrics.centerRowMaxRunFrac > RejectTuning.ledgerRunFrac,
               ledgerMetrics.fillRatio < RejectTuning.ledgerFillMax {
                return true
            }
        }

        let tailMetrics: PatchMetrics? = {
            guard let binaryPage else { return nil }
            let (bin, pageW, pageH) = binaryPage
            let tailRect = rect.insetBy(dx: -0.20 * u, dy: -0.20 * u).intersection(system.bbox)
            return computePatchMetrics(rect: tailRect, bin: bin, pageW: pageW, pageH: pageH)
        }()

        if let tailMetrics, !strongNotehead {
            let isAsymmetric = tailMetrics.lrAsymmetry > RejectTuning.tailAsymMin
            let isLowFill = tailMetrics.fillRatio < RejectTuning.tailFillMax
            let axisRatioHit = ecc > RejectTuning.axisRatioMin && tailMetrics.fillRatio < 0.18
            let overlapHit = overlapExpanded > RejectTuning.overlapExpandedMin && tailMetrics.fillRatio < 0.20
            if (isLowFill && isAsymmetric) || axisRatioHit || overlapHit {
                return true
            }
        }

        // ------------------------------------------------------------
        // RULE 0) Barline neighborhood veto (kills barline spam)
        // ------------------------------------------------------------
        if !strongNotehead, !barlineXs.isEmpty {
            let cx = rect.midX
            let nearBarline = barlineXs.contains { abs($0 - cx) < spacing * 0.22 }
            if nearBarline {
                let smallish = max(w, h) < spacing * 0.65
                if smallish && (strokeOverlap > 0.04 || colStem || lineLike) { return true }
                let tallish = h > spacing * 0.60
                if tallish && strokeOverlap > 0.06 { return true }
                if colStem { return true }
            }
        }

        // ------------------------------------------------------------
        // RULE 1) Staccato dots (tiny + high fill)
        // ------------------------------------------------------------
        if !strongNotehead {
            let tiny = (w < spacing * 0.30) && (h < spacing * 0.30)
            if tiny && inkExtent > 0.55 { return true }
        }

        // ------------------------------------------------------------
        // RULE 2) Hanging flat fragments away from staff neighborhoods
        // ------------------------------------------------------------
        if !strongNotehead {
            let isVeryFlat = (h < spacing * 0.28) && (w > spacing * 1.10)
            if isVeryFlat {
                let centerY = rect.midY
                let d = minDistanceToAnyStaffLine(y: centerY, system: system)
                if d > spacing * 0.55 { return true }
            }
        }

        // ------------------------------------------------------------
        // RULE 3) Tie/slur-ish: thin + long + line-like (NEW: catches tails)
        // ------------------------------------------------------------
        if !strongNotehead {
            let longish = max(w, h) > spacing * 0.85
            let thinish = min(w, h) < spacing * 0.28
            let lowFill = inkExtent < 0.28

            // thickness in pixels (stroke)
            let thinStroke = thickness < Double(max(1.0, spacing * 0.10))

            // line-like includes diagonal/curved strokes; eccentricity catches it too
            if longish && thinish && lowFill && (lineLike || (ecc > 5.5 && thinStroke)) {
                return true
            }

            // Also reject very line-like even if fill is moderate (anti-aliasing can inflate fill)
            if longish && (lineLike && ecc > 6.5) && thinStroke {
                return true
            }
        }

        // ------------------------------------------------------------
        // RULE 4) Stem/tail kill switch (vertical ladders)
        // ------------------------------------------------------------
        if !strongNotehead {
            if colStem {
                if h > spacing * 0.26 { return true }
            }

            if strokeOverlap > 0.22 && max(w, h) < spacing * 0.60 {
                return true
            }

            let tallEnough = h > spacing * 0.55
            let notWide = aspect < 1.05
            if tallEnough && notWide && strokeOverlap > 0.08 {
                return true
            }

            let somewhatSkinny = aspect < 0.85
            if h > spacing * 0.75 && strokeOverlap > 0.16 && somewhatSkinny {
                return true
            }

            if h > spacing * 1.55 && strokeOverlap > 0.26 {
                return true
            }
        }

        // ------------------------------------------------------------
        // RULE 6) Mid-gap vertical artifacts (between treble/bass)
        // ------------------------------------------------------------
        if !strongNotehead {
            let trebleBottom = system.trebleLines.sorted().last ?? 0
            let bassTop = system.bassLines.sorted().first ?? 0
            if rect.midY > trebleBottom && rect.midY < bassTop {
                let skinny = aspect < 0.90 || aspect > 1.35
                if skinny && (strokeOverlap > 0.06 || colStem || lineLike) {
                    return true
                }
            }
        }

        // ------------------------------------------------------------
        // RULE 5) Almost empty contour artifacts
        // ------------------------------------------------------------
        if !strongNotehead, inkExtent < 0.08 {
            return true
        }

        return false
    }

    private static func computePatchMetrics(rect: CGRect, bin: [UInt8], pageW: Int, pageH: Int) -> PatchMetrics? {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: pageW, height: pageH))
        guard clipped.width > 1, clipped.height > 1 else { return nil }

        let x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        let x1 = min(pageW, Int(ceil(clipped.maxX)))
        let y1 = min(pageH, Int(ceil(clipped.maxY)))
        let w = max(1, x1 - x0)
        let h = max(1, y1 - y0)

        var ink = 0
        var leftInk = 0
        var rightInk = 0
        let midX = x0 + w / 2

        var maxRun = 0
        let centerY = y0 + h / 2
        let rowCandidates = [centerY - 1, centerY, centerY + 1]

        for y in y0..<y1 {
            let row = y * pageW
            var run = 0
            let trackRun = rowCandidates.contains(y)
            for x in x0..<x1 {
                let isInk = bin[row + x] != 0
                if isInk {
                    ink += 1
                    if x < midX { leftInk += 1 } else { rightInk += 1 }
                }
                if trackRun {
                    if isInk {
                        run += 1
                        maxRun = max(maxRun, run)
                    } else {
                        run = 0
                    }
                }
            }
        }

        let area = max(1, w * h)
        let fillRatio = Double(ink) / Double(area)
        let runFrac = Double(maxRun) / Double(max(1, w))
        let totalInk = max(1, leftInk + rightInk)
        let lrAsym = Double(abs(leftInk - rightInk)) / Double(totalInk)

        return PatchMetrics(fillRatio: fillRatio, centerRowMaxRunFrac: runFrac, lrAsymmetry: lrAsym)
    }

    private static func minDistanceToAnyStaffLine(y: CGFloat, system: SystemBlock) -> CGFloat {
        let all = system.trebleLines + system.bassLines
        guard !all.isEmpty else { return .greatestFiniteMagnitude }
        var best = CGFloat.greatestFiniteMagnitude
        for ly in all {
            best = min(best, abs(ly - y))
        }
        return best
    }

    // MARK: - Consolidation

    private static func consolidateByStepAndX(_ heads: [ScoredHead],
                                              spacing: CGFloat,
                                              barlineXs: [CGFloat],
                                              binaryPage: ([UInt8], Int, Int)?) -> [CGRect] {
        guard !heads.isEmpty else { return [] }

        let xBinWidth = max(2.0, spacing * 0.60)

        var bestByKey: [String: ScoredHead] = [:]
        bestByKey.reserveCapacity(heads.count)

        func compositeScore(_ h: ScoredHead) -> Double {
            // Use the true compositeScore now that shapeScore is computed
            return Double(h.compositeScore)
        }

        for h in heads {
            guard let step = h.staffStepIndex else { continue }
            let xBin = Int((h.rect.midX / xBinWidth).rounded())
            let key = "\(step)|\(xBin)"

            if let cur = bestByKey[key] {
                if compositeScore(h) > compositeScore(cur) {
                    bestByKey[key] = h
                }
            } else {
                bestByKey[key] = h
            }
        }

        return bestByKey.values.map { $0.rect }
    }

    // MARK: - Draw overlays

    private static func drawOverlays(on image: PlatformImage,
                                     staff: StaffModel?,
                                     noteheads: [CGRect],
                                     barlines: [CGRect]) -> PlatformImage {
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { ctx in
            image.draw(at: .zero)
            ctx.cgContext.setAlpha(0.85)

            let baseRadius = max(6.0, (staff?.lineSpacing ?? 12.0) * 0.75)

            for rect in noteheads {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let radius = baseRadius

                let pitchClass = PitchClassifier.classify(noteCenterY: center.y, staff: staff)
                let color = pitchClass.color

                ctx.cgContext.setStrokeColor(color.withAlphaComponent(0.75).cgColor)
                ctx.cgContext.setLineWidth(max(2.0, radius * 0.18))
                ctx.cgContext.strokeEllipse(in: CGRect(x: center.x - radius,
                                                       y: center.y - radius,
                                                       width: radius * 2,
                                                       height: radius * 2))

                ctx.cgContext.setFillColor(color.withAlphaComponent(0.65).cgColor)
                let dotR = max(2.5, radius * 0.20)
                ctx.cgContext.fillEllipse(in: CGRect(x: center.x - dotR,
                                                     y: center.y - dotR,
                                                     width: dotR * 2,
                                                     height: dotR * 2))
            }

            if !barlines.isEmpty {
                ctx.cgContext.setLineWidth(max(1.5, baseRadius * 0.12))
                ctx.cgContext.setStrokeColor(UIColor.systemTeal.withAlphaComponent(0.55).cgColor)
                for rect in barlines { ctx.cgContext.stroke(rect) }
            }

            if debugStrokeErase, let maskData = debugMaskData,
               let overlay = buildMaskOverlayImage(maskData: maskData, size: image.size) {
                ctx.cgContext.setAlpha(0.25)
                ctx.cgContext.draw(overlay, in: CGRect(origin: .zero, size: image.size))
            }
        }
        #else
        return image
        #endif
    }

    private static func buildMaskOverlayImage(maskData: DebugMaskData, size: CGSize) -> CGImage? {
        let w = maskData.width
        let h = maskData.height
        guard maskData.strokeMask.count == w * h, maskData.protectMask.count == w * h else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let row = y * w
            let rowRGBA = y * w * 4
            for x in 0..<w {
                let idx = row + x
                let rgbaIdx = rowRGBA + x * 4
                if maskData.strokeMask[idx] != 0 {
                    rgba[rgbaIdx] = 255
                    rgba[rgbaIdx + 3] = 120
                }
                if maskData.protectMask[idx] != 0 {
                    rgba[rgbaIdx + 1] = 255
                    rgba[rgbaIdx + 3] = max(rgba[rgbaIdx + 3], 120)
                }
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }

    // MARK: - Binary helpers

    private static func buildBinaryInkMap(from cg: CGImage, lumThreshold: Int) -> ([UInt8], Int, Int) {
        let w = cg.width
        let h = cg.height

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bpr = w * 4

        let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var bin = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * w
            let rowRGBA = y * bpr
            for x in 0..<w {
                let i = rowRGBA + x * 4
                let lum = (Int(rgba[i]) + Int(rgba[i + 1]) + Int(rgba[i + 2])) / 3
                bin[row + x] = (lum < lumThreshold) ? 1 : 0
            }
        }
        return (bin, w, h)
    }

    private static func rectInkExtent(_ rect: CGRect, bin: [UInt8], pageW: Int, pageH: Int) -> CGFloat {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: pageW, height: pageH))
        guard clipped.width > 0, clipped.height > 0 else { return 0 }

        let x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        let x1 = min(pageW, Int(ceil(clipped.maxX)))
        let y1 = min(pageH, Int(ceil(clipped.maxY)))

        var ink = 0
        for y in y0..<y1 {
            let row = y * pageW
            for x in x0..<x1 {
                if bin[row + x] != 0 { ink += 1 }
            }
        }
        let area = max(1, (x1 - x0) * (y1 - y0))
        return CGFloat(ink) / CGFloat(area)
    }

    // MARK: - Stem detector via column dominance

    private static func isStemLikeByColumnDominance(_ rect: CGRect,
                                                    bin: [UInt8],
                                                    pageW: Int,
                                                    pageH: Int) -> Bool {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: pageW, height: pageH))
        guard clipped.width >= 2, clipped.height >= 6 else { return false }

        let x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        let x1 = min(pageW, Int(ceil(clipped.maxX)))
        let y1 = min(pageH, Int(ceil(clipped.maxY)))

        let rw = max(1, x1 - x0)
        let rh = max(1, y1 - y0)
        if rh < 8 { return false }

        var colCounts = [Int](repeating: 0, count: rw)
        var totalInk = 0

        for y in y0..<y1 {
            let row = y * pageW
            for x in x0..<x1 {
                if bin[row + x] != 0 {
                    colCounts[x - x0] += 1
                    totalInk += 1
                }
            }
        }

        guard totalInk >= 8 else { return false }

        colCounts.sort(by: >)
        let top = colCounts[0]
        let top2 = top + (rw >= 2 ? colCounts[1] : 0)

        let fracTop2 = Double(top2) / Double(totalInk)
        return fracTop2 > 0.66
    }

    // MARK: - NEW: Line-likeness via PCA (catches slurs/ties/tails)

    private struct PCALineMetrics {
        let eccentricity: Double   // major/minor axis ratio
        let isLineLike: Bool
    }

    private static func lineLikenessPCA(_ rect: CGRect,
                                        bin: [UInt8],
                                        pageW: Int,
                                        pageH: Int) -> PCALineMetrics {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: pageW, height: pageH))
        guard clipped.width > 0, clipped.height > 0 else {
            return PCALineMetrics(eccentricity: 1.0, isLineLike: false)
        }

        let x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        let x1 = min(pageW, Int(ceil(clipped.maxX)))
        let y1 = min(pageH, Int(ceil(clipped.maxY)))

        // Sample ink points (cap for speed)
        var ptsX: [Double] = []
        var ptsY: [Double] = []
        ptsX.reserveCapacity(256)
        ptsY.reserveCapacity(256)

        var count = 0
        let step = max(1, Int(max(clipped.width, clipped.height) / 28.0)) // subsample
        for y in stride(from: y0, to: y1, by: step) {
            let row = y * pageW
            for x in stride(from: x0, to: x1, by: step) {
                if bin[row + x] != 0 {
                    ptsX.append(Double(x))
                    ptsY.append(Double(y))
                    count += 1
                    if count >= 300 { break }
                }
            }
            if count >= 300 { break }
        }

        guard ptsX.count >= 12 else {
            return PCALineMetrics(eccentricity: 1.0, isLineLike: false)
        }

        // mean
        let mx = ptsX.reduce(0, +) / Double(ptsX.count)
        let my = ptsY.reduce(0, +) / Double(ptsY.count)

        // covariance
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in 0..<ptsX.count {
            let dx = ptsX[i] - mx
            let dy = ptsY[i] - my
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        sxx /= Double(ptsX.count)
        syy /= Double(ptsY.count)
        sxy /= Double(ptsX.count)

        // eigenvalues of 2x2 covariance
        let tr = sxx + syy
        let det = sxx * syy - sxy * sxy
        let disc = max(0.0, tr * tr - 4.0 * det)
        let root = sqrt(disc)

        let l1 = max(1e-9, 0.5 * (tr + root))
        let l2 = max(1e-9, 0.5 * (tr - root))

        let ecc = sqrt(l1 / l2)

        // Line-like if very eccentric AND not a tiny blob
        let isLine = ecc > 5.0

        return PCALineMetrics(eccentricity: ecc, isLineLike: isLine)
    }

    // MARK: - NEW: Thickness estimate (helps reject slurs/tails)

    /// Approx average stroke thickness inside rect:
    /// - count ink pixels
    /// - estimate stroke "length" as max(w,h) projection
    /// Returns pixels (approx).
    private static func meanStrokeThickness(_ rect: CGRect,
                                            bin: [UInt8],
                                            pageW: Int,
                                            pageH: Int) -> Double {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: pageW, height: pageH))
        guard clipped.width > 0, clipped.height > 0 else { return 999 }

        let x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        let x1 = min(pageW, Int(ceil(clipped.maxX)))
        let y1 = min(pageH, Int(ceil(clipped.maxY)))

        var ink = 0
        for y in y0..<y1 {
            let row = y * pageW
            for x in x0..<x1 {
                if bin[row + x] != 0 { ink += 1 }
            }
        }

        let length = max(1.0, Double(max(clipped.width, clipped.height)))
        return Double(ink) / length
    }
}
