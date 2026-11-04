import Foundation
import Testing
@testable import TroveCore

/// Names for your uploads (TEST-DEV-029): read from the paper, the board's own spelling kept. First pages
/// here are written for the test in each board's style (no board text).
@Suite struct PaperTitleTests {
    @Test func boardsPapersAreNamedByWhatTheyAre() {
        let ccea = """
            Centre Number
            General Certificate of Secondary Education
            2023
            Candidate Number
            GCSE Physics
            Unit 1
            Foundation Tier
            [GPH11]
            WEDNESDAY 7 JUNE 2023, MORNING
            """
        #expect(PaperTitle.suggest(text: ccea, fileName: "GPH11_QP_S23.pdf", source: URL(string: "https://ccea.org.uk/downloads/docs/x.pdf"))
                == "CCEA GCSE Physics Unit 1 Foundation, June 2023")
        let pearson = """
            Please check the examination details below before entering your candidate information
            Pearson Edexcel Level 1/Level 2 GCSE (9–1)
            Wednesday 21 May 2025
            Mathematics
            PAPER 1H (Non-Calculator)
            Higher Tier
            """
        #expect(PaperTitle.suggest(text: pearson, fileName: "1ma1-1h-que-20250521.pdf") == "Pearson Edexcel GCSE Mathematics Paper 1H Higher, May 2025")
        let scheme = "Mark Scheme (Results)\nSummer 2022\nPearson Edexcel GCE In Physics (9PH0) Paper 1: Advanced Physics I"
        #expect(PaperTitle.suggest(text: scheme, fileName: "9ph0-01-rms-20220818.pdf") == "Pearson Edexcel A-level Physics Paper 1, Summer 2022 (mark scheme)")
        let aqa = "AQA\nA-level\nCHEMISTRY\nPaper 2 Organic and Physical Chemistry\nMonday 12 June 2023 Morning"
        #expect(PaperTitle.suggest(text: aqa, fileName: "scan0003.pdf") == "AQA A-level Chemistry Paper 2, June 2023")
        let ocrAS = "Oxford Cambridge and RSA\nAS Level Physics A\nH156/01 Breadth in physics\nTuesday 21 May 2024"
        #expect(PaperTitle.guess(text: ocrAS).board == "OCR")
        #expect(PaperTitle.guess(text: ocrAS).qualification == "AS")
        // The board printed first wins over one a question mentions; "as 2 marks" in prose isn't AS level.
        let g = PaperTitle.guess(text: "WJEC Eduqas GCSE (9-1)\nBiology\nComponent 2\nSummer 2019\nmark this as 2 points; an AQA-style table")
        #expect(g.board == "Eduqas" && g.qualification == "GCSE" && g.paper == "Component 2" && g.series == "Summer" && g.year == 2019)
    }

    @Test func competitionsAndOtherFiles() {
        let smc = "UKMT\nUnited Kingdom Mathematics Trust\nSenior Mathematical Challenge\nThursday 3 October 2024"
        #expect(PaperTitle.suggest(text: smc, fileName: "SMC_2024_paper.pdf") == "UKMT Senior Mathematical Challenge, October 2024")
        let bpho = "British Physics Olympiad 2023-24\nA-level Physics Challenge"
        #expect(PaperTitle.suggest(text: bpho, fileName: "bpho.pdf").hasPrefix("BPhO A-Level Physics Challenge"))
        // Nothing to go on: the PDF's own title if it's a real one, else the file name tidied.
        #expect(PaperTitle.suggest(text: "Q1 Find x.", pdfTitle: "Microsoft Word - ws3.docx", fileName: "momentum_worksheet-3.pdf") == "Momentum worksheet 3")
        #expect(PaperTitle.suggest(text: "", pdfTitle: "Circular motion practice questions", fileName: "cm.pdf") == "Circular motion practice questions")
        #expect(PaperTitle.suggest(text: "", fileName: "Scan 4 Nov 2026.pdf") == "Scan 4 Nov 2026")
        #expect(PaperTitle.guess(text: "a pulse lasting 5 ms", fileName: "timing.pdf").kind == nil, "ms in text is milliseconds")
    }

    @Test func theModelCantRenameTheBoard() {
        let g = PaperTitle.guess(text: "Pearson Edexcel GCSE\nMathematics\nPaper 1F\nJune 2024")
        #expect(PaperTitle.keepsBoard("Pearson Edexcel GCSE Maths Paper 1F (Foundation), June 2024", of: g))
        #expect(!PaperTitle.keepsBoard("Edexcel GCSE Maths Paper 1F, June 2024", of: g), "the board's name must stay whole")
        #expect(!PaperTitle.keepsBoard("Pearson Edexcel AQA GCSE Maths", of: g), "no other board may appear")
        #expect(!PaperTitle.keepsBoard("x", of: g))
        #expect(PaperTitle.keepsBoard("Momentum worksheet", of: PaperTitle.guess(text: "momentum")))
    }
}
