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
Re-decided on measurement 2026-10-12 (S1, S1d, S1e, S8); the spike sections
below hold the numbers.
- Engine: our own Whisper on Apple's mlx-swift (S8), not WhisperKit/CoreML.
  Same weights decode 3x faster (15 ms vs 45 ms per token) at equal or better
  WER, and owning the decode loop puts every past landmine (no-speech token,
  first-token threshold, timestamps) in our code. No WhisperKit, no CoreML,
  no ANE in the app; the ANE-wedge self-heal and the 239 s first compile go
  away with them.
- Models: kb-whisper-large for Swedish, whisper-large-v3 for everything
  else, MLX safetensors. 8-bit (group 64) is the default if the pipeline
  gate passes on every set (S8: identical on fleurs-sv, 18% faster, half the
  memory); fp16 otherwise.
- Tokenizer: our own, read from tokenizer.json (vocab id lookups and the
  GPT-2 byte decode S8 already uses). The vendored swift-transformers
  tokenizer mis-encodes KB (S8 landmine) and is the only reason the engine
  needs WhisperKit.
- Decode policy (S1b, S1e): forced language, no timestamps, no conditioning
  on earlier text, mlx_whisper's fallback ladder and thresholds; the
  no-speech token is allowed on audio of 1 s or more and a decode that opens
  with it is empty; under 1 s it is suppressed.
- Routing rule carried over as a pure, tested function: KB only on an explicit
  user language or a fresh detection on THIS audio of at least 1 s and 0.85
  confidence. Detection runs on the general model (first decoder step over
  the language tokens). A remembered language may prefill the general model,
  never route.
- Streaming (S1): Silero v6 (FluidAudio, threshold 0.5, 0.5 s pause) closes
  segments while the key is held; each closed segment is decoded at once,
  unprompted; release decodes only the open tail. Prompting and the confirm
  loop were rejected (slower, no accuracy gain); a short length cap was
  rejected (doubles Swedish WER, S1d). Segments stay under 30 s: an open
  segment that reaches 28 s is cut at the longest pause in its last 3 s.
- Language per dictation: decided on the first 1 s or more of speech and
  pinned for that dictation; shorter earlier segments wait for it. If the key
  is released first, it is decided on all the audio.
- D3 target (revised, S1e): release-to-paste p50 under 1.0 s and p95 under
  1.5 s for a 10 s dictation on the M5 Pro. One-shot MLX alone measures
  0.63 / 0.80 s on fleurs-sv.
- Speech gate: Silero (S3). No speech segment means nothing is pasted.
- Live preview: dropped. S2 is not needed; D3 is met without it.
- Vocabulary (hypothesis): prompt the model with names and terms pulled from
  hq. Spike S6; risk is the model inserting prompt words that were not said.
- Insertion: ⌘V with clipboard restore stays primary (ConcealedType marker,
  150 ms restore, never restore if changeCount moved), the V key resolved from
  the current keyboard layout. AX insert becomes primary per app only after a
  matrix passes (Slack, Chrome, Notion, Terminal, Teams, Mail, Xcode).
- Models live in `~/Library/Application Support/Bark/Models`, downloaded with
  checksums from a manifest. Never `~/Documents`.
- Swedish model on by default only when the user's languages include Swedish.
- Dev builds use bundle ID `se.lab37.bark.mac.dev` so they run beside the
  shipping Bark; release builds keep `se.lab37.bark.mac`.

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
- Clips under 1 s must decode (WhisperKit needed `windowClipTime = 0`;
  the MLX engine pads like mlx_whisper): short08 sets in the gate.
- A name as the first word must not end the decode empty (WhisperKit's
  `firstTokenLogProbThreshold`; the MLX engine has no such cut-off): an eval
  case with names first.
- Language detection is its own decoder step on the general model, never a
  decode option.
- Whisper says "Thank you." on silence at noSpeechProb 0.00, and KB says
  "Tack!" or "Musik" when its no-speech token is suppressed (S1e): the
  no-speech policy plus the Silero gate; noise sets must stay at 0 words.
- The tokenizer must not come from `encode()` for KB (prefix-space bug, S8),
  and a language code that is not in the vocab must fail loudly.
