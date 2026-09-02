import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

public struct ExtractedSourceUnit: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var index: Int
    public var text: String
    public var usedOCR: Bool
    public var ocrConfidence: Double?
    public var regions: [TextImportSourceRegion]

    public init(
        id: UUID = UUID(),
        index: Int,
        text: String,
        usedOCR: Bool,
        ocrConfidence: Double? = nil,
        regions: [TextImportSourceRegion] = []
    ) {
        self.id = id
        self.index = index
        self.text = text
        self.usedOCR = usedOCR
        self.ocrConfidence = ocrConfidence
        self.regions = regions
    }
}

public struct ExtractedDocument: Codable, Hashable, Sendable {
    public var sourceName: String
    public var contentType: String
    public var sha256: String
    public var byteCount: Int64
    public var units: [ExtractedSourceUnit]
    /// In-memory original used only until the user makes an explicit retention
    /// choice. A persisted review includes it only for `keepOriginal`.
    public var originalData: Data?

    public init(
        sourceName: String,
        contentType: String,
        sha256: String,
        byteCount: Int64,
        units: [ExtractedSourceUnit],
        originalData: Data? = nil
    ) {
        self.sourceName = sourceName
        self.contentType = contentType
        self.sha256 = sha256
        self.byteCount = byteCount
        self.units = units
        self.originalData = originalData
    }

    public var combinedText: String {
        units.map { "[Page \($0.index + 1)]\n\($0.text)" }.joined(separator: "\n\n")
    }
}

public enum DocumentExtractionError: LocalizedError, Sendable {
    case inaccessible
    case unsupported
    case tooLarge
    case tooManyPages
    case tooMuchText
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .inaccessible: String(localized: "The selected source could not be opened.")
        case .unsupported: String(localized: "This source format is not supported.")
        case .tooLarge: String(localized: "This source is larger than the configured import limit.")
        case .tooManyPages: String(localized: "This document has more pages than the configured import limit.")
        case .tooMuchText: String(localized: "The extracted text exceeds the configured import limit.")
        case .unreadable: String(localized: "No readable text could be extracted. You can still enter the information manually.")
        }
    }
}

public actor DocumentTextExtractor {
    private let limits: ImportLimits

    public init(limits: ImportLimits = .init()) {
        self.limits = limits
    }

    public func extract(url: URL) throws -> ExtractedDocument {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey])
        let byteCount = Int64(resourceValues.fileSize ?? 0)
        guard byteCount <= limits.maximumFileBytes else { throw DocumentExtractionError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let type = resourceValues.contentType ?? UTType(filenameExtension: url.pathExtension)

        let units: [ExtractedSourceUnit]
        if type?.conforms(to: .pdf) == true {
            units = try extractPDF(data: data)
        } else if type?.conforms(to: .image) == true {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw DocumentExtractionError.unreadable
            }
            let frameCount = CGImageSourceGetCount(source)
            guard frameCount > 0, frameCount <= limits.maximumPages else {
                throw DocumentExtractionError.tooManyPages
            }
            units = try (0..<frameCount).compactMap { index in
                guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
                let result = try recognize(image)
                return .init(
                    index: index,
                    text: result.text,
                    usedOCR: true,
                    ocrConfidence: result.averageConfidence,
                    regions: result.regions
                )
            }
        } else if type?.conforms(to: .plainText) == true || type?.conforms(to: .text) == true {
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                throw DocumentExtractionError.unreadable
            }
            units = [.init(index: 0, text: text, usedOCR: false)]
        } else {
            throw DocumentExtractionError.unsupported
        }

        let totalCharacters = units.reduce(0) { $0 + $1.text.count }
        guard totalCharacters <= limits.maximumExtractedCharacters else { throw DocumentExtractionError.tooMuchText }
        guard units.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DocumentExtractionError.unreadable
        }
        return ExtractedDocument(
            sourceName: resourceValues.name ?? url.lastPathComponent,
            contentType: type?.identifier ?? "public.data",
            sha256: hash,
            byteCount: byteCount,
            units: units,
            originalData: data
        )
    }

    private func extractPDF(data: Data) throws -> [ExtractedSourceUnit] {
        guard let document = PDFDocument(data: data) else { throw DocumentExtractionError.unreadable }
        guard document.pageCount <= limits.maximumPages else { throw DocumentExtractionError.tooManyPages }
        var results: [ExtractedSourceUnit] = []
        results.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let image = render(page: page, maximumDimension: 2_048) else {
                results.append(.init(index: index, text: embedded, usedOCR: false))
                continue
            }
            let ocr = try recognize(image)
            let normalizedEmbedded = normalizedComparisonText(embedded)
            let normalizedOCR = normalizedComparisonText(ocr.text)
            let addsDistinctOCR = !ocr.text.isEmpty
                && (normalizedEmbedded.isEmpty || !normalizedEmbedded.contains(normalizedOCR))
            let separator = !embedded.isEmpty && addsDistinctOCR ? "\n" : ""
            let combined = addsDistinctOCR ? embedded + separator + ocr.text : embedded
            let shift = (embedded as NSString).length + (separator as NSString).length
            let shiftedRegions: [TextImportSourceRegion]
            if addsDistinctOCR {
                shiftedRegions = ocr.regions.map { region in
                    var region = region
                    region.startUTF16Offset += shift
                    region.endUTF16Offset += shift
                    return region
                }
            } else {
                shiftedRegions = []
            }
            results.append(.init(
                index: index,
                text: combined,
                usedOCR: addsDistinctOCR,
                ocrConfidence: addsDistinctOCR ? ocr.averageConfidence : nil,
                regions: shiftedRegions
            ))
        }
        return results
    }

    private func render(page: PDFPage, maximumDimension: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(min(maximumDimension / bounds.width, maximumDimension / bounds.height), 2)
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard Int64(width) * Int64(height) <= limits.maximumImagePixels,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    private func recognize(_ image: CGImage) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ja-JP", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        var cursor = 0
        var strings: [String] = []
        var regions: [TextImportSourceRegion] = []
        var confidences: [Double] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            if !strings.isEmpty { cursor += 1 }
            let start = cursor
            let length = (candidate.string as NSString).length
            cursor += length
            strings.append(candidate.string)
            let box = observation.boundingBox
            let confidence = Double(candidate.confidence)
            confidences.append(confidence)
            regions.append(TextImportSourceRegion(
                text: candidate.string,
                startUTF16Offset: start,
                endUTF16Offset: start + length,
                normalizedBoundingBox: TextImportNormalizedRect(
                    x: Double(box.origin.x),
                    y: Double(box.origin.y),
                    width: Double(box.width),
                    height: Double(box.height)
                ),
                confidence: confidence
            ))
        }
        return OCRResult(
            text: strings.joined(separator: "\n"),
            averageConfidence: confidences.isEmpty
                ? nil
                : confidences.reduce(0, +) / Double(confidences.count),
            regions: regions
        )
    }

    private func normalizedComparisonText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { !$0.isWhitespace }
    }
}

private struct OCRResult {
    var text: String
    var averageConfidence: Double?
    var regions: [TextImportSourceRegion]
}
