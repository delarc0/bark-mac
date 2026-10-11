# Bark2: PRD

Bark2 is Bark rebuilt from zero on macOS: push-to-talk dictation plus meeting
notes, both transcribed on the Mac, with the best Swedish accuracy available.
Meetings land in hq, where an agent turns them into notes and tasks. Goal: a
dictation app as good as Wispr Flow and a notetaker that replaces Granola for
a Swedish team.

Decisions locked with Erik (2026-10-12):
- Mac only, native Swift 6. Windows is rebuilt separately later (likely Rust).
  The two share no code; the contract is the hq API plus shared test fixtures.
- Meeting capture is IN (we are building the Granola replacement, no Granola test).
- Rebuild, not patch. Today's code is a reference for hard-won lessons, never
  a source to port.

## Problems to solve

Every problem today's Bark solves must be solved at least as well.

| # | Problem | Who | Today |
|---|---------|-----|-------|
| D1 | Hold a key anywhere, speak, text lands at the cursor | everyone | yes |
| D2 | Swedish and English accuracy, no compromise (the hard constraint) | Erik, team | yes, dual model |
| D3 | Little wait between speaking and seeing text | everyone | weak (one-shot decode at release, experimental chunker loses context) |
| D4 | Never invent text ("Thank you." on silence) | everyone | yes, energy gate |
| D5 | Works with any mic: multichannel interfaces, Bluetooth, hot-swaps, dead or quiet input explained | everyone | yes |
| D6 | Dictated text never touches disk; clipboard left as it was | everyone | yes, clipboard dance |
| D7 | Domain words right (Leadfabriken, CPL, client names) | Erik | weak (post-hoc replacements) |
| D8 | Install, permissions, updates without fuss; survives ANE hangs on some chips | everyone | yes |
| D9 | Feedback that reads at a glance: pill or notch, sounds | everyone | yes |
| M1 | Record a meeting with no bot, Me and Them never mixed | Erik, team | no |
| M2 | Who said what, with names | Erik, team | no |
| M3 | Swedish meeting accuracy (names, terms) | Erik, team | no |
| M4 | The routine: notes happen without remembering to take them | Erik | no (his stated gap 2026-10-10) |
| M5 | Your own notes kept apart from what the agent adds | Erik | no |
| M6 | Meetings become hq records tied to a client; action items become draft tasks | Erik | no |
| M7 | Ask across meetings ("what did we agree with Tegen") | Erik, Claude | no |

## Architecture

### Shape
- One Swift package, `BarkKit`, holding all logic, testable with `swift test`
  and no app host. A thin app target holds AppKit/SwiftUI only.
- Modules inside BarkKit: `Core` (pure rules: language routing decision, text
  clean-up, stream agreement, settings model), `Engine` (ASR, VAD, diarization
  wrappers), `Capture` (mic, process tap), `Store` (meetings on disk), `HQ`
  (API client).
- macOS 26 floor (Erik 2026-07-20: back-compat not a concern; this Mac is 27.0.1).
- Same identity as Bark: bundle ID `se.lab37.bark.mac`, same Sparkle feed and
  Developer ID, so existing users update into Bark2. Ships as Bark 1.0.
- Every dependency pinned to an exact version.

### Dictation
- Final text: kb-whisper-large for Swedish, whisper-large-v3 for everything
  else, on argmax-oss-swift (WhisperKit). Re-chosen on evidence: Parakeet v3
  measures ~16.8% Swedish WER on FLEURS against KB's 4.56%.
- Routing rule carried over as a pure, tested function: KB only on an explicit
  user language or a fresh detection on THIS audio of at least 1 s and 0.85
  confidence. A remembered language may prefill the general model, never route.
- Streaming: decode while recording, each window conditioned on the
  already-confirmed text, so release-to-paste only covers the last seconds and
  there are no context-free seams. Spike S1 decides the mechanism and must
  show no accuracy loss against one-shot decoding.
- Live preview (hypothesis): a fast volatile transcript in the notch while
  speaking, replaced by the final text. Spike S2.
- Speech gate: model VAD (Silero) if spike S3 beats the energy gate on both
  hallucinations and quiet voices; otherwise keep energy.
- Vocabulary (hypothesis): prompt the model with names and terms pulled from
  hq. Spike S6; risk is the model inserting prompt words that were not said.
- Insertion: AX insert into the focused field first; ⌘V with clipboard restore
  only as fallback, with the V key resolved from the current keyboard layout.