- Warmup must decode real silence and bypass the speech gate.
- KB-Whisper translates English into Swedish; routing needs fresh evidence.
- AVAudioConverter downmixes multichannel interfaces to digital zero.
- Loopback channels on an interface must not win channel selection.
- Event taps get disabled by the system and must be re-enabled.
- (WhisperKit era) The ANE decoder wedged on M1 and M2 Max and the first KB
  load was a ~239 s compile. Both go away with MLX; what remains: the first
  decode after install compiles Metal shaders (~4 s, S8), so warm up at launch.
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
- A single segment longer than 30 s must not reach the engine (one window):
  the segmenter's 28 s cut, and a test.

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
  gate. Release gate: our MLX KB-Whisper conversion is published (otherwise
  Swedish users get the general model); building does not wait for it.
  - P1a, BarkKit library (no UI): targets `BarkCore` (pure rules),
    `BarkEngine` (MLX Whisper, own tokenizer, language detection, Silero
    segmenter, dictation session), model store; `bark-eval --pipeline`
    runs clips through the session exactly as the app will.
  - P1b, the app on P1a: capture, hotkey, paste, notch/pill, settings,
    onboarding, Sparkle, model download.
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
pinned, windowClipTime 0, no detectLanguage, firstTokenLogProbThreshold nil
as in shipping fix 74446f7), no silence trimming. FLEURS test,
first 60 sentence ids per language after sorting by id (one recording per id,
first in file order). Both languages use ids 1660-1719; the list is in
`~/Library/Application Support/Bark/eval/sets/fleurs-{sv,en}/ids.txt`. WER is
corpus-level jiwer on `raw_transcription`, normalised with whisper-normalizer
(English normaliser for en, Basic for sv). M5 Pro, nothing else on the GPU/ANE.
Decode time is per clip, after load and a 3 s warmup, and includes WhisperKit's
own temperature-fallback retries.

| clips | model | WER | decode median | decode p90 | RTF |
|-------|-------|-----|---------------|------------|-----|
| sv | kb-whisper-large | **5.97%** | 2.00 s | 2.62 s | 0.173 |
| sv | whisper-large-v3 | 9.07% | 1.86 s | 2.47 s | 0.162 |
| en | whisper-large-v3 | **4.71%** | 1.34 s | 1.72 s | 0.119 |
| en | kb-whisper-large | 56.25% | 1.68 s | 2.48 s | 0.160 |

No empty outputs. Before the fix (WhisperKit default threshold -1.5) the same
run gave KB sv 5.97%, large-v3 sv 12.02%, large-v3 en 4.71%, KB en 56.32%.

July (whisper.cpp, different 60-clip selection): KB sv 4.56%, large-v3 sv
8.43%, large-v3 en 4.08%, KB en 40.85%.

**Does the CoreML engine match whisper.cpp? Not with WhisperKit's defaults;
yes for large-v3 once the threshold is off.** The models were fine; one
WhisperKit default was not:

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
- With `firstTokenLogProbThreshold = nil` (the table above) large-v3 sv drops
  from 12.02% to 9.07% and nothing rises.
- whisper.cpp (`whisper-cli` defaults, beam 5, `ggml-large-v3`, language
  pinned) on these exact 60 clips: large-v3 sv **8.91%**, en **4.63%**. So
  with the threshold off, CoreML large-v3 is within 0.2 points of whisper.cpp.
  The gap to July's 8.43% / 4.08% is the clip selection, not the engine.
- KB sv 5.97% vs July's 4.56% is not settled: the KB GGML used in July is no
  longer on disk, so whisper.cpp KB could not be rerun on these clips. The
  large-v3 clip-set shift (+0.5 sv) explains only part of it. See S0c.

Other observations:
- KB on English: 30 of 60 clips came back as Swedish text, 2 empty. The
  translation failure reproduces on CoreML and is worse than July (56% vs 41%).
- Two FLEURS sv references (1672, 1682) are shorter than what is spoken; every
  engine pays about 20 errors on them. Constant across runs, so harmless for
  the gate.
- KB loaded in 13.8 s here, not the 239 s first compile: the CoreML compile
  cache on this Mac was already warm. KB warmup (3 s of silence) took
  5.5-11.6 s against 0.5 s for large-v3; the app only warms the general model.

## S0c result (2026-10-12): is our KB conversion worse than the reference?

No. KBLab's own GGML (`ggml-model.bin` from the KBLab/kb-whisper-large repo,
fp16, kept in `~/Library/Application Support/Bark/eval/models/`) on whisper.cpp
1.9.1 (`BarkKit/eval/whispercpp.sh`, language pinned) against the same 60 sv
clips and the same normaliser:

| engine | model | decoding | sv WER |
|--------|-------|----------|--------|
| whisper.cpp | KBLab GGML | beam 5 (whisper-cli default, as July) | 5.97% |
| whisper.cpp | KBLab GGML | greedy (`-bs 1`) | 6.12% |
| CoreML (bark-eval) | our conversion | greedy, shipping config | **5.97%** |
| whisper.cpp | ggml-large-v3 | beam 5 | 8.91% |
| whisper.cpp | ggml-large-v3 | greedy | 9.38% |
| CoreML (bark-eval) | large-v3 | greedy, shipping config | **9.07%** |

