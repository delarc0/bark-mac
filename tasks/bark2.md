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
- Live preview (hypothesis, conditional): a fast volatile transcript in the
  notch while speaking, replaced by the final text. Spike S2 runs only if S1
  misses the D3 target.
- D3 target: release-to-paste p50 under 0.5 s and p95 under 1.0 s for a 10 s
  dictation on the M5 Pro (today's app is measured first as the baseline).
- Speech gate: model VAD (Silero) if spike S3 beats the energy gate on both
  hallucinations and quiet voices; otherwise keep energy.
- Vocabulary (hypothesis): prompt the model with names and terms pulled from
  hq. Spike S6; risk is the model inserting prompt words that were not said.
- Insertion: ⌘V with clipboard restore stays primary (ConcealedType marker,
  150 ms restore, never restore if changeCount moved), the V key resolved from
  the current keyboard layout. AX insert becomes primary per app only after a
  matrix passes (Slack, Chrome, Notion, Terminal, Teams, Mail, Xcode).
- Models live in `~/Library/Application Support/Bark/Models`, downloaded with
  checksums. Never `~/Documents`.
- Swedish model on by default only when the user's languages include Swedish.

### Meetings
- Three modes (proposed, Erik to confirm in-person scope):
  - call: Core Audio process tap on the call app (system audio = Them) plus
    the mic (= Me), two streams, never mixed;
  - in person: mic only, diarization on the mic stream, no Me/Them;
  - hybrid (room plus remote): both streams diarized, Me = dominant mic
    speaker, confirmed by the user.
- Echo cancellation on the mic for laptop speakers (spike S4).
- Transcription: final-quality decode of VAD-closed segments DURING the
  meeting (the S1 mechanism), so stop is near-instant and there is no second
  pass. No volatile live pass for meetings.
- Language is explicit when the meeting is armed (default: last meeting, later
  the client's language from hq); Auto is a choice, not the default. This uses
  the routing rule's explicit-language branch, so short segments of a Swedish
  meeting still go to KB.
- Speakers: diarization (spike S5 picks SpeakerKit or FluidAudio); names from
  calendar attendees once P3 exists, confirmed by the user.
- Detect and offer: in P2 on the audio signal alone (a known call app or a
  browser holds the mic); P3 adds calendar enrichment. Call-app list named in
  code; tapping a browser captures every tab, and the UI says so. Never
  auto-records.
- Durability (losing a client meeting is the worst failure):
  - audio appended to disk per stream as captured, never held in RAM;
  - segments committed to SQLite as they are decoded;
  - an unfinished meeting found on relaunch is offered to finish;
  - a power assertion is held while recording; on wake, capture is rebuilt
    and a gap marker written;
  - the push to hq is a durable queue; the local record stays until hq
    acknowledges; deleting a meeting in hq deletes it on the Mac.
  Each of these is a test.
- Budget (spike S7): a 90-minute two-stream meeting on the M5 Pro and on the
  slowest team Mac, on battery. Targets: final transcript within 2 minutes of
  stop, app responsive throughout; ANE/CPU load, thermal state, battery drain
  and peak memory recorded.
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
- `firstTokenLogProbThreshold` (WhisperKit-only default -1.5) ends the decode
  at zero tokens when the first word is uncertain (a name), so the result is
  empty. Set it to nil. Found by S0: 2 of 60 sv clips empty on large-v3.
- `DecodingOptions.detectLanguage` misdetects; use the dedicated detection API.
- Whisper says "Thank you." on silence at noSpeechProb 0.00.
- Warmup must decode real silence and bypass the speech gate.
- KB-Whisper translates English into Swedish; routing needs fresh evidence.
- AVAudioConverter downmixes multichannel interfaces to digital zero.
- Loopback channels on an interface must not win channel selection.
- Event taps get disabled by the system and must be re-enabled.
- ANE decoder wedges on M1 and M2 Max; warmup under a timeout, self-heal to CPU+GPU.
- First KB load is a ~239 s one-time compile; needs progress and precompile.
- Capitalisation must not fire after abbreviations (bl.a., t.ex., e.g.); this
  is a live bug in today's app.
- A key release can be swallowed (screen lock, secure input, a disabled tap):
  hard stop at the max duration, re-check key state when the tap re-enables.
- Holds under 200 ms are accidental taps.
- A revoked mic grant feeds digital silence (dead input, explain it); a
  Bluetooth device with zero callbacks is transient (retry), not dead.
- Right Option is isolated from left by the device-specific flag mask.
- Clipboard: wait 150 ms before restoring (Electron), never restore if the
  changeCount moved, mark dictation with org.nspasteboard.ConcealedType or
  clipboard managers archive it to disk.
- The mic grant is requested on the first press, and a still-held press starts
  once granted.
- A sample-rate change mid-capture restarts capture instead of pitch-shifting.
- Every decode runs under a timeout; a hung task is orphaned, the app recovers.
- Package.resolved is committed so transitive dependencies cannot float.

## Evaluation harness (built first, gates everything)

- `bark-eval` CLI on the real shipping engine (CoreML, not whisper.cpp),
  run on the M5 Pro. Two modes: engine-only, and whole pipeline through
  BarkKit exactly as the app calls it (speech gate, trim, routing,
  post-processing).
- Baseline first: today's July numbers came from whisper.cpp; the CoreML
  engine's FLEURS WER has never been measured. S0 starts on 60 clips per
  language; the gate uses the full FLEURS test split for both languages.
- Sets, each with its own metric:
  - FLEURS sv and en: WER, Whisper normalisation;
  - silence and noise: hallucinated words must be 0;
  - sub-1 s and 1 to 3 s clips: empty-result rate;
  - mixed sv/en: KB-on-English routes must be 0, language-ID accuracy;
  - Erik's term list (from his clips): term recall;
  - dictation timing: release-to-paste p50/p95.
- A committed baseline JSON per model and set. Scoring exits non-zero on WER
  up 0.3 absolute, or any hallucination or routing regression. Results are
  recorded in the commit body and on the hq task.
- Erik's own clips and consented meetings stay local, never committed.
- Engine tests run when models are on disk and are skipped otherwise; they do
  not pretend to run in CI.

## Phases

- P0 Spikes, each a measured answer written into this file. Order:
  - S0 baseline WER + latency on WhisperKit CoreML, plus Parakeet v3 (via
    FluidAudio) on the same clips and normaliser, so the model choice rests
    on one measurement.
  - S3 Silero VAD vs energy gate: hallucinations on silence/noise, quiet
    speech kept. Before S1, because S1's segment boundaries depend on it.
  - S1 and S4 in parallel:
    - S1 streaming with confirmed-text conditioning (argmax 1.1.0 has
      promptTokens, prefixTokens and AudioStreamTranscriber confirmed
      segments): WER vs one-shot must not rise; release-to-paste vs D3.
    - S4 process tap, pass criteria named up front: per-process vs global tap
      with Bark excluded; permission UX and how a denial is told apart from
      the known all-zero-buffer bug on macOS 26/27; AEC on vs off as Me-stream
      WER and bleed rate (share of Them words in the Me transcript) on laptop
      speakers; AirPods (HFP) vs wired Me-stream WER.
  - S5 diarization: needs a mic-only multi-speaker recording (in-person
    crosstalk, room acoustics) as well as a call; blocked on Erik's
    recordings.
  - S6 vocabulary prompting on KB: gain on terms vs inserted false words.
  - S7 long-meeting budget (see Meetings).
  - S2 SpeechAnalyzer Swedish preview: only if S1 misses D3.
- P1 Dictation core: BarkKit + app shell, parity with every D-problem, eval
  gate. Gate: our KB-Whisper conversion is published (otherwise Swedish users
  get the general model).
- P2 Meetings: capture, transcription, speakers, durable store, notepad,
  detect-and-offer on audio.
- P3 hq: API, MCP tools, agent pass, calendar enrichment (after the hq target
  is chosen; verify hq can read each teammate's calendar, not only Erik's).
- P4 Release as Bark 1.0 over 0.2.3 (Erik's go). Checklist:
  - appcast item carries sparkle:minimumSystemVersion 26.0, so 0.2.3 installs
    on macOS 14/15 are not offered a build that will not launch;
  - CURRENT_PROJECT_VERSION above 5;
  - settings in the shared UserDefaults domain: hotkey, device UID and
    language migrate, everything else resets (stated in release notes);
  - models moved from ~/Documents/huggingface to Application Support, not
    re-downloaded and recompiled;
  - release only from main with a tag (release.sh gets a branch guard).

## What needs Erik

- About 30 minutes of his own Swedish/English dictation clips for the eval set.
- Two or three meetings recorded with consent, for diarization and real-world WER.
- Go to publish our KB-Whisper conversion (Apache 2.0, NOTICE crediting KBLab).
  Gates P1.
- Which hq receives meetings.
- Mockup approvals: notch preview, notepad, meeting view.
- Audio retention period for meetings. Proposed default so the build does not
  wait: audio 30 days, transcripts kept.
- Notice practice when recording clients (a line in the invite, or said at
  the start). A decision, not a feature.
- Whether in-person and hybrid meetings are in scope (proposed: yes).
- The team's Macs (chip, macOS version) for the S7 budget run.

## S0 result (2026-10-12)

Harness: `BarkKit/eval/run.sh` (prep, release build of `bark-eval`, matrix,
score). Engine config identical to shipping `Transcriber` (argmax-oss-swift
1.1.0, encoder cpuAndGPU, decoder cpuAndNeuralEngine, prefill on, language
pinned, windowClipTime 0, no detectLanguage), no silence trimming. FLEURS test,
first 60 sentence ids per language after sorting by id (one recording per id,
first in file order). Both languages use ids 1660-1719; the list is in
`~/Library/Application Support/Bark/eval/fleurs/{sv,en}/ids.txt`. WER is
corpus-level jiwer on `raw_transcription`, normalised with whisper-normalizer
(English normaliser for en, Basic for sv). M5 Pro, nothing else on the GPU/ANE.
Decode time is per clip, after load and a 3 s warmup, and includes WhisperKit's
own temperature-fallback retries.

| clips | model | WER | decode median | decode p90 | RTF |
|-------|-------|-----|---------------|------------|-----|
| sv | kb-whisper-large | **5.97%** | 1.98 s | 2.63 s | 0.181 |
| sv | whisper-large-v3 | 12.02% | 1.83 s | 2.54 s | 0.166 |
| en | whisper-large-v3 | **4.71%** | 1.31 s | 1.69 s | 0.117 |
| en | kb-whisper-large | 56.32% | 1.68 s | 2.79 s | 0.170 |

July (whisper.cpp, different 60-clip selection): KB sv 4.56%, large-v3 sv
8.43%, large-v3 en 4.08%, KB en 40.85%.

**Does the CoreML engine match whisper.cpp? Not as shipped.** The models are
fine; one WhisperKit default is not:

- `DecodingOptions.firstTokenLogProbThreshold` defaults to -1.5 (WhisperKit
  only; whisper.cpp and openai-whisper have no such rule). When the first word
  is uncertain, typically a proper noun ("Huhne", "Cochamó"), the segment is
  aborted with zero tokens, every temperature fallback retries, and the clip
  can come back EMPTY. Two of 60 sv clips on large-v3 returned "" (44 of its
  155 errors) at 3.5-6.6 s decode; KB returned one empty clip on a rerun.
  Because fallback sampling is random, which clips go empty varies run to run.
  Shipping Bark has the same default, so a dictation that starts with a name
  can silently paste nothing. `suppressBlank` does not help; disabling prefill
  does, but only because it changes the prompt path.
- Same harness with only `firstTokenLogProbThreshold = nil` (scratch run, not
  committed): KB sv 5.97%, large-v3 sv **9.07%**, large-v3 en 4.71%, KB en
  56.25%, no empty outputs.
- whisper.cpp (`whisper-cli` defaults, beam 5, `ggml-large-v3`, language
  pinned) on these exact 60 clips: large-v3 sv **8.91%**, en **4.63%**. So
  with the threshold off, CoreML large-v3 is within 0.2 points of whisper.cpp.
  The gap to July's 8.43% / 4.08% is the clip selection, not the engine.
- KB sv 5.97% vs July's 4.56% is not settled: the KB GGML used in July is no
  longer on disk, so whisper.cpp KB could not be rerun on these clips. The
  large-v3 clip-set shift (+0.5 sv) explains only part of it.

Other observations:
- KB on English: 30 of 60 clips came back as Swedish text, 2 empty. The
  translation failure reproduces on CoreML and is worse than July (56% vs 41%).
- Two FLEURS sv references (1672, 1682) are shorter than what is spoken; every
  engine pays about 20 errors on them. Constant across runs, so harmless for
  the gate.
- KB loaded in 13.8 s here, not the 239 s first compile: the CoreML compile
  cache on this Mac was already warm. KB warmup (3 s of silence) took
  5.5-11.6 s against 0.5 s for large-v3; the app only warms the general model.

Next: decide `firstTokenLogProbThreshold = nil` for Bark2 (it passes the gate:
sv large-v3 -2.95 points, nothing rises) and rerun KB on whisper.cpp if the
4.56% vs 5.97% question matters.