- Models live in `~/Library/Application Support/Bark/Models`, downloaded with
  checksums. Never `~/Documents`.
- Swedish model on by default only when the user's languages include Swedish.

### Meetings
- Capture: Core Audio process tap on the call app (system audio = Them) plus
  the mic (= Me), two streams, never mixed. Echo cancellation on the mic for
  laptop speakers (spike S4).
- Transcription: same engines, run per stream; Swedish routing per segment.
- Speakers: Them split by diarization in a final pass (spike S5 picks SpeakerKit
  or FluidAudio); names from calendar attendees, confirmed by the user.
- Detect and offer: Bark notices a call (calendar event from hq plus a call app
  producing audio) and offers to record with one click. Never auto-records.
- Notepad: the user's own notes during the call, kept apart from agent output.
  UI decided on rendered mockups with Erik before building.
- Store: SQLite on the Mac (meetings, segments, speakers, notes). Audio kept
  locally for a retention period Erik picks, so a better model can re-run it.
- Dictation's "never on disk" invariant stays scoped to dictation.

### hq
- Bark to hq: authenticated HTTPS API, per-device token in the Keychain.
  Push: finished meeting (transcript segments, speakers, user notes, attendees,
  calendar event id). Pull: upcoming calendar meetings, vocabulary.
- hq to agents: hq serves MCP tools over meetings (search, get, action items)
  for Claude and teammates.
- On arrival, hq's agent writes the summary, links the client and proposes
  draft tasks. Bark ships no LLM, so the on-device claim stays true.
- The hq endpoint setting is EMPTY by default; the public app never phones home.
- Which hq receives meetings is open (current hq or the LAB hq rebuild).
  Blocks phase P3 only.

## Lessons that become tests

Each one bit Bark once. Each gets a test or an eval case.
- Clips under 1 s decode empty unless `windowClipTime = 0`.
- `DecodingOptions.detectLanguage` misdetects; use the dedicated detection API.
- Whisper says "Thank you." on silence at noSpeechProb 0.00.
- Warmup must decode real silence and bypass the speech gate.
- KB-Whisper translates English into Swedish; routing needs fresh evidence.
- AVAudioConverter downmixes multichannel interfaces to digital zero.
- Loopback channels on an interface must not win channel selection.
- Event taps get disabled by the system and must be re-enabled.
- ANE decoder wedges on M1 and M2 Max; warmup under a timeout, self-heal to CPU+GPU.
- First KB load is a ~239 s one-time compile; needs progress and precompile.
- Capitalisation must not fire after abbreviations (bl.a., t.ex., e.g.).

## Evaluation harness (built first, gates everything)

- `bark-eval` CLI on the real shipping engine (CoreML, not whisper.cpp):
  FLEURS test sv and en (cached locally), WER with Whisper normalisation,
  latency per clip, run on the M5 Pro.
- Baseline first: today's July numbers came from whisper.cpp; the CoreML
  engine's FLEURS WER has never been measured.
- Later: Erik's own dictation clips and consented meetings, kept local, never
  committed.
- Gate: no model, dependency or decoding change merges if sv or en WER rises.

## Phases

- P0 Spikes, each a measured answer written into this file:
  - S0 baseline WER + latency of both models on WhisperKit CoreML.
  - S1 streaming with confirmed-text conditioning: WER vs one-shot, release-to-paste.
  - S2 SpeechAnalyzer Swedish as live preview: availability, lag, quality.
  - S3 Silero VAD vs energy gate: hallucinations on silence/noise, quiet speech kept.
  - S4 process tap + echo cancellation on laptop speakers.
  - S5 diarization on multi-speaker Swedish audio (public Riksdag debate audio).
  - S6 vocabulary prompting on KB: gain on terms vs inserted false words.
- P1 Dictation core: BarkKit + app shell, parity with every D-problem, eval gate.
- P2 Meetings: capture, transcription, speakers, store, notepad, detect-and-offer.
- P3 hq: API, MCP tools, agent pass (after the hq target is chosen).
- P4 Release as Bark 1.0 (Erik's go).

## What needs Erik

- About 30 minutes of his own Swedish/English dictation clips for the eval set.
- Two or three meetings recorded with consent, for diarization and real-world WER.
- Go to publish our KB-Whisper conversion (Apache 2.0, NOTICE crediting KBLab).
- Which hq receives meetings.
- Mockup approvals: notch preview, notepad, meeting view.
- Audio retention period for meetings.
