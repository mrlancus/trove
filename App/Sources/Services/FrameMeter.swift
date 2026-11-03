import Foundation
import QuartzCore
import SwiftUI
import TroveCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Counts slow frames while a sketch is panned or pinched (docs/plans/sketch-2-plan.md S1), so lag
/// is a number in Settings → Diagnostics, not a feeling. Its display link runs only between the
/// start and end of a gesture: nothing ticks while the page is still.
@MainActor
@Observable
final class FrameMeter {
    static let shared = FrameMeter()

    struct Run: Equatable {
        var kind: String
        var frames = 0
        var slow = 0
        /// The longest frame, in milliseconds.
        var worst = 0.0
        var at = Date()
    }

    /// The last pan and the last pinch.
    private(set) var last: [String: Run] = [:]
    @ObservationIgnored private var current: Run?
    @ObservationIgnored private var previous: CFTimeInterval = 0
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var ticker: Ticker?

    /// A gesture began ("Pan" or "Pinch"); a second begin while one runs just carries on.
    #if os(iOS)
    func begin(_ kind: String) {
        guard current == nil else { return }
        current = Run(kind: kind)
        previous = 0
        let t = Ticker { [weak self] link in self?.tick(link) }
        ticker = t
        let l = CADisplayLink(target: t, selector: #selector(Ticker.fire(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }
    #else
    func begin(_ kind: String, in view: NSView) {
        guard current == nil else { return }
        current = Run(kind: kind)
        previous = 0
        let t = Ticker { [weak self] link in self?.tick(link) }
        ticker = t
        let l = view.displayLink(target: t, selector: #selector(Ticker.fire(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }
    #endif

    func end() {
        link?.invalidate()
        link = nil
        ticker = nil
        guard let run = current else { return }
        current = nil
        if run.frames > 2 { last[run.kind] = run }
    }

    private func tick(_ link: CADisplayLink) {
        defer { previous = link.timestamp }
        guard previous > 0, var run = current else { return }
        let budget = max(1.0 / 120, link.targetTimestamp - link.timestamp)
        let took = link.timestamp - previous
        run.frames += 1
        if took > budget * 1.5 { run.slow += 1 }
        run.worst = max(run.worst, took * 1000)
        current = run
    }

    /// The display link's target (it retains its target, so it's this small object, not the meter).
    private final class Ticker: NSObject {
        let action: @MainActor (CADisplayLink) -> Void
        init(_ action: @escaping @MainActor (CADisplayLink) -> Void) { self.action = action }
        @objc func fire(_ link: CADisplayLink) { MainActor.assumeIsolated { action(link) } }
    }
}

/// Settings → Diagnostics: the frame meter's last readings and the test notebook.
struct DiagnosticsSection: View {
    @Environment(AppModel.self) private var model
    @State private var making = false
    private let meter = FrameMeter.shared

    var body: some View {
        Section {
            ForEach(["Pan", "Pinch"], id: \.self) { kind in
                if let run = meter.last[kind] {
                    LabeledContent("Last \(kind.lowercased())", value: "\(run.slow) slow of \(run.frames) frames, worst \(Int(run.worst.rounded())) ms")
                } else {
                    LabeledContent("Last \(kind.lowercased())", value: "Not measured yet")
                }
            }
            Button(making ? "Making the test notebook…" : "Make a test notebook (30 pages)") {
                making = true
                Task {
                    if let library = model.library {
                        let id = await library.addStressNotebook()
                        await model.reload()
                        model.selectedItemID = id
                    }
                    making = false
                    model.toast = "Made “Stress test, 30 pages”"
                }
            }
            .disabled(making)
        } header: {
            Text("Diagnostics")
        } footer: {
            FormFooter("Pan or pinch a sketch, then look here: a slow frame is one that took more than 1½ times the screen's frame time. 0 slow frames means no lag.")
        }
    }
}
