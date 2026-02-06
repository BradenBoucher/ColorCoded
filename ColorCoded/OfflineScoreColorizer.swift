import Foundation
import PDFKit
@preconcurrency import Vision
import CoreGraphics
import os
#if canImport(Accelerate)
import Accelerate
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Convenience operator for expanding a CGRect by a uniform amount
infix operator /-/: AdditionPrecedence

@inline(__always)
func /-/ (lhs: CGRect, rhs: CGFloat) -> CGRect {
    lhs.insetBy(dx: -rhs, dy: -rhs)
}

private func debugDrawStaffLinesEnabled() -> Bool {
    debugMasksEnabled()
}

private func debugMasksEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: "cc_debug_masks")
}

private func debugDrawBarlinesEnabled() -> Bool {
    debugMasksEnabled()
}

private func verticalEraseEnabled() -> Bool {
    UserDefaults.standard.object(forKey: "cc_enable_vertical_erase") as? Bool ?? true
}

private func barlineVetoEnabled() -> Bool {
    UserDefaults.standard.object(forKey: "cc_enable_barline_veto") as? Bool ?? true
}

private struct DebugMaskData {
    let strokeMask: [UInt8]
    let protectMask: [UInt8]
    let horizMask: [UInt8]
    let width: Int
    let height: Int
}

private var debugMaskData: DebugMaskData?

enum OfflineScoreColorizer {
    private static let log = Logger(subsystem: "ColorCoded", category: "OfflinePipeline")

    // ------------------------------------------------------------------
    // TUNING
    // ------------------------------------------------------------------

    private enum RejectTuning {
        static let ledgerRunFrac: Double = 0.70
        static let ledgerFillMax: Double = 0.12

        static let staffLineRunFrac: Double = 0.62
        static let staffLineFillMax: Double = 0.20
        static let staffLineNearFrac: Double = 0.22
        static let staffLineFlatMax: Double = 0.24
        static let staffLineWideMin: Double = 0.85

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

    private struct RowRunMetrics {
        let fillRatio: Double
        let centerRowMaxRunFrac: Double
        let rowsWithLongRunsFrac: Double
    }

    private struct NoteDetectionDebug {
        let noteRects: [CGRect]
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

    // ------------------------------------------------------------------
    // MAIN
    // ------------------------------------------------------------------

