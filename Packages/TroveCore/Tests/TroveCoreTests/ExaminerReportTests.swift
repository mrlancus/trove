import Foundation
import Testing
@testable import TroveCore

/// The national-cohort comparison (study-with-friends prompt §1): only figures the examiner report prints, tied to
/// the right question; nothing for a question it gives no figure for. The text below is written to look like the
/// boards' layouts; no report text is committed.
@Suite struct ExaminerReportTests {
    /// AQA GCSE: a bare "01.1" heading over each part, figures in the prose, a page footer in the middle.
    let aqaGCSE = """
    General
    The longer calculations, question 09.2 and 10.1, went well. Question 09.2 had nearly three quarters
    of the students scoring 6 marks, while question 10.1 had almost 60 % of the students scoring 6 marks.
    Question 02.2 suited students who had done the practical.
    For this question, just fewer than 40% of the students scored 5 or 6 marks.

    01.1
    Answers needed the idea of the resource being replaced. It was not enough to just state the

    © 2025 AQA                                   3 of 11
    Report on the examination – GCSE - Physics – 8463/1H – June 2025

    opposite. Just fewer than 20 % of the students
    scored 2 marks, while just over 50 % of the students scored 1 mark.

    01.2
    Almost all of the students scored this mark for writing down the equation.

    01.4
    This question was poorly answered with fewer than 10 % of the students scoring 2 marks.
    About 30 % of the students scored 1 mark. Students who compared speeds did well.
    """

    /// AQA A-level: "Question 1" headings, parts named inline ("for Question 1.1", "in 1.3").
    let aqaALevel = """
    Question 1

    Only about 25% of students obtained all three marks for Question 1.1. Many labelled a proton.

    The best answers to Question 1.2 referred to electron capture.

    The calculation in 1.3 was very accessible, with over 65% of students getting both marks.

    Question 2

    Question 2.4 discriminated well and gave a good spread of marks. Over 20% gained all five
    marks for this question. Common errors included using 2m for L.
    """

