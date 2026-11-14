import Foundation
import SwiftUI
import UIKit
import Vision
import VisionKit

struct ScannedReceipt: Sendable {
    var merchant: String
    var items: [ScannedReceiptItem]
    var taxCents: Int
    var tipCents: Int
    var totalCents: Int?
    var rawText: String
}

struct ScannedReceiptItem: Identifiable, Sendable {
    let id: UUID
    var name: String
    var amountCents: Int

    init(id: UUID = UUID(), name: String, amountCents: Int) {
        self.id = id
        self.name = name
        self.amountCents = amountCents
    }
}

enum ReceiptScanError: LocalizedError {
    case unreadableImage
    case noText
    case noAmounts

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            "This image could not be read. Try a clear, well-lit receipt photo."
        case .noText:
            "No receipt text was found. Try another photo or enter the bill manually."
        case .noAmounts:
            "Text was found, but no item prices or total could be identified. Try another photo or enter the bill manually."
        }
    }
}

/// Produces an editable draft only. OCR results must be reviewed before a split is sent.
enum ReceiptRecognizer {
    static func recognize(imageData: Data) async throws -> ScannedReceipt {
        try await recognize(imageDatas: [imageData])
    }

    static func recognize(imageDatas: [Data]) async throws -> ScannedReceipt {
        try await Task.detached(priority: .userInitiated) {
            var lines: [String] = []
            for data in imageDatas {
                try Task.checkCancellation()
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.recognitionLanguages = ["en-US"]
                let handler = VNImageRequestHandler(data: data)
                try handler.perform([request])
                lines += orderedLines(request.results ?? [])
            }
            return try parse(lines: lines)
        }.value
    }

    // Receipts often put a description and price in separate OCR observations.
    // Rejoin observations on the same baseline before checking for trailing prices.
    private static func orderedLines(_ observations: [VNRecognizedTextObservation]) -> [String] {
        var rows: [[VNRecognizedTextObservation]] = []
        for observation in observations.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            if let last = rows.last, let anchor = last.first,
               abs(anchor.boundingBox.midY - observation.boundingBox.midY)
                < min(anchor.boundingBox.height, observation.boundingBox.height) * 0.45 {
                rows[rows.count - 1].append(observation)
            } else {
                rows.append([observation])
            }
        }
        return rows.map { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
        }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Intentionally conservative USD parsing; keeps all text for human review.
    static func parse(lines: [String]) throws -> ScannedReceipt {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw ReceiptScanError.noText }
        var items: [ScannedReceiptItem] = []
        var tax = 0
        var tip = 0
        var total: Int?

        for line in cleaned {
            guard let (name, cents) = trailingPrice(in: line) else { continue }
            let normalized = name.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !normalized.isEmpty else { continue }

            if matches(normalized, #"^(grand\s+total|total\s+due|amount\s+due|balance\s+due|total|amount)$"#) {
                total = cents
            } else if matches(normalized, #"^(sales\s+tax|tax|taxes|state\s+tax|local\s+tax|city\s+tax|county\s+tax)\b"#) {
                tax += cents
            } else if matches(normalized, #"^(tip|gratuity|service\s+charge)\b"#) {
                tip += cents
            } else if matches(normalized, #"\b(sub\s*total|total|balance|amount\s+paid|cash|change|credit|debit|visa|mastercard|amex|discover|tender|payment|savings|discount|coupon|suggested|suggestion|recommended|approval|authorization|account|rounding)\b"#) {
                continue
            } else if cents > 0, name.rangeOfCharacter(from: .letters) != nil {
                items.append(ScannedReceiptItem(name: name, amountCents: cents))
            }
        }

        guard !items.isEmpty || (total ?? 0) > 0 else { throw ReceiptScanError.noAmounts }
        let merchant = cleaned.first { line in
            line.rangeOfCharacter(from: .letters) != nil && trailingPrice(in: line) == nil
                && !matches(line.lowercased(), #"(https?://|www\.|thank\s+you|welcome|receipt|invoice|tel:|phone:|\d{3}[- .]\d{3}[- .]\d{4})"#)
        } ?? "Scanned receipt"
        return ScannedReceipt(
            merchant: String(merchant.prefix(80)), items: items, taxCents: tax,
            tipCents: tip, totalCents: total, rawText: cleaned.joined(separator: "\n")
        )
    }

    private static func trailingPrice(in line: String) -> (String, Int)? {
        // Only explicit decimal prices are accepted. Whole numbers may be
        // quantities, dates, phone numbers or identifiers, so never infer them.
        let pattern = #"\s+\$?\s*([0-9]{1,3}(?:,[0-9]{3})*|[0-9]+)\.([0-9]{2})\s*(?:[A-Z])?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let full = Range(match.range, in: line),
              let dollarsRange = Range(match.range(at: 1), in: line),
              let centsRange = Range(match.range(at: 2), in: line),
              let dollars = Int(line[dollarsRange].replacingOccurrences(of: ",", with: "")),
              let pennies = Int(line[centsRange]), dollars < 1_000_000 else { return nil }
        let name = line[..<full.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        // A minus sign before a price indicates a discount; preserve it in raw
        // text instead of turning it into a positive charge.
        guard !name.hasSuffix("-") else { return nil }
        return (name, dollars * 100 + pennies)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

@MainActor
struct ReceiptCamera: UIViewControllerRepresentable {
    var onScan: (Result<ScannedReceipt, Error>) -> Void
    var onCancel: () -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        var parent: ReceiptCamera
        private var isProcessing = false

        init(parent: ReceiptCamera) { self.parent = parent }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onScan(.failure(error))
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard !isProcessing else { return }
            isProcessing = true
            let pages = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.95) }
            guard pages.count == scan.pageCount, !pages.isEmpty else {
                parent.onScan(.failure(ReceiptScanError.unreadableImage))
                return
            }
            Task {
                do {
                    let receipt = try await ReceiptRecognizer.recognize(imageDatas: pages)
                    parent.onScan(.success(receipt))
                } catch {
                    parent.onScan(.failure(error))
                }
            }
        }
    }
}
