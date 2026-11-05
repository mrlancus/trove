import SwiftUI
import TroveCore

/// First launch (learn-pivot plan §4 B3): after the vault is made, "What are you learning?" with three answers.
/// The answer sets Home's Up next; nothing is locked behind it, and every answer can be changed later in Learn.
struct WhatAreYouLearningView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var develop = DevelopModel.shared
    @State private var pickingCourse = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text("What are you learning?").font(.largeTitle.weight(.bold))
                    Text("Trove gives you small practice sessions, a tutor that holds the answer back, and progress you can see.")
                        .font(.callout).foregroundStyle(.secondary)
                    LearningChoice(title: "An exam course", detail: "GCSE, IGCSE or A-level, from AQA, OCR, Pearson, Eduqas, WJEC or Cambridge, with their real past papers.",
                                   symbol: "graduationcap.fill", tint: Theme.accent) { pickingCourse = true }
                    LearningChoice(title: "Something of my own", detail: "A university module, a language, an instrument, a certificate: name it and its topics.",
                                   symbol: "sparkles", tint: .purple) {
                        model.firstLaunchChoice = .own
                        model.openLearn()
                        dismiss()
                    }
                    LearningChoice(title: "Just take me to my notes", detail: "You can start learning any time from Learn.",
                                   symbol: "doc.text", tint: .secondary) {
                        model.selection = .smart(.notes)
                        dismiss()
                    }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
            .task { await develop.start(model) }
            .sheet(isPresented: $pickingCourse, onDismiss: {
                if !develop.courses.isEmpty { model.openLearn(); dismiss() }
            }) { CoursePicker(develop: develop) }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }
}

private struct LearningChoice: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(cornerRadius: Theme.Radius.large)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.large))
        }
        .buttonStyle(.plain)
    }
}
