import Foundation

/// What a new sketch starts as (docs/plans/sketch-2-plan.md T6): the sheet that opens on "New
/// sketch" starts at your last choices, so Create makes your usual sketch in one tap.
public struct NewSketchChoice: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Pages, one after another.
        case notebook
        /// One endless canvas.
        case whiteboard
    }

    public var kind: Kind = .notebook
    public var paper: InkPaper = .lined
    public var size: InkPageSize = .a4
    public var landscape = false
    /// The page colour (nil: white).
    public var color: String?
    /// Show the sheet on "New sketch" (off: create with these straight away).
    public var ask = true

    public init() {}

    /// The page's width and height in points.
    public var dimensions: [Double] { size.dimensions(landscape: landscape) }

    public static let colours: [(name: String, hex: String?)] = [("White", nil), ("Cream", "#fff8e7"), ("Grey", "#f1f1f1"), ("Dark", "#1c1c1e")]

    public static func load(_ data: Data?) -> NewSketchChoice {
        guard let data, let c = try? JSONDecoder().decode(NewSketchChoice.self, from: data) else { return NewSketchChoice() }
        return c
    }

    public var data: Data? { try? JSONEncoder().encode(self) }
}

extension InkPageSize: Codable {}

extension Library {
    /// A new sketch made as chosen; returns its id.
    @discardableResult
    public func addSketch(_ choice: NewSketchChoice, title: String = "", folder: [String] = []) async -> String {
        let id = await addSketch(title: title, paper: choice.paper, folder: folder, infinite: choice.kind == .whiteboard)
        if choice.kind == .notebook || choice.color != nil {
            await setAllPages(of: id, color: choice.color, size: choice.kind == .notebook ? choice.dimensions : nil)
        }
        return id
    }
}
