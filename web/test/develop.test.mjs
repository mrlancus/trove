// Develop ids and mastery, on the same worked examples as Swift's DevelopTests (PROTOCOL.md §13).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { CONSTANTS, conceptId, edgeId, evaluate, evaluateSkill, interval, problemId, slug } from "../public/core/develop.js";
import { sha256Hex } from "../public/core/bytes.js";

const f = JSON.parse(readFileSync(new URL("../../Packages/TroveCore/Tests/TroveCoreTests/Fixtures/mastery-cases.json", import.meta.url)));
const r4 = (x) => Math.round(x * 10_000) / 10_000;

test("the worked examples come out exactly as in Swift", () => {
  assert.equal(f.cases.length, 6);
  for (const c of f.cases) {
    const s = evaluateSkill(c.attempts);
    const e = c.expect;
    assert.equal(r4(s.ability), e.ability, `${c.name}: ability`);
    assert.equal(r4(s.information), e.information, `${c.name}: information`);
    assert.equal(s.mastery === null ? null : r4(s.mastery), e.mastery, `${c.name}: mastery`);
    assert.equal(s.memory ? r4(s.memory.stability) : null, e.stability, `${c.name}: stability`);
    if (e.difficulty !== undefined) assert.equal(r4(s.memory.difficulty), e.difficulty, `${c.name}: difficulty`);
    if (e.intervalDays !== undefined) assert.equal(r4(interval(s.memory.stability, CONSTANTS.skillRetention)), e.intervalDays, `${c.name}: interval`);
    if (e.dueDays !== undefined) assert.equal((s.due - s.memory.last) / 86_400_000, e.dueDays, `${c.name}: due`);
    assert.equal(s.proficient, e.proficient, `${c.name}: proficient`);
    assert.equal(s.attempts, e.attempts, `${c.name}: counted`);
    assert.equal(s.trivial, e.trivial, `${c.name}: trivial`);
  }
  assert.equal(evaluate(f.cases[0].attempts).size, 1);
});

test("ids and slugs match TroveCore", () => {
  assert.equal(slug("Conservation of Momentum"), "conservation-of-momentum");
  assert.equal(slug("  Énergie cinétique!! "), "energie-cinetique");
  assert.equal(conceptId("Conservation of momentum"), conceptId("conservation  of MOMENTUM"));
  assert.equal(edgeId("a", "confusedWith", "b"), edgeId("b", "confusedWith", "a"));
  assert.notEqual(edgeId("a", "about", "b"), edgeId("b", "about", "a"));
  assert.equal(edgeId("item.1", "about", "concept.x"), "edge." + sha256Hex("item.1\nabout\nconcept.x").slice(0, 12));
  assert.equal(problemId("cat:aqa-7408-1-2023-06-qp", "2.1"), "problem." + sha256Hex("cat:aqa-7408-1-2023-06-qp\n2.1").slice(0, 12));
});
