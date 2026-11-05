// Develop's record ids and the mastery engine (PROTOCOL.md §13): a port of TroveCore's
// Develop/DevelopRecords.swift ids and Develop/Mastery.swift, run on the same
// Fixtures/mastery-cases.json. The website keeps Develop's records (they sync like any record) and can
// work out mastery, but has no Develop screens yet (docs/DEVELOP_PLAN.md decision 4).
import { sha256Hex } from "./bytes.js";

export function slug(name) {
  const folded = name.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();
  let out = "", dash = false;
  for (const ch of folded) {
    if (/[a-z0-9]/.test(ch)) {
      if (dash && out) out += "-";
      dash = false;
      out += ch;
    } else dash = true;
  }
  return out.slice(0, 64).replace(/^-+|-+$/g, "");
}

export const sha12 = (s) => sha256Hex(s).slice(0, 12);
export const conceptId = (name) => `concept.${slug(name)}`;
const SYMMETRIC = new Set(["confusedWith", "related"]);
export function edgeId(from, type, to) {
  const [a, b] = SYMMETRIC.has(type) ? [from < to ? from : to, from < to ? to : from] : [from, to];
  return `edge.${sha12(`${a}\n${type}\n${b}`)}`;
}
export const problemId = (sourceKey, key) => `problem.${sha12(`${sourceKey}\n${key}`)}`;

// FSRS-5 (Model/Study.swift), only what the mastery engine needs.
const W = [0.4072, 1.1829, 3.1262, 15.4722, 7.2102, 0.5316, 1.0651, 0.0234, 1.616, 0.1544, 1.0824, 1.9813, 0.0953, 0.2975, 2.2042, 0.2407, 2.9466, 0.5034, 0.6567];
const DECAY = -0.5, FACTOR = 19 / 81, DAY = 86_400_000, RELEARN = 10 * 60_000;
const clampD = (d) => Math.min(10, Math.max(1, d));
const initialDifficulty = (g) => clampD(W[4] - Math.exp(W[5] * (g - 1)) + 1);
export const retrievability = (days, s) => Math.pow(1 + (FACTOR * Math.max(0, days)) / Math.max(0.01, s), DECAY);
export const interval = (s, r = 0.9) => (s / FACTOR) * (Math.pow(r, 1 / DECAY) - 1);
export function fsrsReview(state, g, now) {
  if (!state) {
    const s = W[g - 1];
    const due = g === 1 ? now + RELEARN : now + Math.max(1, Math.round(interval(s))) * DAY;
    return { stability: s, difficulty: initialDifficulty(g), reps: 1, lapses: g === 1 ? 1 : 0, last: now, due };
  }
  const elapsed = Math.max(0, (now - state.last) / DAY);
  const r = retrievability(elapsed, state.stability);
  const damped = state.difficulty + (-W[6] * (g - 3) * (10 - state.difficulty)) / 9;
  const d = clampD(W[7] * initialDifficulty(4) + (1 - W[7]) * damped);
  let s;
  if (g === 1) {
    s = W[11] * Math.pow(d, -W[12]) * (Math.pow(state.stability + 1, W[13]) - 1) * Math.exp(W[14] * (1 - r));
    s = Math.min(s, state.stability);
  } else {
    const hard = g === 2 ? W[15] : 1, easy = g === 4 ? W[16] : 1;
    s = state.stability * (1 + Math.exp(W[8]) * (11 - d) * Math.pow(state.stability, -W[9]) * (Math.exp(W[10] * (1 - r)) - 1) * hard * easy);
  }
  s = Math.max(0.01, s);
  const due = g === 1 ? now + RELEARN : now + Math.max(1, Math.round(interval(s))) * DAY;
  return { stability: s, difficulty: d, reps: state.reps + 1, lapses: state.lapses + (g === 1 ? 1 : 0), last: now, due };
}

/** MasteryConstants.standard, with the same reasons (Mastery.swift). */
export const CONSTANTS = Object.freeze({
  k0: 0.8, trivialMargin: 1, ceilingMargin: 1, independence: [1, 0.85, 0.7, 0.5, 0.3, 0],
  markingWeight: { self: 1, aiScheme: 0.9, aiNoScheme: 0.5, none: 0 }, goodScore: 0.85, hardScore: 0.5, skillRetention: 0.85,
  reassessAfterFailureDays: 1, proficientMastery: 0.7, proficientSuccesses: 3, proficientProblems: 2, proficientSources: 2,
  successScore: 0.7, prerequisiteGapDays: 1, referenceDifficulty: 0,
});

