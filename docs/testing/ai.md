# AI (AI)

Ask (tools over the library), Ask this notebook, note actions (incl. Make flashcards), reading
handwriting, keywords, your own key (Claude, OpenAI, Gemini, OpenRouter), Apple Intelligence on the
iPad, the relay's AI routes, Activity and costs. DEVELOP_PLAN §A5 lists every call site.

### TEST-AI-001: Ask about one note, with its cost shown
- **Feature**: Ask
- **Priority**: critical
- **Coverage**: auto-tested (request building, tools, metering)
- **Platforms**: Mac, iPhone, iPad
- **Preconditions**: your key in Settings → AI → Your AI, Test says OK; a note titled `Smoke note` with `quantum walrus 42`.
- **Steps**:
  1. Ask: "What number is in my smoke note?"
  2. Watch the steps; open Activity and costs.
- **Expected**: the steps show a search and opening "Smoke note"; the answer says 42 and cites it; the
  request is listed with tokens and cost (a fraction of a cent on Fast).
- **Failure looks like**: a made-up number, no citation, no row in Activity and costs.
- **Automated by**: `AIProviderTests/researchUsesTheLibraryTools`, `metersAndLogsUsage`; device: manual.

### TEST-AI-002: Hidden items never reach the AI
- **Feature**: `aiHidden`
- **Priority**: critical
- **Coverage**: auto-tested
- **Platforms**: all
- **Preconditions**: `Smoke note` set to Hide from AI.
- **Steps**:
  1. Ask the same question as TEST-AI-001.
- **Expected**: Ask doesn't find it and says so; Activity shows no request carrying it.
- **Failure looks like**: the answer 42.
- **Automated by**: `AIProviderTests/hiddenItemsAreNeverShownAndPagesAreViewed`.

### TEST-AI-003: No AI call from features that shouldn't make one
- **Feature**: AI is optional
- **Priority**: critical
- **Coverage**: not tested
- **Platforms**: all
- **Preconditions**: Activity and costs open; note the newest row.
- **Steps**:
  1. Create a note, search, open a notebook, write, use Math Assist, study three cards, use the clipboard.
  2. Look at Activity and costs.
- **Expected**: no new rows (unless "Read new handwriting as it arrives" or keywords are on, which say so).
- **Failure looks like**: any new row.
- **Automated by**: manual.

### TEST-AI-004: Make flashcards from a note
- **Feature**: note actions
- **Priority**: high
- **Coverage**: auto-tested (relay route)
- **Platforms**: all
- **Preconditions**: a note with a paragraph of facts.
- **Steps**:
  1. Note's AI menu → Make flashcards.
  2. Item menu → Study these cards.
- **Expected**: 3–10 cards about the paragraph; the study sheet shows them as new.
- **Failure looks like**: no cards, cards about something else.
- **Automated by**: `server/test/ai.test.ts`; app: manual.

### TEST-AI-005: Errors, timeouts and going offline mid-request
- **Feature**: failures
- **Priority**: high
- **Coverage**: auto-tested (error mapping)
- **Platforms**: all
- **Preconditions**: your key.
- **Steps**:
  1. Ask something; turn on Airplane Mode while it works.
  2. Paste a wrong key and Test.
- **Expected**: a plain message for each ("You're offline", "The key was refused"); nothing hangs; Ask can be used again.
- **Failure looks like**: a spinner for ever, a raw error dump, a crash.
- **Automated by**: `AIProviderTests/claudeReadsAPageAndExplainsFailures`, `cutOffAnswersAreSplitNotFailed`.

### TEST-AI-006: The monthly limit for background reading
- **Feature**: spend limit
- **Priority**: high
- **Coverage**: implemented
- **Platforms**: all
- **Preconditions**: Settings → AI → monthly limit $0.01; Read new handwriting on.
- **Steps**:
  1. Write several pages.
- **Expected**: reading by AI stops at the limit and Vision takes over; Settings says so.
- **Failure looks like**: spending past the limit.
- **Automated by**: manual.

### TEST-AI-007: Switching models and providers
- **Feature**: tiers, own key
- **Priority**: high
- **Coverage**: auto-tested (OpenAI-style fallback, model names)
- **Platforms**: all
- **Preconditions**: keys for two providers (only if you have them).
- **Steps**:
  1. Ask with Fast, Smarter and Best; switch the provider and Ask again.
- **Expected**: each answer names its model; costs differ as the picker says.
- **Failure looks like**: the wrong model, a 400 on one provider.
- **Automated by**: `AIProviderTests/openAIStyleFallsBackWhenAParameterIsRefused`, `prettyNames`.
