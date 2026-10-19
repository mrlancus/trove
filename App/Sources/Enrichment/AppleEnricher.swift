import Foundation
import NaturalLanguage
import PDFKit
import Vision
import TroveCore

/// Tier 0 on Apple platforms (every device, no Apple Intelligence needed): text in images and PDFs,
/// dates/addresses/phones, named entities, and fetching link pages.
enum AppleEnricher {
    // MARK: OCR

    /// Recognises printed and handwritten text. Accurate mode with language correction.
    static func recognizeText(in image: CGImage) async -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Typed PDFs give their text directly; scanned/handwritten pages (GoodNotes) are OCR'd.
    static func pdfText(_ data: Data, maxPages: Int = 40) async -> String {
        guard let pdf = PDFDocument(data: data) else { return "" }
        if let text = pdf.string?.trimmingCharacters(in: .whitespacesAndNewlines), text.count > 40 { return text }
        var pages: [String] = []
        for index in 0..<min(pdf.pageCount, maxPages) {
            guard let page = pdf.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(2.0, 2000 / max(bounds.width, bounds.height, 1))
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            guard let image = page.thumbnail(of: size, for: .mediaBox).cgImageForVision else { continue }
            let text = await recognizeText(in: image)
            if !text.isEmpty { pages.append(text) }
        }
        return pages.joined(separator: "\n\n")
    }

    // MARK: Detectors

    struct Detected: Equatable {
        var dates: [Date] = []
        var addresses: [String] = []
        var phones: [String] = []
        var links: [String] = []
        var places: [String] = []
        var organizations: [String] = []
        var people: [String] = []
    }

    static func detect(in text: String) -> Detected {
        var out = Detected()
        let sample = String(text.prefix(20_000))
        let types: NSTextCheckingResult.CheckingType = [.date, .address, .phoneNumber, .link]
        if let detector = try? NSDataDetector(types: types.rawValue) {
            let range = NSRange(sample.startIndex..., in: sample)
            for match in detector.matches(in: sample, range: range) {
                switch match.resultType {
                case .date: if let d = match.date, out.dates.count < 5 { out.dates.append(d) }
                case .address:
                    if let r = Range(match.range, in: sample), out.addresses.count < 3 { out.addresses.append(String(sample[r])) }
                case .phoneNumber: if let p = match.phoneNumber, out.phones.count < 3 { out.phones.append(p) }
                case .link: if let u = match.url?.absoluteString, out.links.count < 10 { out.links.append(u) }
                default: break
                }
            }
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sample
        tagger.enumerateTags(in: sample.startIndex..<sample.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            let name = String(sample[range])
            switch tag {
            case .placeName: if !out.places.contains(name) { out.places.append(name) }
            case .organizationName: if !out.organizations.contains(name) { out.organizations.append(name) }
            case .personalName: if !out.people.contains(name) { out.people.append(name) }
            default: break
            }
            return true
        }
        return out
    }

    static func fields(for detected: Detected, existing: [String: JSONValue]) -> [String: JSONValue] {
        var extracted = existing
        if !detected.dates.isEmpty { extracted["dates"] = .array(detected.dates.map { JSONValue($0) }) }
        if !detected.addresses.isEmpty { extracted["addresses"] = JSONValue(detected.addresses) }
        if !detected.phones.isEmpty { extracted["phones"] = JSONValue(detected.phones) }
        if !detected.people.isEmpty { extracted["people"] = JSONValue(Array(detected.people.prefix(5))) }
        var f: [String: JSONValue] = [:]
        if !extracted.isEmpty { f[Field.extracted] = .object(extracted) }
        let tags = (detected.places.prefix(2) + detected.organizations.prefix(2)).map { $0.lowercased() }
        if !tags.isEmpty { f[Field.tags] = JSONValue(Array(tags)) }
        return f
    }

    // MARK: Links

    static func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let limited = data.prefix(3_000_000)
        return String(data: limited, encoding: .utf8) ?? String(decoding: limited, as: UTF8.self)
    }
}
