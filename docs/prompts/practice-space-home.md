# Trove: practice in real sketches, a tutor that sees your writing, locked images, a home page

Saved 2026-11-04 so it can't be lost with a session. The user's words first, then what they mean.
Ground rules as in `docs/prompts/develop-perf-testing.md` (push to `main`, log decisions in NOTES.md,
Part 2's budgets, tests in `docs/testing/` with the code). Builds on Sketch 2 (`docs/plans/sketch-2-*.md`).

## What the user asked for

1. **The AI must see handwriting everywhere.** "the ai not being able to view any handwriting". Sketch 2
   fixed the notebook chat. Develop still sends only typed text to hints and a picture only on Mark with AI.
2. **Room to work, saved.** "the questions it gives u not having any space to do it and actually being in a
   new inf whiteboard or normal page if user chooses and it saves that so u can come back to it".
   - Each question is worked in a real sketch (notebook page or endless whiteboard, the user's choice,
     remembered), with the full editor, not a 320 pt box.
   - The working is saved and synced, linked from the attempt record.
3. **Progress you can go back through.** "trove stores where everything is so u can really view ur progress
   and go back to stuff".
4. **A tutor, not a marker.** "the ai is not meant to just be a marker its meant to like look at what ur
   doing help u if u want it". Only when asked (user's choice): check my working, hint, where did I go
   wrong, explain, mark it. It reads the question, the mark scheme and the handwriting on the page.
5. **The question is a picture on the page, like GoodNotes.** "like how in goodnotes its just like a section
   of a pdf so just like an image that's there and u can move them around etc".
6. **Lock images.** "or you can choose to lock them (add this so u can lock images and stuff so u can still
   write over them and everything etc etc but they can't be moved until u unlock it)". For every picture
   and element in every sketch, not only Develop.
7. **Organised attempts.** "similar types of questions grouped together somehow not all visible at the same
   time obv.. but something like very organised like u can easily see all ur similar attempts etc with like
   folders or whatever … something that looks good and is neat".
   - Grouped by skill/topic within a course, folded until opened; each group shows its attempts with score,
     date and a thumbnail of the working; redoing a question keeps every attempt to compare.
8. **Develop must look insanely good.** "this whole develop thing has to be insanely good looking if it
   doesn't immediately look good then that's a massive problem". Direction A Glass (MASTER_PLAN §13.1),
   `Theme` tokens.
9. **A home page.** "in trove a similar thing applies, like we need to add a home page asw which shows like
   stats or sm idk whatever, but it should nt just immediately be notes". The app opens on Home, not on notes.

## Decided (log in NOTES.md "Decisions")
- AI speaks only when asked (user, 2026-11-04).
- One sketch per attempt, kept in `Practice/<course>/<topic>` sketch folders; the Develop screen's own
  "Your work" view groups them by topic, so you never browse the folders to find them.