export const sigmoid = (x) => 1 / (1 + Math.exp(-x));

/** One skill's state from its attempts (Mastery.evaluate(skill:)). */
export function evaluateSkill(attempts, c = CONSTANTS) {
  const sorted = [...attempts].sort((a, b) => (a.at !== b.at ? a.at - b.at : a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  let theta = 0, n = 0, memory = null, counted = 0, trivial = 0, lastWasFailure = false, lastSuccessAt = null, failuresAfterGap = 0, reassessAt = null;
  const successes = [];
  for (const a of sorted) {
    const w = c.markingWeight[a.marking] ?? 0;
    if (!(w > 0) || a.uncertain || typeof a.score !== "number") continue;
    if (a.b < theta - c.trivialMargin) { trivial++; continue; }
    const hint = Math.min(Math.max(a.hint ?? 0, 0), c.independence.length - 1);
    const s = Math.min(Math.max(a.score, 0), 1) * c.independence[hint];
    const p = sigmoid(theta - a.b);
    const k = c.k0 / Math.sqrt(1 + n);
    let next = theta + k * w * (s - p);
    if (s > p) next = Math.min(next, Math.max(theta, a.b + c.ceilingMargin));
    theta = next;
    n += w * 4 * p * (1 - p);
    const grade = s >= c.goodScore ? 3 : s >= c.hardScore ? 2 : 1;
    memory = fsrsReview(memory, grade, a.at);
    counted++;
    const ok = s >= c.successScore;
    if (ok) { successes.push([a.problem, a.source]); lastSuccessAt = a.at; failuresAfterGap = 0; reassessAt = null; }
    else {
      if (lastSuccessAt !== null && a.at - lastSuccessAt >= c.prerequisiteGapDays * DAY) failuresAfterGap++;
      if (hint === c.independence.length - 1) reassessAt = a.at + c.reassessAfterFailureDays * DAY;
    }
    lastWasFailure = !ok;
  }
  const mastery = counted > 0 ? sigmoid(theta - c.referenceDifficulty) : null;
  const problems = new Set(successes.map((x) => x[0])).size, sources = new Set(successes.map((x) => x[1])).size;
  const proficient = (mastery ?? 0) >= c.proficientMastery && successes.length >= c.proficientSuccesses && problems >= c.proficientProblems
    && sources >= c.proficientSources && !lastWasFailure;
  let due = null;
  if (memory) {
    due = memory.last + Math.max(1, Math.round(interval(memory.stability, c.skillRetention))) * DAY;
    if (reassessAt !== null) due = Math.min(due, reassessAt);
  }
  return { ability: theta, information: n, mastery, memory, attempts: counted, trivial, successes: successes.length, proficient, due,
    needsPrerequisites: failuresAfterGap >= 2, lastWasFailure };
}

/** Every skill's state (Mastery.evaluate). Attempts are records' fields plus `id`. */
export function evaluate(attempts, c = CONSTANTS) {
  const bySkill = new Map();
  for (const a of attempts) for (const s of new Set(a.skills ?? [])) {
    if (!bySkill.has(s)) bySkill.set(s, []);
    bySkill.get(s).push(a);
  }
  return new Map([...bySkill].map(([s, list]) => [s, evaluateSkill(list, c)]));
}

// ---------- Your own courses (learn-pivot plan §C1, PROTOCOL.md §13; Papers.swift Course) ----------

/** A course record's fields → {spec, name, active, own}. Own courses have spec "own.<uuid>" and source "own". */
export function course(fields) {
  const spec = String(fields.spec ?? "");
  return { spec, name: fields.name ?? spec, active: fields.active !== false, own: spec.startsWith("own.") };
}
export const courseConcept = (spec) => `concept.${slug(spec)}`;
export const topicId = (spec, name) => `concept.${slug(`${spec} ${name}`)}`;

/** An own course's topics: skill concepts with a `partOf` edge to the course's concept that isn't rejected. */
export function ownCourseTopics(spec, records) {
  const to = courseConcept(spec);
  const ids = new Set(records.filter((r) => r.kind === "edge" && r.fields.type === "partOf" && r.fields.to === to && r.fields.state !== "rejected").map((r) => r.fields.from));
  return records.filter((r) => r.kind === "concept" && ids.has(r.id)).map((r) => ({ id: r.id, name: r.fields.name }))
    .sort((a, b) => a.name.localeCompare(b.name));
}
