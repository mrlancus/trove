# Trove: study with friends, and compare with the national cohort

Read `CLAUDE.md`, `NOTES.md` and `docs/DEVELOP_PLAN.md` first. The ground rules in
`docs/prompts/develop-perf-testing.md` still apply: save nothing over the archive branch, push to
`main`, don't ask me for permission, log the decisions you take for me in NOTES.md, meet Part 2's
performance budgets, and add tests to `docs/testing/` in the same commit as the code.

**Check first:** this builds on Develop's practice loop (the paper catalogue, practising questions,
the mark-scheme view, marking). If those aren't built and working yet, stop and tell me what's
missing instead of building around them.

## 1. Compare with the national cohort (build this first; it's small)

Examiner reports often say how candidates did on each question, sometimes as an average mark or a
percentage. On the device, read that from the downloaded examiner reports, link it to the questions,
and after I've marked a question show it next to my score: "you got 4/6; the average candidate got
2.8 (AQA examiner report, June 2023)". Say so when a report has no number for a question. Show
nothing invented or estimated. No accounts, nothing shared, no AI needed.

## 2. Study with friends

Casual challenges between friends. It's for fun and motivation, not a ranking.

- **Friends only, never strangers.** No public profiles, no search for people, no discovery. People
  join a group only through an invite link that a member sends them. Anyone can leave, and the group
  creator can remove members and revoke invites. Many users will be under 18, so keep it this way.
- **A challenge** is a set of catalogue questions or a whole paper (a mock), with either a deadline or
  a shared timer (live mode: everyone starts together while the app is open).
- **No peeking.** You see the others' answers and marks only after you've submitted your own.
- **Marking can be anything:** self-marked against the mark scheme, marked by a friend (peer
  marking: they see my answer and the mark scheme and tick the marks), or AI-marked. Each result
  shows how it was marked. It's casual, so none of this has to be strict.
- **Results** are shown by question (marks, time taken, hints used, how it was marked) and as a
  simple total for the challenge. No overall leaderboard across challenges, no XP, no streak
  pressure.
- **Mastery:** my attempt counts as ordinary practice evidence, labelled by how it was marked, just as
  if I'd done the question alone. Who won, and friends' marks of my work, don't change mastery unless
  I accept the mark.
- **Copyright:** only catalogue questions can go into a challenge, shared as catalogue ids. Each
  device downloads the paper from the board itself. My own uploads (textbook scans, worksheets) can
  never be shared. A peer marker sees my answer, not my uploaded files.

## 3. Design questions to answer (in `docs/DEVELOP_PLAN.md`, a new appendix)

1. **Encryption.** Vaults are encrypted for one person. Design a group key: how the invite link
   carries it (for example in the URL fragment, which never reaches the relay), how it changes when
   someone is removed, and what the relay can and can't see. Group data must stay unreadable to the
   relay. Say plainly in the UI what is shared with whom.
2. **The relay.** New group records (members, challenges, encrypted answers and marks) in a Durable
   Object, and live mode over the existing live socket. Write it into PROTOCOL.md with relay tests,
   Swift, JS and fixtures in the same commit. Older clients must ignore it safely. Estimate the
   Cloudflare cost.
3. **No push notifications** (free Apple ID). Say how friends find out about a new challenge or a
   finished one: on opening the app, over the live socket while it's open, or by the invite link
   itself.
4. **Abuse.** Even among friends: removing someone, leaving, deleting what I shared, and limits on
   invites and group size.
5. **The website**: whether it can join a challenge cheaply. The apps come first.

## 4. Done means

- Cohort comparisons show for every question whose examiner report has a number, and never
  otherwise.
- Two test vaults on CI (Swift and the website against `wrangler dev`) can create a group, invite,
  run a challenge, submit, mark in each of the three ways, see results only after submitting, and
  remove a member, with the relay holding only ciphertext for group data (checked with a captured
  request).
- `docs/testing/` has the tests (`develop.md` and `sync-privacy.md`), including the device tests I
  need to run with a friend, and NOTES.md says what's mine to check.
