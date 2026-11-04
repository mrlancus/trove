# Trove for learners: the brief

Saved 2026-11-04 so it can't be lost with a session. The user's words come first, then what they mean.
The plan is `learn-pivot-plan.md` and its review is `learn-pivot-review.md`, both in this folder.

## What the user said

1. "i would like to pivot to students more, so removing the ai coding stuff and obsidian graph stuff for now
   its too oversaturated and making the develop thing a bigger focus and making the clipboard and notes more a
   secondary thing but still there"
2. "the idea is for any student or anyone trying to learn anything really like basically anything eventually"
3. "the ai coding stuff is the mcp stuff and the github bridge etc"
4. "lets hide the features so they don't run at all in background but don't remove code there's no point"
5. "not sure what name actually" (asked whether Develop should get a new name)
6. "dont do anything again but create a prompt and then use that prompt to create a plan and review the plan"
   (no code changes in this round; another session is working on the code)

## What it means

### A. Who it's for
- **Anyone learning anything.** Start with students: GCSE, IGCSE and A-level, where the catalogue already
  is, then university. After that, anyone learning on their own: a language, an instrument, a certificate,
  coding, a hobby.
- Develop, the practice part, becomes **the reason to open the app**.
- Notes, sketches, the clipboard and saving things **stay, as tools for learning**: good, but not the pitch.

### B. Hide, don't delete
These features are hidden: **no UI, and nothing of theirs runs in the background**. Their code stays and
still compiles, and their data stays in the vault, so a feature can be switched back on in one place.
- **AI coding**:
  - trove-mcp (`mcp/`): Claude Desktop and Claude Code joining the vault as an `agent` device.
  - The GitHub bridge: stars and releases, fetched by the relay every 6 hours.
  - "etc.": the plan lists the other candidates (the Telegram bot, add addresses, feeds) and asks.
- **The Obsidian graph**:
  - Connections (the full graph).
  - The small graph on an item.
  - The clipboard's graph and Map.
  - Syncing with an Obsidian vault (the Mac mirror).
- Removing code is not wanted ("there's no point").

### C. Develop becomes the main thing
- Navigation, Home, first launch and the iPhone tabs all lead with learning.
- It has to work for any subject, not only exam board specs: your own courses and topics, questions from your
  own material, and kinds of practice that aren't exam questions.
- Build on what exists: courses, papers, practice in a sketch, the tutor, marking, mastery, goals and
  campaigns, flashcards with FSRS, Anki export, Your work.

### D. Notes and the clipboard become secondary, but still there
- They stay a click away and keep working.
- They should feed learning: notes per topic, practice and cards from your notes, lecture recordings turned
  into notes.

### E. The name
- Undecided. The plan gives options for the section ("Develop" today) and says what renaming the app
  would cost.
- **The user decides** (CLAUDE.md: names are the user's).

### F. Research first
Learning science, what students use and leave (Anki, Quizlet, Knowt, NotebookLM, GoodNotes, Notability),
self-learners, AI tutors that help versus harm, what Apple's on-device frameworks can do, and the rules for
apps used by under-18s.

## Ground rules
- `CLAUDE.md` holds:
  - Apps first, website only where cheap.
  - Apple on-device frameworks first.
  - Free Apple ID limits.
  - Only the iPad has Apple Intelligence; the user's Mac is Intel.
  - Swift 6, iOS 18 and macOS 15 targets.
  - Secrets stay in the Keychain.
- **This round: documents only.** No code edits; another session is in the code. NOTES.md gets a pointer to
  these files once that session has finished, so the two don't collide.
- Ask the user about decisions that are theirs: the name, anything that costs money, the design direction,
  and which features stay hidden.
- Check every claim about the code against the file it names.