- Greedy against greedy, 56 of 60 KB transcripts are identical to whisper.cpp
  after normalisation; the other 4 differ by a word (a numeral spelled out, a
  dropped "det", "nothen"/"nothern"). The conversion is faithful.
- Beam search is worth about 0.15 to 0.5 points on these clips. WhisperKit has
  no beam search, and greedy CoreML already equals beam-5 whisper.cpp on KB.
- July's 4.56% came from a different selection of clips, not a better engine.
  Every number from here on is on the fixed id list, so July's figures are no
  longer the reference.
- Nothing was reconverted.

## S0b result (2026-10-12): Parakeet TDT 0.6B v3

FluidAudio 0.17.7 (Apache 2.0, pinned exact), `AsrModels` v3 with its default
int8 encoder, `AsrManager` default config, no language hint (v3 has no
language pinning; its hint only filters scripts). Run by the eval-only
`fluid-eval parakeet` executable; no app-facing target links FluidAudio. Same
60-clip sets and normaliser as S0, decode time per clip after load and a 3 s
warmup.

| clips | model | WER | decode median | decode p90 | RTF |
|-------|-------|-----|---------------|------------|-----|
| sv | parakeet-tdt-0.6b-v3 | 16.74% | 0.05 s | 0.07 s | 0.005 |
| sv | kb-whisper-large (S0) | **5.97%** | 2.00 s | 2.62 s | 0.173 |
| en | parakeet-tdt-0.6b-v3 | 5.97% | 0.05 s | 0.09 s | 0.005 |
| en | whisper-large-v3 (S0) | **4.71%** | 1.34 s | 1.72 s | 0.119 |

- Parakeet is about 35 times faster and makes 2.8 times the Swedish errors
  of KB. The Swedish number matches the ~16.8% the PRD already cited.