    /// Run with and without blank lines: the app reads a PDF into lines with none between paragraphs.
    @Test(arguments: [true, false]) func aqaGCSEPartsGetTheirOwnFigures(blank: Bool) {
        let f = ExaminerReport.figures(aqaGCSE.lines(blank))
        #expect(f["1.1"] == ["Just fewer than 20% of the students scored 2 marks, while just over 50% of the students scored 1 mark."])
        #expect(f["1.4"] == ["This question was poorly answered with fewer than 10% of the students scoring 2 marks.",
                             "About 30% of the students scored 1 mark."])
        // "Almost all of the students" is no figure: nothing is made of words like "most" or "many".
        #expect(f["1.2"] == nil)
        // The general section: a sentence naming two questions goes to each whose own part has a figure…
        #expect(f["9.2"]?.first?.contains("three quarters") == true)
        #expect(f["10.1"]?.first?.contains("almost 60%") == true)
        // …and "this question" is the one the sentence before named.
        #expect(f["2.2"] == ["For this question, just fewer than 40% of the students scored 5 or 6 marks."])
    }

    /// Run with and without blank lines: the app reads a PDF into lines with none between paragraphs.
    @Test(arguments: [true, false]) func aqaALevelInlineReferences(blank: Bool) {
        let f = ExaminerReport.figures(aqaALevel.lines(blank))
        #expect(f["1.1"] == ["Only about 25% of students obtained all three marks for Question 1.1."])
        #expect(f["1.2"] == nil)
        #expect(f["1.3"] == ["The calculation in 1.3 was very accessible, with over 65% of students getting both marks."])
        // "Over 20% gained all five marks for this question." follows a sentence naming 2.4.
        #expect(f["2.4"] == ["Over 20% gained all five marks for this question."])
        // The section heading "Question 1" never takes its parts' figures.
        #expect(f["1"] == nil)
        #expect(f["2"] == nil)
    }

    /// Run with and without blank lines: the app reads a PDF into lines with none between paragraphs.
    @Test(arguments: [true, false]) func headingSentencesSectionsAndStrayPercentages(blank: Bool) {
        let lines = """
        Question 5.1 was answered correctly by nearly 70% of students. Rounding was the usual slip.
        Question 6
        An answer of 4.76%, rounded to 5% scored no marks. Most students did better.
        Section B
        The correct answer to B14 was chosen by less than 20% of students.
        """.lines(blank)
        let f = ExaminerReport.figures(lines)
        // The heading stays part of its sentence.
        #expect(f["5.1"] == ["Question 5.1 was answered correctly by nearly 70% of students."])
        // A percentage that isn't about candidates is no figure.
        #expect(f["6"] == nil)
        // After "Section B" a sentence isn't the last question's.
        #expect(f.count == 1)
    }

    /// Run with and without blank lines: the app reads a PDF into lines with none between paragraphs.
    @Test(arguments: [true, false]) func lettersAndMeanMarks(blank: Bool) {
        let lines = """
        Question 3 (a) (ii)
        The mean mark for this question was 2.8 out of 6. Candidates found it hard.
        Q4(b) Most candidates plotted the points well.
        (c) A 22% efficiency means that 22% of the total energy is useful.
        """.lines(blank)
        let f = ExaminerReport.figures(lines)
        #expect(f["3.1.2"] == ["The mean mark for this question was 2.8 out of 6."])
        // No figure about candidates: nothing for 4(b), and "22% of the total energy" isn't one.
        #expect(f["4.2"] == nil)
        #expect(f.count == 1)
    }

    /// Run with and without blank lines: the app reads a PDF into lines with none between paragraphs.
    @Test(arguments: [true, false]) func proseWithoutNumbersGivesNothing(blank: Bool) {
        let lines = """
        Question 1
        (a) Many candidates answered well. Stronger candidates explained the average force.
        (b) Most were able to calculate the speed. Some confused mass and weight.
        """.lines(blank)
        #expect(ExaminerReport.figures(lines).isEmpty)
    }

    @Test func keysMatchThePaperSplitter() {
        #expect(ExaminerReport.heading("01.1")?.key == "1.1")
        #expect(ExaminerReport.heading("Question 09.2")?.key == "9.2")
        #expect(ExaminerReport.heading("Question 3(a)(ii)")?.key == "3.1.2")
        #expect(ExaminerReport.heading("Question 3 (b): most did well")?.key == "3.2")
        #expect(ExaminerReport.heading("2025 was a good year") == nil)
        #expect(ExaminerReport.heading("3.5 m s–1 was common") == nil)
        #expect(ExaminerReport.references("Over half of the students got Q4(b)(iii) right, unlike Question 5.") == ["4.2.3", "5"])
    }

    /// Real examiner reports as text, one `.txt` per report (`pdftotext <report>.pdf`), never committed:
    /// TROVE_REPORTS=<folder> swift test --filter ExaminerReport.
    @Test func realReports() throws {
        guard let folder = ProcessInfo.processInfo.environment["TROVE_REPORTS"] else { return }
        for f in try FileManager.default.contentsOfDirectory(atPath: folder).filter({ $0.hasSuffix(".txt") }).sorted() {
            let text = try String(contentsOfFile: URL(fileURLWithPath: folder).appendingPathComponent(f).path, encoding: .utf8)
            let figures = ExaminerReport.figures(text.components(separatedBy: "\n"))
            print("REPORT \(f): \(figures.count) questions with figures")
            for k in figures.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                for q in figures[k]! { print("  \(k): \(q.prefix(110))") }
            }
        }
    }
}

private extension String {
    /// The text's lines, with or without the blank ones.
    func lines(_ blank: Bool) -> [String] {
        let all = components(separatedBy: "\n")
        return blank ? all : all.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
