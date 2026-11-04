import Foundation
import Testing
@testable import TroveCore

/// Your own papers in a goal (TEST-DEV-032): picked, matched by name, turned off; and the goal chat that
/// can pick them and edit a goal.
@Suite struct GoalUploadsTests {
    let uploads: [(id: String, title: String)] = [
        ("u1", "CCEA GCSE Physics Unit 1 Foundation, June 2023"),
        ("u2", "CCEA GCSE Chemistry Unit 1, June 2023"),
        ("u3", "AQA A-level Physics Paper 1, June 2023"),
        ("u4", "Momentum worksheet 3"),
        ("u5", "BPhO A-Level Physics Challenge, 2023"),
        ("u6", "Cambridge IGCSE Physics Paper 2, June 2024"),
    ]

    @Test func uploadsMatchAGoalByName() {
        // A goal with no courses (CCEA isn't in the catalogue): read from its name.
        let ccea = GoalUploads.targets(courses: [], goalText: "CCEA GCSE Physics")
        #expect(GoalUploads.effective(picked: [], excluded: [], uploads: uploads, targets: ccea) == ["u1"])
        // A course goal: its board, subject and level. The AQA A-level paper, not CCEA's GCSE one.
        let aqa = GoalUploads.targets(courses: [("AQA", "Physics", "A-level")], goalText: "")
        #expect(GoalUploads.effective(picked: [], excluded: [], uploads: uploads, targets: aqa) == ["u3"])
        // "Cambridge" on the paper is the catalogue's "Cambridge International".
        let cie = GoalUploads.targets(courses: [("Cambridge International", "Physics", "IGCSE")], goalText: "")
        #expect(GoalUploads.effective(picked: [], excluded: [], uploads: uploads, targets: cie) == ["u6"])
        // A competition goal matches its organiser's papers.
        let bpho = GoalUploads.targets(courses: [], goalText: "BPhO round 1")
        #expect(GoalUploads.effective(picked: [], excluded: [], uploads: uploads, targets: bpho) == ["u5"])
        // Nothing to go on: no automatic matches (the goal keeps practising from everything).
        #expect(GoalUploads.targets(courses: [], goalText: "my mocks").isEmpty)
    }

    @Test func pickedAndTurnedOff() async {
        let aqa = GoalUploads.targets(courses: [("AQA", "Physics", "A-level")], goalText: "")
        // A worksheet you pick joins; a match you turn off leaves.
        #expect(GoalUploads.effective(picked: ["u4"], excluded: ["u3"], uploads: uploads, targets: aqa) == ["u4"])
        #expect(GoalUploads.automatic(uploads: uploads, targets: aqa) == ["u3"])
        // An upload that's gone is dropped.
        #expect(GoalUploads.effective(picked: ["gone"], excluded: [], uploads: uploads, targets: []) == [])
        var g = CampaignPlanner.Goal(id: "campaign.x", name: "AQA A-level Physics", deadline: 0, courses: ["aqa-7408"], uploads: ["u4"], excludedUploads: ["u3"])
        #expect(g.sourcePrefixes(uploads: ["u4"]) == ["cat:aqa-7408-", "item:u4"])
        // Uploads survive the record (and sync with it).
        let lib = Library(engine: SyncEngine(device: "A", keys: nil, encrypted: false))
        await lib.saveCampaign(g)
        let back = await lib.campaigns().first
        #expect(back?.uploads == ["u4"] && back?.excludedUploads == ["u3"])
        g.courses = []
        #expect(g.sourcePrefixes(uploads: []).isEmpty, "no courses, no uploads: anything you have")
    }

    @Test func theChatPicksUploadsAndEditsAGoal() throws {
        let list = uploads.map { GoalChat.Upload(id: $0.id, title: $0.title) }
        let current = GoalChat.Proposal(name: "CCEA GCSE Physics", date: "2027-06-01", courses: [], papers: [], target: nil, summary: "", uploads: ["u1"])
        let prompt = GoalChat.prompt([.init(.you, "add the chemistry paper too")], candidates: [], today: "2026-11-04", uploads: list, current: current)
        #expect(prompt.contains("u2: CCEA GCSE Chemistry Unit 1, June 2023") && prompt.contains("<current_goal>") && prompt.contains("uploads: u1"))
        let reply = #"{"status":"ready","question":"","options":[],"goal":{"name":"CCEA GCSE Physics","date":"2027-06-01","courses":[],"papers":[],"target":"","summary":"","uploads":["u1","u2","made-up"]}}"#
        guard case .ready(let p) = try #require(GoalChat.parse(reply, candidates: [], uploads: list)) else { Issue.record("not ready"); return }
        #expect(p.uploads == ["u1", "u2"], "ids not in the list are dropped")
        // Older replies without uploads still read.
        let old = #"{"status":"ready","question":"","options":[],"goal":{"name":"x","date":"2027-06-01","courses":[],"papers":[],"target":"","summary":""}}"#
        guard case .ready(let q) = try #require(GoalChat.parse(old, candidates: [])) else { Issue.record("not ready"); return }
        #expect(q.uploads.isEmpty)
    }
}