- On English it trails large-v3 by 1.3 points.
- The model choice stands: KB for Swedish, large-v3 for everything else. If
  Parakeet earns a place, it is as the fast live preview (S2's slot), not the
  final text.
- Not measured: the int8-v2 encoder and FluidAudio's newer "Parakeet Ultra"
  model, which its README calls more accurate than v3.

## Harness v2 (2026-10-12), engine-only

`BarkKit/eval/run.sh` builds every set (`prep.py`), runs the shipping engine on
each route and gates with `score.py` against the committed
`BarkKit/eval/baseline.json` (one entry per set and model; metrics only, no
transcripts). `run.sh --write-baseline` rewrites it. Exit 1 on: a missing or
resized run, WER up 0.3 points absolute, more empty results than the baseline,
or any hallucinated word on a set whose baseline has none. Two back-to-back
runs gave identical numbers and exit 0; blanking three hypotheses exits 1.

Sets (data outside git under `~/Library/Application Support/Bark/eval/sets`):
- `fleurs-sv`, `fleurs-en`: the S0 clips, WER.
- `short08-*`, `short25-*`: the same clips cut to 0.8 s and 2.5 s, metric
  empty-result rate. Cut from speech onset (first 10 ms frame above 10% of the
  clip's loudest, minus 100 ms), not from the start of the file: FLEURS opens
  with a median 0.4 s of silence, so a plain first 0.8 s would often hold no
  speech and an empty result would be correct.
- `noise`: 28 generated clips, 1/3/6/10 s each of digital silence, pink room
  tone at -60 and -50 dBFS RMS, fan (hum plus rumble) at -45 and -35 dBFS RMS,
  and keyboard-like click bursts peaking at -30 and -15 dBFS. Seeded, so it
  regenerates identically. Metric: hallucinated words after normalisation.

Engine-only baseline:

| set | model | n | WER | empty | hallucinated words |
|-----|-------|---|-----|-------|--------------------|
| fleurs-sv | kb-whisper-large | 60 | 5.97% | 0 | - |
| fleurs-sv | whisper-large-v3 | 60 | 9.07% | 0 | - |
| fleurs-en | whisper-large-v3 | 60 | 4.71% | 0 | - |
| fleurs-en | kb-whisper-large (canary) | 60 | 56.25% | 0 | - |
| short08-sv | kb-whisper-large | 60 | - | **16** | - |
| short25-sv | kb-whisper-large | 60 | - | 0 | - |
| short08-en | whisper-large-v3 | 60 | - | 2 | - |
| short25-en | whisper-large-v3 | 60 | - | 0 | - |
| noise | kb-whisper-large | 28 | - | 28 | 0 |
| noise | whisper-large-v3 | 28 | - | 13 | **15** |

- **KB drops 27% of sub-1 s Swedish clips.** It emits its `<|nospeech|>`
  token as the first token at near-certainty (log prob about -1e-4), so the
  text comes back empty. large-v3 on the same 0.8 s Swedish clips returns
  text for all 60. At 2.5 s KB is fine. Today's app sends short clips to KB
  only on an explicit Swedish setting (auto routing needs at least 1 s), but
  that is exactly the "ja", "okej" case. Candidate fixes for P1: suppress the
  no-speech token on KB, or send sub-1 s audio to large-v3. Each needs its
  own measurement.
- Without a gate, large-v3 says "you" on digital silence and on keyboard
  clicks at every length, "Amen." on 1 s of fan, and "so" once. KB says nothing
  on any noise clip.
- Engine-only noise counts are recorded but cannot gate: with no speech gate
  in front of the decoder they are expected, and fallback sampling makes them
  random. The pipeline-mode noise baseline will be 0, which turns on the
  "any hallucination fails" rule.
- Full FLEURS test split (the PRD's gate size) and the pipeline mode are not
  built yet; the pipeline mode needs BarkKit's pipeline.

## S3 result (2026-10-12): Silero VAD vs the energy gate

`BarkKit/eval/s3.sh` puts a gate in front of the shipping decoder on each
route (sv clips to KB, en clips to large-v3), then `s3_score.py`. Gates:
- `energy`: today's `trimSilence`, ported verbatim (10 ms frames, RMS above
  0.01, 100 ms margin);
- `silero85` and `silero50`: FluidAudio 0.17.7 Silero v6 (`VadManager`,
  default segmentation, 0.1 s padding) at FluidAudio's default threshold 0.85
  and Silero's own default 0.5. Audio is trimmed from the first speech segment
  to the last;
- `none`: no gate.

Speech sets are the 60 FLEURS clips per language, each peak-normalised to
-6 dBFS (a well-gained mic) and then attenuated by 20 and 30 dB for soft
voices. A rejected clip is one the gate never hands to the decoder; WER is
over the clips that pass.

| speech | gate | sv rejected | sv WER | en rejected | en WER |
|--------|------|-------------|--------|-------------|--------|
| -6 dBFS peak | none | 0 | 6.05% | 0 | 4.42% |
| | energy | 0 | 5.89% | 0 | 4.85% |
| | silero 0.85 | 0 | 5.89% | 0 | 4.49% |
| | silero 0.5 | 0 | **5.74%** | 0 | 4.49% |
| -26 dBFS peak | none | 0 | 6.67% | 0 | 4.63% |
| | energy | 0 | 22.25% | 1 | 17.20% |
| | silero 0.85 | 0 | 6.28% | 0 | 5.55% |
| | silero 0.5 | 0 | **6.28%** | 0 | **4.92%** |
| -36 dBFS peak | none | 0 | 6.51% | 0 | 4.99% |
| | energy | **57 of 60** | 100% on the 3 | **60 of 60** | - |
| | silero 0.85 | 0 | 6.28% | 0 | 4.99% |
| | silero 0.5 | 0 | 6.43% | 0 | 4.85% |

| noise set (28 clips) | clips passed | hallucinated words, large-v3 | KB |
|----------------------|--------------|------------------------------|----|
| none | 28 | 15 | 0 |
| energy | 8 | 9 ("Thank you." twice on fan, "you" on clicks) | 0 |
| silero 0.85 | 0 | 0 | 0 |
| silero 0.5 | 0 | 0 | 0 |

- The energy gate fails both ways. A soft voice 20 dB down keeps its words
  but loses onsets and tails (kept audio falls from ~655 s to ~480 s), so WER
  triples to quadruples. At 30 dB down it rejects nearly everything. The gate
  lets fan at -35 dBFS and loud key clicks through, and large-v3 answers with
  "Thank you." and "you".
- Silero rejects every noise clip at both thresholds and no speech clip at any
  level. Its WER stays within 0.5 points of no gate at every level (-6 dBFS:
  5.74% sv, 4.49% en).
- At -6 dBFS the energy gate trims 5 to 6% of the audio, Silero 0.5 about
  11%, and neither costs words. FLEURS en as recorded peaks around -34 dBFS,
  and at that level today's energy gate rejects 30 of the 60 clips before any
  attenuation.
- Cost: Silero gated all 60 clips (706 s of audio) in 0.59 s wall time,
  including its model load. The energy gate took 0.08 s.

**Recommendation: replace the energy gate with Silero v6 at threshold 0.5.**
It matches or beats 0.85 everywhere, keeps more audio, and is the measurably
better one at -26 dBFS en (4.92% vs 5.55%).

Not covered: real-mic noise floors under quiet speech (these clips are
attenuated clean recordings), music, TV or other voices (any VAD passes
those), breath and mouth noise. Eval data stays outside git; Silero adds a
FluidAudio dependency to the app, which today is eval-only, so the switch is
P1 work behind the gate.

## S1b result (2026-10-12): KB drops sub-1 s Swedish

`BarkKit/eval/s1b.sh`. Fix (1): suppress KB's `<|nospeech|>` token with a
`SuppressTokensFilter` on `textDecoder.logitsFilters`
(`bark-eval --suppress-nospeech 1`). `DecodingOptions.suppressTokens` cannot
do it: 1.1.0 drops special tokens from that list. Fix (2): send sub-1 s audio
to large-v3 with language sv.

| set | KB today | (1) KB, no-speech suppressed | (2) large-v3 sv |
|-----|----------|------------------------------|-----------------|
| short08-sv empty | 16 of 60 | **4** | 1 |
| short25-sv empty | 0 | 0 | 0 |
| fleurs-sv WER | 5.97% | 6.12% | 5.97% (unchanged: no clip is under 1 s) |
| noise, no gate: hallucinated words | 0 | 7 ("Tack." on digital silence, "Musik" on loud clicks) | 15 (S0, en route) |
| noise behind Silero 0.5 (S3) | 0 | 0 | 0 |

What the 16 formerly empty clips now say (reference start, then (1), then (2)):
- "Det kan också vara": "Det kan" / "Det är ju".
- "På vissa rutter har": "På vissa rutter" / "På vis och rött."
- "Rör ihop de två": "" / "Tack till elever och personal vid Värmlands
  universitet."
- "Segregation och rekombination": "" / "Tack!"
- "Kongressen anslog medel": "<|" / "-".

**Recommendation: (1), applied only to audio under 1 s, behind the Silero
gate.**
- Option (1) recovers 12 of the 16 clips with words that are actually in the
  audio. Where it is unsure, it returns nothing.
- Option (2) empties fewer clips but invents whole sentences on two of them
  ("Tack till elever och personal vid Värmlands universitet."). That is the
  D4 failure we exist to prevent.
- Scoping (1) to sub-1 s audio keeps full-length Swedish at 5.97%. Without
  that scope it costs 0.15 points and gives up KB's clean record on noise.
- The behind-the-gate scope means the "Tack." risk only reaches the decoder
  when Silero passes a non-speech blip shorter than 1 s.
- (1) once leaked a literal "<|" as text. P1's text clean-up must strip it.
- Not measured as a separate run: the sub-1 s-only scope. Full-length
  behaviour is unchanged by construction, because the filter is set per call.

## S1 result (2026-10-12): streaming under a real-time feed

`BarkKit/Sources/stream-eval`, `BarkKit/eval/s1.sh`, `s1_score.py`. Each clip
fed in 100 ms blocks at wall-clock pace; release = last block in. dict = one
FLEURS clip released 0.3 s after its last word (60 per language); long = 4
consecutive clips joined (30 to 60 s, 15 per language). sv runs KB, en runs
large-v3; Bark's S1b short-clip fix on.

| set | mechanism | WER | release-to-final p50 / p95 | decoder busy per audio s |
|-----|-----------|-----|----------------------------|--------------------------|
| dict-en | one-shot (today) | 4.71% | 1.33 / 1.80 s | 0.12 |
| dict-en | confirm loop | 5.27% | 1.79 / 3.25 s | 0.86 |
| dict-en | Silero 0.5 s pause, no prompt | 4.71% | 1.13 / 1.91 s | 0.13 |
| dict-sv | one-shot (today) | 5.97% | 2.03 / 2.71 s | 0.18 |
| dict-sv | confirm loop | 6.20% | 2.71 / 4.64 s | 1.06 |
| dict-sv | Silero 0.5 s pause, no prompt | 5.89% | 1.73 / 2.75 s | 0.18 |
| long-en | one-shot (today) | **29.42%** | 3.77 / 4.87 s | 0.09 |
| long-en | Silero 0.5 s pause, no prompt | 22.19% | 1.58 / 2.95 s | 0.11 |
| long-sv | one-shot (today) | **17.05%** | 5.86 / 9.08 s | 0.15 |
| long-sv | Silero 0.5 s pause, no prompt | 9.15% | 2.74 / 4.77 s | 0.17 |

Full table (Silero 0.25 s, prompted variants): run `s1_score.py`.

- Prompting each segment with earlier text did not improve accuracy and
  made long dictations 2 to 2.5x slower at release (prompt tokens cost a
  decoder pass each). Dropped.
- The confirm loop (AudioStreamTranscriber style) keeps the decoder busy
  nonstop and is the slowest at release. Rejected.
- Silero segmentation without prompts is the winner, but only ~15% faster at
  release on normal dictations: read speech rarely pauses 0.5 s, so most of
  the utterance is still open at release.
- **D3 (p50 < 0.5 s) is not reachable with KB-large on this engine.** One
  decode of 1 s of audio costs ~0.5 s (July spike), so that is the floor.
  New D3 proposal: p50 < 1.0 s, p95 < 1.5 s for a 10 s dictation. Getting
  there needs a short open tail at release: force-close segments at a
  shorter pause or a length cap, measured next.
- The long-set deletions in every mechanism came from one bug, below.

## S1c result (2026-10-12): long dictations drop speech (shipping bug)

One-shot on 30 to 60 s dictations deleted 355 words (en) and 155 (sv): with
`withoutTimestamps = true`, WhisperKit can end a 30 s window early and seek
to the next window, skipping the speech in between (a 34 s clip returned 26
of 80 words). `bark-eval --timestamps 1 | --chunking vad`:

| set | today | timestamps | VAD chunking | both |
|-----|-------|-----------|--------------|------|
| long-en | 29.42% | **7.72%** | 12.29% | 11.52% |
| long-sv | 17.05% | 7.21% | 8.14% | **6.59%** |
| dict-en | 4.71% | 5.97% | | 5.97% |
| dict-sv | 5.97% | 6.67% | | 6.59% |

Timestamps fix long audio but cost ~1 point within one window. Rule: timestamps
on only when the audio exceeds 30 s. Shipped to today's Bark as d652c62
(p0-argmax-oss, built, not installed). Bark2: segments are VAD-closed and
capped under 30 s, so every decode stays inside one window; the rule stays
as a guard and as an eval case.

## S1d result (2026-10-12): a length cap buys latency with accuracy

`stream-eval --cap <s>`: Silero 0.5 s pause, no prompt, plus a forced cut once
the open segment reaches the cap, placed mid-way through the longest pause of
60 ms or more in its last 1.5 s (forced at 2x the cap if none). First 20 clips
of dict-sv:

| mechanism | WER | release-to-final p50 / p95 |
|-----------|-----|----------------------------|
| Silero, no cap (S1 winner) | 7.38% | 1.74 / 2.51 s |
| cap 5 s | 11.45% | 0.96 / 1.60 s |
| cap 3 s | 14.25% | 0.78 / 1.53 s |

Rejected: the cap meets the proposed D3 but doubles Swedish WER. Three causes,
all visible in the parts: short segments come back empty ("räkenskapsåret
2005", "säger Glen Cushing" lost), cuts still land inside words ("framträda"
became "framtid | Trädande") and KB loses context ("läckan" became
"läkaren"). Cutting a running utterance is off the table; the remaining lever
is the cost of the release decode itself. The first cut variant (quietest
20 ms frame) was worse on the same seams in a 5-clip smoke run.

## S1e result (2026-10-12): the release wait is the engine, and MLX cuts it 3x

`bark-eval` now logs WhisperKit's own timing split and takes `--encoder` /
`--decoder gpu|ane|all`. One-shot decode of a ~10 s dictation, medians:

| route | total | encoder | decoder loop | tokens | per token |
|-------|-------|---------|--------------|--------|-----------|
| sv, KB-large | 2.13 s | 0.31 s | 2.12 s | 47 | 45 ms |
| en, large-v3 | 1.39 s | 0.11 s | 1.39 s | 32 | 44 ms |

- The wait is the token-by-token decoder, not the encoder. Compute placement
  barely moves it: KB decoder on GPU p50 1.93 s (p95 worse, 3.36 s), on
  `.all` 1.89 s, encoder on the ANE 2.02 s; text identical in every case.
- argmax's `openai_whisper-large-v3_turbo` is NOT OpenAI's 4-layer turbo: it
  ships the same 1.7 GB 32-layer decoder (plus a prefill model) and produced
  identical transcripts. No smaller-decoder test was run.
- 45 ms per token for a 1.7 GB decoder is far below what this Mac's memory
  bandwidth allows, so the overhead is the CoreML path. Same weights on MLX
  (`mlx-whisper`, fp16; KB converted locally with Apple's mlx-examples
  `convert.py`, not uploaded):

| set | engine | WER | release decode p50 / p95 | per token |
|-----|--------|-----|--------------------------|-----------|
| dict-sv | WhisperKit CoreML (today) | 5.97% | 2.02 / 2.75 s | 45 ms |
| dict-sv | MLX fp16 | **5.89%** | **0.66 / 0.89 s** | 15 ms |
| dict-en | WhisperKit CoreML (today) | 4.71% | 1.38 / 1.84 s | 44 ms |
| dict-en | MLX fp16 | **4.35%** | **0.51 / 0.64 s** | 18 ms |

(greedy, no fallback, M5 Pro.) One-shot MLX meets the proposed D3 with no
streaming at all, and Silero segmentation shortens it further.

Full harness on MLX (`score.py` gate against the CoreML baseline, fallback
ladder on, same thresholds as WhisperKit):

| set/model | CoreML WER | MLX WER | MLX median decode |
|-----------|-----------|---------|-------------------|
| fleurs-sv/swedish | 5.97% | 5.81% (5.66% with the no-speech policy) | 0.67 s (CoreML 2.01 s) |
| fleurs-en/general | 4.71% | 4.56% | 0.52 s |
| fleurs-sv/general | 9.07% | 9.38% (gate +0.31, slack 0.30) | 0.67 s |

Gate failures and what they are:
- **noise/swedish, 28 hallucinated words** ("Tack!", "Musik" on every noise
  clip; CoreML 0). mlx-whisper always suppresses the no-speech token, and KB
  never raises `no_speech_prob` at the start position (0.00 on noise and
  speech alike), so the standard skip rule cannot fire. KB says "silence" by
  generating the no-speech token, which WhisperKit turns into empty text.
  Policy for Bark2's decoder: let the token through on audio of 1 s or more,
  a decode that opens with it is empty; under 1 s keep it suppressed (S1b).
  Measured: noise 28/28 empty, short25-sv 0 empty, fleurs-sv 0 empty and WER
  5.66%.
- short08-en/general, 5 empty vs 2: MLX returns empty where CoreML returned
  junk ("*Gunshot*", "you") on 0.8 s clips. Accepted: empty is the better
  failure for dictation. Rebaseline.
- fleurs-en/swedish 63.8% vs 56.3%: KB on English is the translation canary,
  not a route. fleurs-sv/general +0.31: v3 is only the low-confidence fallback
  for Swedish; watch it in the Swift port.

Verdict: switch the Bark2 engine from WhisperKit/CoreML to MLX. 3x faster at
release on both routes with WER equal or better. Next: spike S8, a Swift MLX
Whisper decoder (mlx-swift; mlx-audio-swift as reference, not a dependency)
that owns the decode policy above and must reproduce these numbers. Costs to
measure there: GPU instead of ANE (power, and S7's 90-minute budget), model
memory (fp16 KB 3.1 GB; try 8-bit), load and first-decode time.

## S8 result (2026-10-12): Swift MLX engine

`BarkKit/Sources/mlx-eval` is a small Swift port of mlx_whisper 0.4.3 on
mlx-swift 0.32.3: log-mel, encoder, decoder with KV cache, greedy decode with
the fallback ladder, and the S1e no-speech policy. It does no language
detection. `BarkKit/eval/mlx.sh` runs run.sh's matrix into
`eval/mlx/results` and scores it. Python is the S1e proof: the `nsa` policy
runs where they exist (noise/KB, short25-sv/KB, fleurs-sv/KB), otherwise the
no-policy runs. Medians are on this M5 Pro.

| set/model | Swift WER | Python WER | same transcript | median Swift / Python |
|-----------|-----------|------------|-----------------|-----------------------|
| fleurs-sv/swedish | 5.80% | 5.80% (5.66% incl. 1716) | 59/59 | 0.63 / 0.66 s |
| fleurs-sv/general | 9.35% | 9.35% (9.38%) | 59/59 | 0.62 / 0.66 s |
| fleurs-en/general | 4.56% | 4.56% | 59/60 | 0.48 / 0.52 s |
| fleurs-en/swedish (canary) | 63.97% | 63.83% | 57/60 | 0.54 / 0.58 s |
| noise/swedish | 28/28 empty | 28/28 empty | 28/28 | 0.19 / 0.21 s |
| noise/general | 0 empty, 40 words | 0 empty, 40 words | 28/28 | 0.19 / 0.22 s |
| short08-sv/swedish | 0 empty | 0 empty | 58/60 | 0.22 / 0.25 s |
| short08-en/general | 5 empty | 5 empty | 58/60 | 0.21 / 0.24 s |
| short25-sv/swedish | 0 empty | 0 empty | 59/60 | 0.30 / 0.33 s |
| short25-en/general | 0 empty | 0 empty | 59/60 | 0.27 / 0.30 s |

- Overall, 524 of 534 transcripts are byte-identical. 4 of the 10 that differ
  are short08 clips decoded at a fallback temperature, which is random
  sampling and so differs on every run (in the first run, short08-sv 1664 came
  back empty). The other 6 are greedy fp16 drift: Python ran MLX core 0.31.1
  and mlx-swift 0.32.3 bundles core 0.32.2. Example: fleurs-en 1712, "Bengal
  tigers" vs "Bengal Tigers". fleurs-sv has no differing clips.
- Python timing includes ffmpeg loading the file. Swift times from samples in
  memory to text. Swift is 4 to 8% faster on the median.
- Load, after the weights are in the page cache: 0.4 to 0.8 s. The first load
  of the session took 2.0 s. First decode (a FLEURS clip, right after load):
  0.5 to 0.7 s, so warm-up costs nothing beyond one decode. The very first run
  after the build took 3.8 s (Metal shader cache). Memory (MLX
  `Memory.peakMemory`): fp16 KB or large-v3 is 3.09 GB active after load and
  4.03 GB peak while decoding.
- Bonus, 8-bit KB (MLX affine quantize, group 64, Linear and Embedding layers,
  conv stays fp16; quantized once in Python, loaded through config.json
  `quantization`): fleurs-sv WER 5.80% with 59/59 transcripts identical to
  fp16, median 0.52 s (-18%), 1.66 GB after load, 2.52 GB peak. The fp16 build
  has no accuracy advantage over it on this set.

Policy behaviour: noise/KB is 28/28 empty, as in Python. noise/general
hallucinates 40 words with the policy on: none of the 28 decodes opens with
the no-speech token, and the no_speech_prob skip never fires (an outcome; the
probability itself was not logged). So the large-v3 route depends on the
Silero gate in front of it (CoreML: 13 empty, 15 words).
short08-en/general's 5 empties are the S1e "rebaseline" case.

Landmines:
- **The vendored tokenizer's `encode` is wrong for KB.** argmax-oss-swift
  vendors swift-transformers inside ArgmaxCore, exposed through `WhisperKit`
  as `AutoTokenizerWrapper`. There is no separate swift-transformers package
  in the graph. Its ByteLevel pre-tokenizer prefixes a space to *every* regex
  piece when `add_prefix_space` is set, and KB's tokenizer.json sets it
  (openai's does not), so `encode("(")` returns `" ("`. The engine therefore
  never calls `encode`: suppress sets come from direct vocab lookups and match
  mlx_whisper's 82 non-speech tokens exactly on both tokenizers. Anything that
  encodes text for KB in Swift (prompts, prefixes) inherits this bug.
- **`tokenizer.decode` differs from tiktoken for large-v3.** openai's
  tokenizer_config sets `clean_up_tokenization_spaces` (" ." becomes ".",
  " 's" becomes "'s"); KB's does not. The engine decodes byte-level BPE
  itself.
- **`convertTokenToId` returns the unk id (`<|endoftext|>`) for unknown
  strings**, so a bad language code silently becomes EOT. The engine checks
  the round trip.
- Input parity: ffmpeg rounds float to s16 half-up (`floor(x*32768 + 0.5)`),
  not to nearest even. mlx-eval quantizes the same way so per-clip diffs
  measure the engine (eval only; the app feeds floats). With that, the Swift
  mel segment and mel filters (Slaney, computed, not loaded) are bit-identical
  to Python's.
- fleurs-sv clip 1716 is 31.4 s. mlx-eval decodes one 30 s window and stops
  with an error on anything longer, so mlx.sh scores fleurs-sv on a filtered
  copy of 59 clips. That is why score.py reports "59 clips, baseline 60" in
  its REGRESSION lines. A seek loop is needed before long dictations bypass
  the Silero cap.
- mlx-swift's README says SwiftPM cannot build the Metal shaders. With Xcode
  26's SwiftPM it does (`mlx-swift_Cmlx.bundle/default.metallib`), with
  identical output, so mlx.sh uses `swift build` like run.sh. The xcodebuild
  fallback command is in the script.
- The weights carry `alignment_heads` (word timestamps). The loader drops it
  and otherwise verifies `noUnusedKeys`.

Verdict: the Swift engine reproduces the Python MLX numbers (WER equal on
every route, fleurs-sv transcript-identical, 3x faster than CoreML holds). Run
KB at 8-bit: same transcripts, 18% faster, half the memory. Not measured yet:
power on the GPU versus the ANE (S7), and a cold load straight from disk.