    static func colorizePDF(inputURL: URL) async throws -> URL {
        guard let doc = PDFDocument(url: inputURL) else { throw ColorizeError.cannotOpenPDF }

        let outDoc = PDFDocument()

        for pageIndex in 0..<doc.pageCount {
            log.notice("colorizePDF entering page \(pageIndex + 1, privacy: .public)/\(doc.pageCount, privacy: .public)")
            try await withCheckedThrowingContinuation { continuation in
                autoreleasepool {
                    guard let page = doc.page(at: pageIndex) else {
                        continuation.resume(returning: ())
                        return
                    }

                    let renderStart = CFAbsoluteTimeGetCurrent()
                    guard let image = render(page: page, scale: 1.6) else {
                        continuation.resume(throwing: ColorizeError.cannotRenderPage)
                        return
                    }
                    let renderMs = (CFAbsoluteTimeGetCurrent() - renderStart) * 1000.0
                    log.notice("PERF renderMs=\(String(format: "%.1f", renderMs), privacy: .public)")

                    Task {
                        let pageStart = CFAbsoluteTimeGetCurrent()
                        let staffStart = CFAbsoluteTimeGetCurrent()
                        let staffModel = await StaffDetector.detectStaff(in: image)
                        let staffMs = (CFAbsoluteTimeGetCurrent() - staffStart) * 1000.0
                        log.notice("PERF staffMs=\(String(format: "%.1f", staffMs), privacy: .public)")
                        logStaffDiagnostics(staffModel)
                        let systemsStart = CFAbsoluteTimeGetCurrent()
                        let systems = SystemDetector.buildSystems(from: staffModel, imageSize: image.size)
                        let systemsMs = (CFAbsoluteTimeGetCurrent() - systemsStart) * 1000.0
//
                        //
                        //
                        //
                        //
                        //
                        //
                        //
                        let protectStart = CFAbsoluteTimeGetCurrent()

                        // Pass 1: protectRects on original image (cheap + keeps recall)
                        let protectNoteRects = await NoteheadDetector.detectNoteheads(in: image)
                        let protectDetectMs = (CFAbsoluteTimeGetCurrent() - protectStart) * 1000.0
                        log.notice("PERF protectDetectMs=\(String(format: "%.1f", protectDetectMs), privacy: .public)")

                        // Build stroke-cleaned image AND keep the cleaned binary.
                        debugMaskData = nil
                        let strokeStart = CFAbsoluteTimeGetCurrent()
                        let cleaned = await buildStrokeCleaned(
                            baseImage: image,
                            staffModel: staffModel,
                            systems: systems,
                            protectRects: protectNoteRects
                        )
                        let strokeMs = (CFAbsoluteTimeGetCurrent() - strokeStart) * 1000.0
                        log.notice("PERF strokeMs=\(String(format: "%.1f", strokeMs), privacy: .public)")
                        if cleaned == nil {
                            debugMaskData = nil
                        }

                        let cleanedBinary = cleaned?.binaryPage
                        let rawBinary = cleaned?.binaryRaw
                        log.notice("systems.count=\(systems.count, privacy: .public) cleaned!=nil=\(cleaned != nil, privacy: .public) override!=nil=\(cleanedBinary != nil, privacy: .public)")

                        // Pass 2: do contours on binary (MUCH more stable). Fallback if it gets too aggressive.
                        let contourStart = CFAbsoluteTimeGetCurrent()
                        let contourCG = cleanedBinary ?? rawBinary ?? image.cgImageSafe

                        var noteRects = protectNoteRects
                        if let contourCG {
                            let pass2 = await NoteheadDetector.detectNoteheads(in: image, contoursCGOverride: contourCG)
                            // If it looks like we under-detected, retry on raw binary if available
                            if pass2.count >= 200 {
                                noteRects = pass2
                            } else if let rb = rawBinary {
                                noteRects = await NoteheadDetector.detectNoteheads(in: image, contoursCGOverride: rb)
                            }
                        }
                        let contourMs = (CFAbsoluteTimeGetCurrent() - contourStart) * 1000.0
                        log.notice("PERF contoursMs=\(String(format: "%.1f", contourMs), privacy: .public)")

                        // High recall note candidates
                        let detection = NoteDetectionDebug(noteRects: noteRects)
                        let debugDetectMs = 0.0
                        log.notice("PERF debugDetectMs=\(String(format: "%.1f", debugDetectMs), privacy: .public)")


                        // High recall note candidates
                        let detection = NoteDetectionDebug(noteRects: noteRects)
                        let debugDetectMs = 0.0
                        log.notice("PERF debugDetectMs=\(String(format: "%.1f", debugDetectMs), privacy: .public)")

                        // Barlines
                        let barlineStart = CFAbsoluteTimeGetCurrent()
                        let barlinesRaw = image.cgImageSafe.map { BarlineDetector.detectBarlines(in: $0, systems: systems) } ?? []
                        let barlinesFiltered = filterConfidentBarlines(barlinesRaw,
                                                                       systems: systems,
                                                                       spacing: staffModel?.lineSpacing ?? 12.0,
                                                                       binaryRaw: rawBinary)
                        let barlines = sanitizeBarlines(barlinesFiltered,
                                                        systems: systems,
                                                        spacing: staffModel?.lineSpacing ?? 12.0)
                        let barlineMs = (CFAbsoluteTimeGetCurrent() - barlineStart) * 1000.0
                        log.notice("PERF barMs=\(String(format: "%.1f", barlineMs), privacy: .public)")

                        // Use raw binary for shape metrics, cleaned binary for line/stem rejection.
                        let filterStart = CFAbsoluteTimeGetCurrent()
                        let filtered = filterNoteheadsHighRecall(
                            detection.noteRects,
                            systems: systems,
                            barlines: barlines,
                            fallbackSpacing: staffModel?.lineSpacing ?? 12.0,
                            cgImage: image.cgImageSafe,
                            binaryRawOverride: rawBinary,
                            binaryCleanOverride: cleanedBinary
                        )
                        let filterMs = (CFAbsoluteTimeGetCurrent() - filterStart) * 1000.0
                        log.notice("PERF filterMs=\(String(format: "%.1f", filterMs), privacy: .public)")

                        let horizErasedCount = cleaned?.horizErasedCount ?? -1
                        let vertErasedCount = cleaned?.vertErasedCount ?? -1
                        let horizArea = cleaned?.horizEraseArea ?? 0
                        let horizEraseFrac = horizArea > 0 ? Double(horizErasedCount) / Double(horizArea) : 0
                        log.notice("metrics systems=\(systems.count, privacy: .public) v=\(vertErasedCount, privacy: .public) h=\(horizErasedCount, privacy: .public) hFrac=\(horizEraseFrac, privacy: .public) candidates=\(detection.noteRects.count, privacy: .public) filtered=\(filtered.count, privacy: .public)")
                        logDamagedNoteheadsIfNeeded(filtered: filtered,
                                                    binaryRaw: rawBinary,
                                                    binaryClean: cleanedBinary)
                        let statusStamp = "sys=\(systems.count) v=\(vertErasedCount) h=\(horizErasedCount) notes=\(filtered.count)"
                        let watermarkText = "PIPELINE: CLEANED=\(cleaned != nil) V=\(vertErasedCount) H=\(horizErasedCount)"
                        let drawStart = CFAbsoluteTimeGetCurrent()
                        let colored = drawOverlays(
                            on: image,
                            staff: staffModel,
                            systems: systems,
                            noteheads: filtered,
                            barlines: barlines,
                            pipelineWatermark: watermarkText,
                            statusStamp: statusStamp
                        )
                        let drawMs = (CFAbsoluteTimeGetCurrent() - drawStart) * 1000.0
                        log.notice("PERF drawMs=\(String(format: "%.1f", drawMs), privacy: .public)")

                        let pdfStart = CFAbsoluteTimeGetCurrent()
                        if let pdfPage = PDFPage(image: colored) {
                            outDoc.insert(pdfPage, at: outDoc.pageCount)
                        }
                        let pdfMs = (CFAbsoluteTimeGetCurrent() - pdfStart) * 1000.0
                        log.notice("PERF pdfMs=\(String(format: "%.1f", pdfMs), privacy: .public)")
                        let pageMs = (CFAbsoluteTimeGetCurrent() - pageStart) * 1000.0
                        let strokeBinaryMs = cleaned?.perfBinaryBuildMs ?? 0
                        let strokeCopyMs = cleaned?.perfBinaryCopyMs ?? 0
                        let strokeGsmMs = cleaned?.perfGlobalStrokeMaskMs ?? 0
                        let strokeProtectMs = cleaned?.perfProtectMaskMs ?? 0
                        let strokeRoiMs = cleaned?.perfRoiTotalMs ?? 0
                        log.notice("TIMING page=\(pageIndex + 1, privacy: .public) render=\(String(format: "%.1f", renderMs), privacy: .public)ms staff=\(String(format: "%.1f", staffMs), privacy: .public)ms systems=\(String(format: "%.1f", systemsMs), privacy: .public)ms stroke=\(String(format: "%.1f", strokeMs), privacy: .public)ms strokeBin=\(String(format: "%.1f", strokeBinaryMs), privacy: .public)ms strokeCopy=\(String(format: "%.1f", strokeCopyMs), privacy: .public)ms strokeGsm=\(String(format: "%.1f", strokeGsmMs), privacy: .public)ms strokeProtect=\(String(format: "%.1f", strokeProtectMs), privacy: .public)ms strokeRoi=\(String(format: "%.1f", strokeRoiMs), privacy: .public)ms note=\(String(format: "%.1f", protectDetectMs), privacy: .public)ms bar=\(String(format: "%.1f", barlineMs), privacy: .public)ms filter=\(String(format: "%.1f", filterMs), privacy: .public)ms draw=\(String(format: "%.1f", drawMs), privacy: .public)ms pdf=\(String(format: "%.1f", pdfMs), privacy: .public)ms total=\(String(format: "%.1f", pageMs), privacy: .public)ms")
                        debugMaskData = nil
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

    // ------------------------------------------------------------------
    // RENDER
    // ------------------------------------------------------------------

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

    // ------------------------------------------------------------------
    // STROKE CLEANING PIPELINE (VERTICAL + HORIZONTAL)
    // ------------------------------------------------------------------

    private struct CleanedStrokeResult {
        // NOTE: image removed (expensive + not used by pipeline)
        let binaryRaw: ([UInt8], Int, Int)
        let binaryPage: ([UInt8], Int, Int)

        let horizErasedCount: Int
        let vertErasedCount: Int
        let horizEraseArea: Int

        // Perf breakdown (optional but useful)
        let perfBinaryBuildMs: Double
        let perfBinaryCopyMs: Double
        let perfGlobalStrokeMaskMs: Double
        let perfProtectMaskMs: Double
        let perfRoiTotalMs: Double
        let perfBinaryToCGMs: Double   // will be 0 unless debug enabled
    }



    private static func buildStrokeCleaned(baseImage: PlatformImage,
                                           staffModel: StaffModel?,
                                           systems: [SystemBlock],
                                           protectRects: [CGRect]) async -> CleanedStrokeResult? {
        guard let cg = baseImage.cgImageSafe else { return nil }

        let spacing = max(6.0, staffModel?.lineSpacing ?? 12.0)

        return buildStrokeCleaned(
            cgImage: cg,
            spacing: spacing,
            systems: systems,
            protectRects: protectRects
        )
    }

    private static func buildStrokeCleaned(cgImage: CGImage,
                                           spacing: CGFloat,
                                           systems: [SystemBlock],
                                           protectRects: [CGRect]) -> CleanedStrokeResult? {
        log.notice("enter buildStrokeCleaned(cgImage:)")
        _ = HorizontalStrokeEraser.self

        // --- Binary map (already timed by you outside OR here) ---
        let tBinary0 = CFAbsoluteTimeGetCurrent()
        let (bin, w, h) = buildBinaryInkMap(from: cgImage, lumThreshold: 175)
        let binaryBuildMs = (CFAbsoluteTimeGetCurrent() - tBinary0) * 1000.0
        log.notice("PERF binaryBuildMs=\(String(format: "%.1f", binaryBuildMs), privacy: .public)")

        let tCopy0 = CFAbsoluteTimeGetCurrent()
        let binaryRaw = (bin, w, h)
        var binary = bin
        let binaryCopyMs = (CFAbsoluteTimeGetCurrent() - tCopy0) * 1000.0
        log.notice("PERF binaryCopyMs=\(String(format: "%.1f", binaryCopyMs), privacy: .public)")

        let u = max(7.0, spacing)

        // ------------------------------------------------------------
        // PERF: Global stroke mask build
        // ------------------------------------------------------------
        let tG0 = CFAbsoluteTimeGetCurrent()
        let globalStrokeMask: VerticalStrokeMask? = VerticalStrokeMask.build(
            from: binary,
            width: w,
            height: h,
            roi: CGRect(x: 0, y: 0, width: w, height: h),
            minRun: max(12, Int((2.0 * u).rounded()))
        )
        let globalStrokeMaskMs = (CFAbsoluteTimeGetCurrent() - tG0) * 1000.0
        log.notice("PERF globalStrokeMaskMs=\(String(format: "%.1f", globalStrokeMaskMs), privacy: .public)")

        // ------------------------------------------------------------
        // Protect mask (notehead neighborhoods)
        // ------------------------------------------------------------
        let tP0 = CFAbsoluteTimeGetCurrent()
        var protectMask = [UInt8](repeating: 0, count: w * h)
        let minDim = 0.35 * u
        let maxDim = 1.8 * u
        let protectUnion: CGRect = {
            guard !systems.isEmpty else { return CGRect(x: 0, y: 0, width: w, height: h) }
            let expand = 0.6 * u
            return systems
                .map { $0.bbox.insetBy(dx: -expand, dy: -expand) }
                .reduce(CGRect.null) { $0.union($1) }
                .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        }()

        for rect in protectRects {
            guard rect.intersects(protectUnion) else { continue }
            let rw = rect.width
            let rh = rect.height
            guard rw >= minDim, rh >= minDim else { continue }
            guard rw <= maxDim, rh <= maxDim else { continue }

            let aspect = max(rw / max(1, rh), rh / max(1, rw))
            if aspect > 2.2 { continue }

            if rw < 0.25 * u && rh < 0.25 * u { continue }

            let fill = rectInkExtent(rect, bin: binary, pageW: w, pageH: h)
            if fill < 0.10 { continue }

            let expanded = rect /-/ (0.20 * u)
            let expandedFill = rectInkExtent(expanded, bin: binary, pageW: w, pageH: h)
            let expandedPCA = lineLikenessPCA(expanded, bin: binary, pageW: w, pageH: h)

            let isBlobLike = expandedFill >= 0.22 &&
                expandedPCA.eccentricity <= 4.8 &&
                min(rw, rh) >= 0.28 * u
            if !isBlobLike { continue }

            if let gsm = globalStrokeMask {
                let neighborhood = rect.insetBy(dx: -1.0 * u, dy: -0.8 * u)
                if gsm.overlapRatio(with: neighborhood) > 0.12 { continue }
            }

            let core = rect.insetBy(dx: -0.45 * u, dy: -0.35 * u)
            let clippedCore = core.intersection(protectUnion)
            markMask(&protectMask, rect: clippedCore, width: w, height: h)
        }
        let protectMaskMs = (CFAbsoluteTimeGetCurrent() - tP0) * 1000.0
        log.notice("PERF protectMaskMs=\(String(format: "%.1f", protectMaskMs), privacy: .public)")

        let protectPad = 0.20 * u
        let fullPageRect = CGRect(x: 0, y: 0, width: w, height: h)
        let rois: [CGRect] = systems.isEmpty ? [fullPageRect] : systems.map(\.bbox)

        let staffLinesByROI: [[CGFloat]] = systems.isEmpty
            ? [[]]
            : systems.map { $0.trebleLines + $0.bassLines }

        var verticalScratch = VerticalStrokeEraser.Scratch()
        var debugStrokeMaskFull: [UInt8]?
        var lastHorizMask: [UInt8]?
        var totalHorizErased = 0
        var totalVertErased = 0
        var totalHorizArea = 0
        var totalRoiMs = 0.0

        for (index, roi) in rois.enumerated() {
            guard let qroi = VerticalStrokeEraser.quantize(systemRect: roi, width: w, height: h) else { continue }
            let staffLines = staffLinesByROI[index]

            log.notice("VerticalStrokeEraser before roi=\(index, privacy: .public)")

            VerticalStrokeEraser.Scratch.ensureUInt8(&verticalScratch.protectExpandedROI, count: qroi.roiW * qroi.roiH)
            let protectFillStart = CFAbsoluteTimeGetCurrent()
            verticalScratch.protectExpandedROI.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                base.initialize(repeating: 0, count: qroi.roiW * qroi.roiH)
            }

            for rect in protectRects {
                let expanded = rect.insetBy(dx: -protectPad, dy: -protectPad)
                let clipped = expanded.intersection(roi)
                guard clipped.width > 0, clipped.height > 0 else { continue }

                let xStart = max(qroi.x0, Int(floor(clipped.minX)))
                let yStart = max(qroi.y0, Int(floor(clipped.minY)))
                let xEnd = min(qroi.x1, Int(ceil(clipped.maxX)))
                let yEnd = min(qroi.y1, Int(ceil(clipped.maxY)))
                guard xStart <= xEnd, yStart <= yEnd else { continue }

                for y in yStart...yEnd {
                    let dstRow = (y - qroi.y0) * qroi.roiW
                    for x in xStart...xEnd {
                        verticalScratch.protectExpandedROI[dstRow + (x - qroi.x0)] = 1
                    }
                }
            }

            let protectRectFillMs = (CFAbsoluteTimeGetCurrent() - protectFillStart) * 1000

            let vres = verticalEraseEnabled()
                ? VerticalStrokeEraser.eraseStrokes(
                    binary: binary,
                    width: w,
                    height: h,
                    roi: qroi,
                    spacing: spacing,
                    protectExpandedROI: verticalScratch.protectExpandedROI,
                    scratch: &verticalScratch
                )
                : VerticalStrokeEraser.Result(
                    binaryWithoutStrokes: binary,
                    strokeMaskROI: [],
                    roiX: qroi.x0,
                    roiY: qroi.y0,
                    roiW: qroi.roiW,
                    roiH: qroi.roiH,
                    erasedCount: 0,
                    totalStrokeCount: 0,
                    pass1Ms: 0, pass2Ms: 0, strokeDilateMs: 0, eraseLoopMs: 0
                )

            log.notice("VerticalStrokeEraser after roi=\(index, privacy: .public) erasedCount=\(vres.erasedCount, privacy: .public)")
            log.notice("VerticalStrokeEraser timing roi=\(index, privacy: .public) area=\(qroi.roiW * qroi.roiH, privacy: .public) passMs=\(vres.pass1Ms, privacy: .public) protectFillMs=\(protectRectFillMs, privacy: .public)")

            if debugMasksEnabled() {
                if debugStrokeMaskFull?.count != w * h {
                    debugStrokeMaskFull = [UInt8](repeating: 0, count: w * h)
                }
                if var fullMask = debugStrokeMaskFull {
                    for y in qroi.y0...qroi.y1 {
                        let srcRow = (y - qroi.y0) * qroi.roiW
                        let dstRow = y * w
                        for x in qroi.x0...qroi.x1 {
                            fullMask[dstRow + x] = vres.strokeMaskROI[srcRow + (x - qroi.x0)]
                        }
                    }
                    debugStrokeMaskFull = fullMask
                }
            }

            totalVertErased += vres.erasedCount
            binary = vres.binaryWithoutStrokes

            log.notice("HorizontalStrokeEraser before roi=\(index, privacy: .public)")
            let hStart = CFAbsoluteTimeGetCurrent()
            let hres = HorizontalStrokeEraser.eraseHorizontalRuns(
                binary: binary,
                width: w,
                height: h,
                roi: roi,
                spacing: spacing,
                protectMask: protectMask,
                staffLinesY: staffLines
            )
            let hMs = (CFAbsoluteTimeGetCurrent() - hStart) * 1000
            log.notice("HorizontalStrokeEraser after roi=\(index, privacy: .public) erasedCount=\(hres.erasedCount, privacy: .public)")
            if hres.erasedCount == 0 {
                log.notice("HorizontalStrokeEraser skipped roi=\(index, privacy: .public) erasedCount=0")
            }

            if debugMasksEnabled() { lastHorizMask = hres.horizMask }

            totalHorizErased += hres.erasedCount
            let clipped = roi.intersection(fullPageRect)
            totalHorizArea += max(0, Int(clipped.width) * Int(clipped.height))
            binary = hres.binaryWithoutHorizontals

            totalRoiMs += vres.pass1Ms + protectRectFillMs + hMs
        }

        if debugMasksEnabled(),
           let sm = debugStrokeMaskFull,
           sm.count == w * h,
           let hm = lastHorizMask,
           hm.count == w * h {
            debugMaskData = DebugMaskData(
                strokeMask: sm,
                protectMask: protectMask,
                horizMask: hm,
                width: w,
                height: h
            )
        } else if !debugMasksEnabled() {
            debugMaskData = nil
        }

        // ------------------------------------------------------------
        // BIG WIN: Only build cleaned image if you actually need it
        // ------------------------------------------------------------
        var binaryToCGMs = 0.0
        log.notice("PERF roiTotalMs=\(String(format: "%.1f", totalRoiMs), privacy: .public)")
        if debugMasksEnabled() {
            let tC0 = CFAbsoluteTimeGetCurrent()
            _ = buildBinaryCGImage(from: binary, width: w, height: h) // just to validate if you want
            binaryToCGMs = (CFAbsoluteTimeGetCurrent() - tC0) * 1000.0
            log.notice("PERF binaryToCGMs=\(String(format: "%.1f", binaryToCGMs), privacy: .public)")
        }

        return CleanedStrokeResult(
            binaryRaw: binaryRaw,
            binaryPage: (binary, w, h),
            horizErasedCount: totalHorizErased,
            vertErasedCount: totalVertErased,
            horizEraseArea: totalHorizArea,
            perfBinaryBuildMs: binaryBuildMs,
            perfBinaryCopyMs: binaryCopyMs,
            perfGlobalStrokeMaskMs: globalStrokeMaskMs,
            perfProtectMaskMs: protectMaskMs,
            perfRoiTotalMs: totalRoiMs,
            perfBinaryToCGMs: binaryToCGMs
        )
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

    // ------------------------------------------------------------------
    // FILTERING PIPELINE (YOUR HIGH RECALL FILTER)
    // ------------------------------------------------------------------

    private static func filterNoteheadsHighRecall(_ noteheads: [CGRect],
                                                  systems: [SystemBlock],
                                                  barlines: [CGRect],
                                                  fallbackSpacing: CGFloat,
                                                  cgImage: CGImage?,
                                                  binaryRawOverride: ([UInt8], Int, Int)?,
                                                  binaryCleanOverride: ([UInt8], Int, Int)?) -> [CGRect] {
        log.notice("filterNoteheadsHighRecall binaryRaw.nil=\(binaryRawOverride == nil, privacy: .public) binaryClean.nil=\(binaryCleanOverride == nil, privacy: .public)")
        guard !noteheads.isEmpty else { return [] }

        // If systems not found, only do dedupe (avoid losing notes)
        guard !systems.isEmpty else {
            return DuplicateSuppressor.suppress(noteheads, spacing: fallbackSpacing)
        }

        // Build binary page once (reused across systems)
        let binaryRaw: ([UInt8], Int, Int)? = binaryRawOverride ?? {
            guard let cgImage else { return nil }
            return buildBinaryInkMap(from: cgImage, lumThreshold: 175)
        }()
        let binaryClean: ([UInt8], Int, Int)? = binaryCleanOverride ?? binaryRaw

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

                // Widen zone a bit to eat left-side clutter
                zone.size.width = min(bbox.width * 0.45, zone.width + spacing * 2.5)

                return zone
            }()

            // Build vertical stroke mask in this system (stems/tails detector)
            let vMask: VerticalStrokeMask? = {
                guard let binaryClean else { return nil }
                let (bin, w, h) = binaryClean
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

            // Compute shapeScore BEFORE clustering/suppression so junk loses
            let gated = gated0.map { head -> ScoredHead in
                var h = head
                guard let binaryRaw else { return h }

                let (rawBin, rawW, rawH) = binaryRaw
                let ext = rectInkExtent(h.rect, bin: rawBin, pageW: rawW, pageH: rawH)
                let colStem: Bool = {
                    guard let binaryClean else { return false }
                    let (cleanBin, cleanW, cleanH) = binaryClean
                    return isStemLikeByColumnDominance(h.rect, bin: cleanBin, pageW: cleanW, pageH: cleanH)
                }()

                let ov = vMask?.overlapRatio(with: h.rect) ?? 0
                let (pca, thickness): (LineLikenessPCA, Double) = {
                    //guard let binaryRaw else { return (LineLikenessPCA(eccentricity: 1.0, isLineLike: false), 999) }
                    let (rawBin, rawW, rawH) = binaryRaw
                    let pca = lineLikenessPCA(h.rect, bin: rawBin, pageW: rawW, pageH: rawH)
                    let thickness = meanStrokeThickness(h.rect, bin: rawBin, pageW: rawW, pageH: rawH)
                    return (pca, thickness)
                }()

                h.inkExtent = ext
                h.strokeOverlap = ov

                // Shape score: 0..1
                let fillTarget: CGFloat = 0.48
                let fillScore = 1.0 - min(1.0, abs(ext - fillTarget) / 0.40)

                var s: CGFloat = 0
                s += 0.55 * fillScore
                s += 0.25 * (1.0 - min(1.0, ov / 0.35))
                s += 0.20 * (colStem ? 0.0 : 1.0)

                let ecc = pca.eccentricity
                let thin = thickness < max(1.0, spacing * 0.10)
                if ecc > 6.0 && thin {
                    s *= 0.12
                } else if ecc > 4.5 && thin {
                    s *= 0.35
                }

                h.shapeScore = max(0, min(1, s))
                return h
            }

            // Chord-aware suppression early (informed by shapeScore)
            let clustered = ClusterSuppressor.suppress(gated, spacing: spacing)

            // Targeted pruning: remove stems/tails/slurs/flat junk
            let pruned = clustered.filter { head in
                !shouldRejectAsStemOrLine(head,
                                         system: system,
                                         spacing: spacing,
                                         vMask: vMask,
                                         binaryClean: binaryClean,
                                         binaryRaw: binaryRaw,
                                         barlineXs: barlineXs)
            }

            // Consolidate (stepIndex + X bin) keeps true head, drops duplicates
            let consolidated = consolidateByStepAndX(
                pruned,
                spacing: spacing
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

    // ------------------------------------------------------------------
    // REJECTION RULES (STEMS / TAILS / LINES)
    // ------------------------------------------------------------------

    private static func shouldRejectAsStemOrLine(_ head: ScoredHead,
                                                system: SystemBlock,
                                                spacing: CGFloat,
                                                vMask: VerticalStrokeMask?,
                                                binaryClean: ([UInt8], Int, Int)?,
                                                binaryRaw: ([UInt8], Int, Int)?,
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

        if let binaryClean {
            let (bin, pageW, pageH) = binaryClean
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
        let strongNotehead = head.shapeScore > 0.72 && strokeOverlap < 0.18 && !colStem

        // Ledger / staff-line metrics
        let ledgerMetrics: PatchMetrics? = {
            guard let binaryClean else { return nil }
            let (bin, pageW, pageH) = binaryClean
            let ledgerRect = rect.insetBy(dx: -0.25 * u, dy: -0.10 * u).intersection(system.bbox)
            return computePatchMetrics(rect: ledgerRect, bin: bin, pageW: pageW, pageH: pageH)
        }()

        if let ledgerMetrics, !strongNotehead {
            if ledgerMetrics.centerRowMaxRunFrac > 0.70 &&
                ledgerMetrics.fillRatio < 0.18 &&
                h < spacing * 0.28 {
                return true
            }

            if ledgerMetrics.centerRowMaxRunFrac > RejectTuning.ledgerRunFrac,
               ledgerMetrics.fillRatio < RejectTuning.ledgerFillMax {
                return true
            }

            let distToStaff = minDistanceToAnyStaffLine(y: rect.midY, system: system)
            let nearStaff = distToStaff < spacing * RejectTuning.staffLineNearFrac
            let flat = h < spacing * RejectTuning.staffLineFlatMax
            let wide = w > spacing * RejectTuning.staffLineWideMin
            if nearStaff && flat && wide &&
                ledgerMetrics.centerRowMaxRunFrac > RejectTuning.staffLineRunFrac &&
                ledgerMetrics.fillRatio < RejectTuning.staffLineFillMax {
                return true
            }
        }

        if !strongNotehead, let binaryRaw {
            let (bin, pageW, pageH) = binaryRaw
            let expanded = rect.insetBy(dx: -0.35 * u, dy: -0.10 * u).intersection(system.bbox)
            if let runMetrics = computeRowRunMetrics(rect: expanded, bin: bin, pageW: pageW, pageH: pageH) {
                let heightRatio = rect.height / max(1.0, spacing)
                if runMetrics.rowsWithLongRunsFrac > 0.35 &&
                    heightRatio < 0.30 &&
                    runMetrics.fillRatio < 0.22 {
                    return true
                }
            }
        }

        // Tail-ish metrics
        let tailMetrics: PatchMetrics? = {
            guard let binaryClean else { return nil }
            let (bin, pageW, pageH) = binaryClean
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

        // Stroke-through veto (diagonal fragments)
        if !strongNotehead, let binaryClean {
            let (bin, pageW, pageH) = binaryClean
            let expanded = rect.insetBy(dx: -0.10 * u, dy: -0.10 * u).intersection(system.bbox)
            if expanded.width > 1, expanded.height > 1 {
                let x0 = max(0, Int(floor(expanded.minX)))
                let y0 = max(0, Int(floor(expanded.minY)))
                let x1 = min(pageW, Int(ceil(expanded.maxX)))
                let y1 = min(pageH, Int(ceil(expanded.maxY)))

                var maxRun = 0
                for x in x0..<x1 {
                    var run = 0
                    var gap = 0
                    for y in y0..<y1 {
                        let isInk = bin[y * pageW + x] != 0
                        if isInk {
                            run += 1
                            gap = 0
                            maxRun = max(maxRun, run)
                        } else {
                            gap += 1
                            if gap <= 1 { continue }
                            run = 0
                            gap = 0
                        }
                    }
                }

                if Double(maxRun) >= 1.15 * Double(spacing) && inkExtent < 0.30 && ecc > 4.8 {
                    return true
                }
            }
        }

        // Barline neighborhood veto
        if barlineVetoEnabled(), !strongNotehead, !barlineXs.isEmpty {
            let cx = rect.midX
            let nearBarline = barlineXs.contains { abs($0 - cx) < spacing * 0.12 }
            if nearBarline {
                let smallish = max(w, h) < spacing * 0.65
                if smallish && (strokeOverlap > 0.10 || colStem || lineLike) { return true }

                let tallish = h > spacing * 0.60
                if tallish && strokeOverlap > 0.12 { return true }

                if colStem { return true }
            }
        }

        // Staccato dots (tiny + high fill)
        if !strongNotehead {
            let tiny = (w < spacing * 0.30) && (h < spacing * 0.30)
            if tiny && inkExtent > 0.55 { return true }
        }

        // Hanging flat fragments away from staff neighborhoods
        if !strongNotehead {
            let isVeryFlat = (h < spacing * 0.28) && (w > spacing * 1.10)
            if isVeryFlat {
                let d = minDistanceToAnyStaffLine(y: rect.midY, system: system)
                if d > spacing * 0.55 { return true }
            }
        }

        // Tie/slur-ish: thin + long + line-like
        if !strongNotehead {
            let longish = max(w, h) > spacing * 0.85
            let thinish = min(w, h) < spacing * 0.28
            let lowFill = inkExtent < 0.28
            let thinStroke = thickness < Double(max(1.0, spacing * 0.10))

            if longish && thinish && lowFill && (lineLike || (ecc > 5.5 && thinStroke)) {
                return true
            }
            if longish && (lineLike && ecc > 6.5) && thinStroke {
                return true
            }
        }

        // Stem/tail kill switch
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

        // Mid-gap vertical artifacts (between treble/bass)
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

        // Almost empty contour artifacts
        if !strongNotehead, inkExtent < 0.08 {
            return true
        }

        return false
    }

    // ------------------------------------------------------------------
    // PATCH METRICS
    // ------------------------------------------------------------------

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

    private static func computeRowRunMetrics(rect: CGRect, bin: [UInt8], pageW: Int, pageH: Int) -> RowRunMetrics? {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: pageW, height: pageH))
        guard clipped.width > 1, clipped.height > 1 else { return nil }

        let x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        let x1 = min(pageW, Int(ceil(clipped.maxX)))
        let y1 = min(pageH, Int(ceil(clipped.maxY)))
        let w = max(1, x1 - x0)
        let h = max(1, y1 - y0)
        let longRunThreshold = Double(w) * 0.70

        var ink = 0
        var rowsWithLongRuns = 0
        var maxCenterRun = 0
        let centerY = y0 + h / 2
        let rowCandidates = [centerY - 1, centerY, centerY + 1]

        for y in y0..<y1 {
            let row = y * pageW
            var run = 0
            var maxRun = 0
            let trackCenter = rowCandidates.contains(y)
            for x in x0..<x1 {
                if bin[row + x] != 0 {
                    ink += 1
                    run += 1
                    maxRun = max(maxRun, run)
                } else {
                    run = 0
                }
            }
            if trackCenter {
                maxCenterRun = max(maxCenterRun, maxRun)
            }
            if Double(maxRun) > longRunThreshold {
                rowsWithLongRuns += 1
            }
        }

        let area = max(1, w * h)
        let fillRatio = Double(ink) / Double(area)
        let centerRunFrac = Double(maxCenterRun) / Double(max(1, w))
        let rowsFrac = Double(rowsWithLongRuns) / Double(max(1, h))

        return RowRunMetrics(fillRatio: fillRatio,
                             centerRowMaxRunFrac: centerRunFrac,
                             rowsWithLongRunsFrac: rowsFrac)
    }

    private static func logDamagedNoteheadsIfNeeded(filtered: [CGRect],
                                                    binaryRaw: ([UInt8], Int, Int)?,
                                                    binaryClean: ([UInt8], Int, Int)?) {
        guard let binaryRaw, let binaryClean else { return }
        let (rawBin, rawW, rawH) = binaryRaw
        let (cleanBin, cleanW, cleanH) = binaryClean
        guard rawW == cleanW, rawH == cleanH else { return }

        var damaged = 0
        var offenders: [(ratio: Double, rect: CGRect)] = []
        for rect in filtered {
            let fillRaw = rectInkExtent(rect, bin: rawBin, pageW: rawW, pageH: rawH)
            let fillClean = rectInkExtent(rect, bin: cleanBin, pageW: cleanW, pageH: cleanH)
            if fillRaw > 0.0 && fillClean < 0.6 * fillRaw {
                damaged += 1
                offenders.append((ratio: fillClean / max(0.001, fillRaw), rect: rect))
            }
        }

        log.warning("notehead health check damagedHeads=\(damaged, privacy: .public)")
        if !offenders.isEmpty {
            let worst = offenders.sorted { $0.ratio < $1.ratio }.prefix(10)
            let details = worst.enumerated().map { idx, item in
                let r = item.rect
                return "#\(idx + 1) ratio=\(String(format: "%.2f", item.ratio)) rect=(\(Int(r.minX)),\(Int(r.minY))) \(Int(r.width))x\(Int(r.height))"
            }.joined(separator: " | ")
            log.warning("notehead health worst=\(details, privacy: .public)")
        }
    }

    private static func filterConfidentBarlines(_ barlines: [CGRect],
                                                systems: [SystemBlock],
                                                spacing: CGFloat,
                                                binaryRaw: ([UInt8], Int, Int)?) -> [CGRect] {
        guard !barlines.isEmpty, !systems.isEmpty else { return [] }
        let widthLimit = max(2.0, 0.12 * spacing)
        let heightFracMin: CGFloat = 0.60
        let runFracMin: CGFloat = 0.55
        let systemByRect: (CGRect) -> SystemBlock? = { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            if let direct = systems.first(where: { $0.bbox.contains(center) }) {
                return direct
            }
            return systems.first(where: { $0.bbox.intersects(rect) })
        }

        return barlines.compactMap { rect in
            guard let system = systemByRect(rect) else { return nil }
            let systemHeight = max(1.0, system.bbox.height)
            let heightFrac = rect.height / systemHeight
            if heightFrac < heightFracMin { return nil }
            if rect.width > widthLimit { return nil }

            if !system.bassLines.isEmpty {
                let trebleTop = system.trebleLines.min() ?? system.bbox.minY
                let bassBottom = system.bassLines.max() ?? system.bbox.maxY
                if rect.minY > trebleTop - 0.5 * spacing { return nil }
                if rect.maxY < bassBottom + 0.5 * spacing { return nil }
            }

            if let binaryRaw {
                let (bin, pageW, pageH) = binaryRaw
                let x = min(pageW - 1, max(0, Int(rect.midX.rounded())))
                let y0 = max(0, Int(system.bbox.minY.rounded()))
                let y1 = min(pageH - 1, Int(system.bbox.maxY.rounded()))
                let longest = max(
                    longestVerticalRun(bin: bin, width: pageW, height: pageH, x: x - 1, y0: y0, y1: y1),
                    max(
                        longestVerticalRun(bin: bin, width: pageW, height: pageH, x: x, y0: y0, y1: y1),
                        longestVerticalRun(bin: bin, width: pageW, height: pageH, x: x + 1, y0: y0, y1: y1)
                    )
                )
                if CGFloat(longest) < runFracMin * systemHeight { return nil }
            }

            return rect
        }
    }

    private static func sanitizeBarlines(_ barlines: [CGRect],
                                         systems: [SystemBlock],
                                         spacing: CGFloat) -> [CGRect] {
        guard !barlines.isEmpty, !systems.isEmpty else { return [] }
        let maxWidth = max(2.0, spacing * 0.5)
        let tallAndFatWidth = spacing * 0.35
        let systemByRect: (CGRect) -> SystemBlock? = { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            if let direct = systems.first(where: { $0.bbox.contains(center) }) {
                return direct
            }
            return systems.first(where: { $0.bbox.intersects(rect) })
        }

        var sanitized: [CGRect] = []
        sanitized.reserveCapacity(barlines.count)

        for rect in barlines {
            guard let system = systemByRect(rect) else { continue }
            let systemHeight = max(1.0, system.bbox.height)
            if rect.width > spacing * 0.8 || rect.height > 0.98 * systemHeight {
                log.warning("barline sanity drop fat/tall rect=(\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height))")
                continue
            }
            if rect.height > 0.92 * systemHeight && rect.width > tallAndFatWidth { continue }
            if rect.width > maxWidth { continue }
            if rect.minX < system.bbox.minX || rect.maxX > system.bbox.maxX { continue }

            let systemWidth = max(1.0, system.bbox.width)
            let symbolWidth = min(systemWidth * 0.40, spacing * 8.0)
            let symbolZone = CGRect(x: system.bbox.minX,
                                    y: system.bbox.minY,
                                    width: symbolWidth,
                                    height: system.bbox.height)
            let intersection = rect.intersection(symbolZone)
            if intersection.width / max(1.0, rect.width) > 0.20 { continue }

            sanitized.append(rect)
        }

        sanitized = mergeBarlinesByX(sanitized, maxGap: max(2.0, spacing * 0.12))

        if !sanitized.isEmpty {
            let widths = sanitized.map(\.width)
            let heights = sanitized.map(\.height)
            let minW = widths.min() ?? 0
            let maxW = widths.max() ?? 0
            let minH = heights.min() ?? 0
            let maxH = heights.max() ?? 0
            log.notice("barline sanity count=\(sanitized.count, privacy: .public) w=[\(String(format: "%.1f", minW)), \(String(format: "%.1f", maxW))] h=[\(String(format: "%.1f", minH)), \(String(format: "%.1f", maxH))]")

            let topLargest = sanitized
                .sorted { $0.height * $0.width > $1.height * $1.width }
                .prefix(5)
                .map { rect in
                    "(\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height))"
                }
                .joined(separator: " | ")
            if !topLargest.isEmpty {
                log.notice("barline sanity largest=\(topLargest, privacy: .public)")
            }
        }

        return sanitized
    }

    private static func mergeBarlinesByX(_ barlines: [CGRect], maxGap: CGFloat) -> [CGRect] {
        guard barlines.count >= 2 else { return barlines }
        let sorted = barlines.sorted { $0.minX < $1.minX }
        var merged: [CGRect] = []
        merged.reserveCapacity(sorted.count)
        var current = sorted[0]
        for rect in sorted.dropFirst() {
            if rect.minX - current.maxX <= maxGap {
                current = current.union(rect)
            } else {
                merged.append(current)
                current = rect
            }
        }
        merged.append(current)
        return merged
    }

    private static func longestVerticalRun(bin: [UInt8],
                                           width: Int,
                                           height: Int,
                                           x: Int,
                                           y0: Int,
                                           y1: Int) -> Int {
        guard x >= 0, x < width else { return 0 }
        let minY = max(0, min(height - 1, y0))
        let maxY = max(0, min(height - 1, y1))
        if maxY < minY { return 0 }
        var maxRun = 0
        var run = 0
        for y in minY...maxY {
            if bin[y * width + x] != 0 {
                run += 1
                maxRun = max(maxRun, run)
            } else {
                run = 0
            }
        }
        return maxRun
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

    // ------------------------------------------------------------------
    // CONSOLIDATION
    // ------------------------------------------------------------------

    private static func consolidateByStepAndX(_ heads: [ScoredHead],
                                              spacing: CGFloat) -> [CGRect] {
        guard !heads.isEmpty else { return [] }

        let xBinWidth = max(2.0, spacing * 0.60)

        var bestByKey: [String: ScoredHead] = [:]
        bestByKey.reserveCapacity(heads.count)

        func compositeScore(_ h: ScoredHead) -> Double {
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

    // ------------------------------------------------------------------
    // DRAWING / DEBUG OVERLAY
    // ------------------------------------------------------------------

    private static func drawOverlays(on image: PlatformImage,
                                     staff: StaffModel?,
                                     systems: [SystemBlock],
                                     noteheads: [CGRect],
                                     barlines: [CGRect],
                                     pipelineWatermark: String?,
                                     statusStamp: String?) -> PlatformImage {
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { ctx in
            image.draw(at: .zero)
            ctx.cgContext.setAlpha(0.85)

            let baseRadius = max(6.0, (staff?.lineSpacing ?? 12.0) * 0.75)

            if debugDrawStaffLinesEnabled(), let staff {
                let colors: [UIColor] = [
                    .systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink
                ]
                let width = image.size.width
                for (idx, stave) in staff.staves.enumerated() {
                    let color = colors[idx % colors.count].withAlphaComponent(0.5)
                    ctx.cgContext.setStrokeColor(color.cgColor)
                    ctx.cgContext.setLineWidth(1.0)
                    for y in stave {
                        ctx.cgContext.move(to: CGPoint(x: 0, y: y))
                        ctx.cgContext.addLine(to: CGPoint(x: width, y: y))
                        ctx.cgContext.strokePath()
                    }
                }
                if !systems.isEmpty {
                    ctx.cgContext.setLineWidth(1.5)
                    for (idx, system) in systems.enumerated() {
                        let color = colors[idx % colors.count].withAlphaComponent(0.6)
                        ctx.cgContext.setStrokeColor(color.cgColor)
                        ctx.cgContext.stroke(system.bbox)
                    }
                }
            }

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

            if debugDrawBarlinesEnabled(), !barlines.isEmpty {
                ctx.cgContext.setLineWidth(max(1.5, baseRadius * 0.12))
                ctx.cgContext.setStrokeColor(UIColor.systemTeal.withAlphaComponent(0.55).cgColor)
                for rect in barlines { ctx.cgContext.stroke(rect) }
            }

            if let watermark = pipelineWatermark {
                drawPipelineWatermark(text: watermark, in: ctx.cgContext)
            }
            if let statusStamp {
                drawStatusStamp(text: statusStamp, in: ctx.cgContext)
            }

            if debugMasksEnabled(), let maskData = debugMaskData,
               let overlay = buildMaskOverlayImage(maskData: maskData) {
                let debugOverlayAlpha: CGFloat = 0.08
                let drawSize = CGSize(width: CGFloat(maskData.width), height: CGFloat(maskData.height))
                ctx.cgContext.setAlpha(debugOverlayAlpha)
                ctx.cgContext.draw(overlay, in: CGRect(origin: .zero, size: drawSize))
            }
        }
        #else
        return image
        #endif
    }

    private static func drawPipelineWatermark(text: String, in context: CGContext) {
        #if canImport(UIKit)
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black.withAlphaComponent(0.85)
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let size = attributed.size()
        let padding = CGSize(width: 6, height: 4)
        let origin = CGPoint(x: 8, y: 8)
        let backgroundRect = CGRect(
            x: origin.x - padding.width,
            y: origin.y - padding.height,
            width: size.width + padding.width * 2,
            height: size.height + padding.height * 2
        )

        context.saveGState()
        context.setFillColor(UIColor.white.withAlphaComponent(0.75).cgColor)
        context.fill(backgroundRect)
        attributed.draw(at: origin)
        context.restoreGState()
        #endif
    }

    private static func drawStatusStamp(text: String, in context: CGContext) {
        #if canImport(UIKit)
        let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black.withAlphaComponent(0.9)
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let size = attributed.size()
        let padding = CGSize(width: 6, height: 4)
        let origin = CGPoint(x: 8, y: 28)
        let backgroundRect = CGRect(
            x: origin.x - padding.width,
            y: origin.y - padding.height,
            width: size.width + padding.width * 2,
            height: size.height + padding.height * 2
        )

        context.saveGState()
        context.setFillColor(UIColor.white.withAlphaComponent(0.75).cgColor)
        context.fill(backgroundRect)
        attributed.draw(at: origin)
        context.restoreGState()
        #endif
    }

    private static func logStaffDiagnostics(_ staffModel: StaffModel?) {
        if let staffModel {
            let staves = staffModel.staves
            let flat = staves.flatMap { $0 }
            let minY = flat.min() ?? -1
            let maxY = flat.max() ?? -1
            log.notice("staffModel.nil=false staves=\(staves.count, privacy: .public) lineSpacing=\(staffModel.lineSpacing, privacy: .public) minY=\(minY, privacy: .public) maxY=\(maxY, privacy: .public)")
            for (idx, stave) in staves.prefix(3).enumerated() {
                let rounded = stave.map { Int($0.rounded()) }
                log.notice("staff[\(idx, privacy: .public)] lines=\(rounded, privacy: .public)")
            }
        } else {
            log.notice("staffModel.nil=true staves=0")
        }
    }

    private static func buildMaskOverlayImage(maskData: DebugMaskData) -> CGImage? {
        let w = maskData.width
        let h = maskData.height
        guard maskData.strokeMask.count == w * h,
              maskData.protectMask.count == w * h,
              maskData.horizMask.count == w * h else { return nil }

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let row = y * w
            let rowRGBA = y * w * 4
            for x in 0..<w {
                let idx = row + x
                let rgbaIdx = rowRGBA + x * 4

                // Red: vertical stroke mask (stems)
                if maskData.strokeMask[idx] != 0 {
                    rgba[rgbaIdx] = 255
                    rgba[rgbaIdx + 3] = 120
                }
                // Blue: horizontal erased
                if maskData.horizMask[idx] != 0 {
                    rgba[rgbaIdx + 2] = 255
                    rgba[rgbaIdx + 3] = max(rgba[rgbaIdx + 3], 120)
                }
                // Green: protect mask
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

    // ------------------------------------------------------------------
    // BINARY HELPERS
    // ------------------------------------------------------------------

    private static func buildBinaryInkMap(from cg: CGImage, lumThreshold: Int) -> ([UInt8], Int, Int) {
        let w = cg.width
        let h = cg.height

        let tGrayAlloc = CFAbsoluteTimeGetCurrent()
        var gray = [UInt8](repeating: 0, count: w * h)
        let grayAllocMs = (CFAbsoluteTimeGetCurrent() - tGrayAlloc) * 1000.0
        log.notice("PERF binaryGrayAllocMs=\(String(format: "%.1f", grayAllocMs), privacy: .public)")

        let tRender = CFAbsoluteTimeGetCurrent()
        gray.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            let cs = CGColorSpaceCreateDeviceGray()
            guard let ctx = CGContext(
                data: base,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let grayRenderMs = (CFAbsoluteTimeGetCurrent() - tRender) * 1000.0
        log.notice("PERF binaryGrayRenderMs=\(String(format: "%.1f", grayRenderMs), privacy: .public)")

        let tThreshold = CFAbsoluteTimeGetCurrent()
        var bin = [UInt8](repeating: 0, count: w * h)

        // If Accelerate succeeds, we flip this to false.
        var needsFallback = true

        #if canImport(Accelerate)
        // Use vImageTableLookUp to map gray -> {0,1} in one vectorized pass.
        var vImageErr: vImage_Error = kvImageNoError

        gray.withUnsafeBytes { grayBuf in
            bin.withUnsafeMutableBytes { binBuf in
                guard let grayBase = grayBuf.baseAddress,
                      let binBase = binBuf.baseAddress else { return }

                var src = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: grayBase),
                    height: vImagePixelCount(h),
                    width: vImagePixelCount(w),
                    rowBytes: w
                )
                var dst = vImage_Buffer(
                    data: binBase,
                    height: vImagePixelCount(h),
                    width: vImagePixelCount(w),
                    rowBytes: w
                )

                let thresh = Pixel_8(clamping: lumThreshold)

                // Lookup table: values < thresh => 1 else 0
                var table = [UInt8](repeating: 0, count: 256)
                for i in 0..<256 {
                    table[i] = (i < Int(thresh)) ? 1 : 0
                }

                vImageErr = vImageTableLookUp_Planar8(
                    &src,
                    &dst,
                    table,
                    vImage_Flags(kvImageNoFlags)
                )
            }
        }

        if vImageErr == kvImageNoError {
            needsFallback = false
        } else {
            log.warning("vImageTableLookUp_Planar8 failed err=\(vImageErr, privacy: .public) -> fallback threshold")
        }
        #endif

        // Scalar fallback (also used when Accelerate is unavailable)
        if needsFallback {
            // NOTE: bin is already allocated; fill it in place.
            for i in 0..<bin.count {
                bin[i] = (Int(gray[i]) < lumThreshold) ? 1 : 0
            }
        }

        let thresholdMs = (CFAbsoluteTimeGetCurrent() - tThreshold) * 1000.0
        log.notice("PERF binaryThresholdMs=\(String(format: "%.1f", thresholdMs), privacy: .public)")

        let buildMs = (CFAbsoluteTimeGetCurrent() - tGrayAlloc) * 1000.0
        log.notice("PERF binaryBuildMs=\(String(format: "%.1f", buildMs), privacy: .public)")

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

    // ------------------------------------------------------------------
    // STEM DETECTOR VIA COLUMN DOMINANCE
    // ------------------------------------------------------------------

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

    // ------------------------------------------------------------------
    // LINE-LIKENESS VIA PCA
    // ------------------------------------------------------------------

    private struct LineLikenessPCA {
        let eccentricity: Double
        let isLineLike: Bool
    }

    private static func lineLikenessPCA(_ rect: CGRect,
                                        bin: [UInt8],
                                        pageW: Int,
                                        pageH: Int) -> LineLikenessPCA {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: pageW, height: pageH))
        guard clipped.width > 0, clipped.height > 0 else {
            return LineLikenessPCA(eccentricity: 1.0, isLineLike: false)
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
        let step = max(1, Int(max(clipped.width, clipped.height) / 28.0))
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
            return LineLikenessPCA(eccentricity: 1.0, isLineLike: false)
        }

        let mx = ptsX.reduce(0, +) / Double(ptsX.count)
        let my = ptsY.reduce(0, +) / Double(ptsY.count)

        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in 0..<ptsX.count {
            let dx = ptsX[i] - mx
            let dy = ptsY[i] - my
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        sxx /= Double(ptsX.count)
        syy /= Double(ptsX.count)
        sxy /= Double(ptsX.count)

        let tr = sxx + syy
        let det = sxx * syy - sxy * sxy
        let disc = max(0.0, tr * tr - 4.0 * det)
        let root = sqrt(disc)

        let l1 = max(1e-9, 0.5 * (tr + root))
        let l2 = max(1e-9, 0.5 * (tr - root))

        let ecc = sqrt(l1 / l2)
        let isLine = ecc > 5.0

        return LineLikenessPCA(eccentricity: ecc, isLineLike: isLine)
    }

    // ------------------------------------------------------------------
    // THICKNESS ESTIMATE
    // ------------------------------------------------------------------

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
    func cgImageFromBinary(
        _ binary: ([UInt8], Int, Int)
    ) -> CGImage? {
        let (pixels, width, height) = binary

        let bytesPerRow = width
        let colorSpace = CGColorSpaceCreateDeviceGray()

        return pixels.withUnsafeBytes { ptr in
            guard let provider = CGDataProvider(
                data: NSData(bytes: ptr.baseAddress!, length: pixels.count)
            ) else { return nil }

            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }

}
