import SwiftUI
import TroveCore

/// Develop → Your work (docs/prompts/practice-space-home.md): every question you've done, by course
/// and topic, each topic folded until you open it. An attempt opens its working; Try again starts the
/// same question on a fresh page, so attempts of one question can be compared.
struct YourWorkCard: View {
    let develop: DevelopModel
    @State private var open: Set<String> = []

    var body: some View {
        let courses = develop.yourWork
        if !courses.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your work").font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(courses.reduce(0) { $0 + $1.count }) questions").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(courses) { course in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(course.name.uppercased())
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.Space.l).padding(.top, Theme.Space.m).padding(.bottom, Theme.Space.xs)
                        ForEach(Array(course.topics.enumerated()), id: \.element.id) { i, topic in
                            if i > 0 { Divider().padding(.leading, Theme.Space.l) }
                            TopicRow(develop: develop, topic: topic, open: open.contains(topic.id)) {
                                withAnimation(.snappy(duration: 0.25)) {
                                    if open.contains(topic.id) { open.remove(topic.id) } else { open.insert(topic.id) }
                                }
                            }
                        }
                    }
                    .padding(.bottom, Theme.Space.xs)
                    .card(cornerRadius: Theme.Radius.large)
                }
            }
        }
    }
}

private struct TopicRow: View {
    let develop: DevelopModel
    let topic: PracticeWork.Topic
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: Theme.Space.m) {
                    ScoreRing(score: topic.average, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                        HStack(spacing: 6) {
                            Text("\(topic.attempts.count) question\(topic.attempts.count == 1 ? "" : "s") · \(DevelopModel.ago(topic.latest))")
                            if let trend = topic.trend, abs(trend) >= 0.05 {
                                Label(trend > 0 ? "up" : "down", systemImage: trend > 0 ? "arrow.up.right" : "arrow.down.right")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(trend > 0 ? .green : .orange)
                                    .accessibilityLabel(trend > 0 ? "Getting better" : "Slipping")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides its questions" : "Shows its questions")
            if open {
                VStack(spacing: Theme.Space.xs) {
                    ForEach(topic.attempts) { a in AttemptRow(develop: develop, attempt: a, tries: topic.retried[a.problem]) }
                }
                .padding(.horizontal, Theme.Space.l).padding(.bottom, Theme.Space.m)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct AttemptRow: View {
    let develop: DevelopModel
    let attempt: Attempt
    /// Every attempt at this question, oldest first, when it was tried more than once.
    let tries: [Attempt]?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ScoreRing(score: attempt.score, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(PracticeWork.title(label: attempt.label)).font(.callout).lineLimit(1)
                HStack(spacing: 4) {
                    Text(DevelopModel.ago(attempt.at))
                    if let tries, let n = tries.firstIndex(where: { $0.id == attempt.id }) { Text("· try \(n + 1) of \(tries.count)") }
                    if attempt.uncertain { Text("· to review").foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !attempt.work.isEmpty {
                Button { Task { await develop.openWork(of: attempt) } } label: { WorkThumb(itemId: attempt.work) }
                    .buttonStyle(.plain)
                    .help("Open the working")
                    .accessibilityLabel("Open the working")
            }
            Button { develop.practise(problem: attempt.problem) } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Try it again on a fresh page")
                .accessibilityLabel("Try again")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(Theme.Space.s)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}

/// A small picture of the working (the sketch's card picture, made when it was last closed), so attempts can be
/// told apart at a glance (learn-pivot plan §B4). Decoded off the main thread at this size, by ThumbnailCache.
private struct WorkThumb: View {
    @Environment(AppModel.self) private var model
    let itemId: String
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "pencil.and.scribble").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.1))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).stroke(Color.secondary.opacity(0.2)))
        .task(id: itemId) {
            guard let library = model.library, let thumb = await library.item(itemId)?.thumbnail else { return }
            image = await ThumbnailCache.image(for: thumb, from: library)
        }
    }
}

/// A score as a ring (empty and dashed when it isn't marked yet).
struct ScoreRing: View {
    let score: Double?
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: size / 9, dash: score == nil ? [2, 3] : []))
            if let score {
                Circle().trim(from: 0, to: max(0.02, score))
                    .stroke(Self.colour(score), style: StrokeStyle(lineWidth: size / 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(score.map { "\(Int(($0 * 100).rounded()))" } ?? "–")
                .font(.system(size: size * 0.32, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(score == nil ? .secondary : .primary)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(score.map { "\(Int(($0 * 100).rounded())) percent" } ?? "Not marked")
    }

    static func colour(_ s: Double) -> Color { s >= 0.7 ? .green : s >= 0.4 ? Theme.accent : .red.opacity(0.85) }
}
