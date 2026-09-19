# Bark Notetaker: PRD

Bark records the meeting you are already in, transcribes both sides on-device,
labels who said what, and files the result in hq. No bot joins the call, no
audio leaves the Mac, and the thinking is done by Claude Code against hq, not by
a model inside Bark.

Reference product: Wispr Flow Notetaker (shipped 2026-08). Same capture model,
different transcription quality on Swedish, and an output surface Wispr does not
have.

## Decisions locked

Three forks were closed with Erik before this was written. They are not open.

1. **Who v1 is for: Erik, and hq is the output.** Bark captures, transcribes and
   diarizes. It does NOT summarize. No LLM ships inside Bark, no API key, and
   the "100% on-device" claim in README.md stays literally true. Summarization
   and routing are done by Claude Code, which already knows the clients, the
   board and the vocabulary.
2. **A meeting lives in hq as a first-class object.** Bark posts the finished
   transcript to hq over an authenticated write path. Meetings become searchable
   records tied to a client, and their action items become real linked hq tasks.
3. **Detect and offer, one click to arm.** Bark notices a call and offers to
   record. It never starts on its own. No silently armed microphone.

## Why build this instead of paying for Wispr

Measured on FLEURS, 60 clips per language, on the M5 Pro (`tasks/kb-whisper-spike.md`):

| model            | sv WER    | en WER              |
|------------------|-----------|---------------------|
| kb-whisper-large | **4.56%** | 40.85% (unusable)   |
| whisper-large-v3 | 8.43%     | **4.08%**           |

Wispr, Granola and Otter run general models on Swedish. Almost every meeting
worth recording here is a Swedish client meeting, full of names, company terms
and domain words that a general model turns to mush. Halving the error rate on
the language the meetings are actually in is the entire product argument.

The catch: the dual-model routing that spike decided is still not implemented.
`Transcriber` holds a single `modelVariant`. Notetaker is what finally lands it,
and dictation gets the same upgrade for free.

## Non-goals

- No summarization, action-item extraction or "AI notes" inside Bark. Decision 1.
- No bot that joins a call as a participant.
- No Windows. Windows Bark is a separate Python product and stays dictation-only.
- No iOS or mobile.
- No live translation.
- No transcript editing inside Bark. Once uploaded, hq owns the record.
- No cross-meeting voice enrollment. Pyannote clusters speakers within a single
  meeting; recognizing "this is Jesper again" across meetings is v2.
- No new `tasks.kind` value. That set is pinned in `schema.ts` and does not grow
  without Erik.

## Architecture

### Capture: two streams, never mixed

macOS 14.4 added CoreAudio process taps, which read a copy of what the machine
is playing with no virtual driver (no BlackHole, no Loopback) and no bot. This
is the same mechanism Wispr uses.

- `AudioHardwareCreateProcessTap` with a `CATapDescription`, then
  `AudioHardwareCreateAggregateDevice` combining that tap with the current mic
  input device. Format from `kAudioTapPropertyFormat`, capture via
  `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`.
- Info.plist needs `NSAudioCaptureUsageDescription`. There is no public API to
  query or pre-request this permission: the prompt fires on first capture. So
  onboarding cannot check it, and the app must detect denial by noticing the tap
  yields digital silence while the mic does not.
- Reference implementation to read first: `insidegui/AudioCap`. The API is
  poorly documented and the sample is the fastest way in. Do not copy its
  private-TCC permission probe.

**The aggregate device is the diarization shortcut.** System audio is THEM, mic
is YOU. Kept as separate streams, that is hard speaker separation with no model
at all, which is exactly Wispr's live You/Them labeling.

This means a new `MeetingRecorder`, NOT a reuse of `AudioRecorder`. Two pieces of
existing logic would actively destroy the separation:

- the mono downmix in `installCapture()`, which sums channels, and
- the loudest-channel latch (`selectedChannel`, `channelLatchLevel`), which picks
  one channel and discards the rest.

Both are correct for dictation off a multichannel interface and wrong here. Each
stream gets its own converter to 16 kHz mono Float32, independently.

**Known hard problem: speaker bleed.** On headphones the separation is clean. On
laptop speakers, the other party's audio comes back in through the mic, so THEM
also appears in YOUR channel and Bark will attribute their words to Erik. v1
supports headphones as the reliable path and treats speakers as best-effort,
with a per-frame energy comparison between the two streams (system channel hot
and strongly correlated with the mic channel means attribute to THEM). Say this
plainly in the UI rather than shipping confidently wrong labels.

### Transcription: land the dual-model decision

- Route by language: `sv` to kb-whisper-large, everything else to
  whisper-large-v3 full (not turbo). KB-Whisper must never see English: it does
  not degrade, it silently translates English audio into Swedish.
- Convert kb-whisper-large ourselves with whisperkittools from KBLab's official
  checkpoint. Do not ship third-party community weights, and verify the
  conversion matches the GGML reference output.
- First load of a freshly converted CoreML model is a ~239s one-time ANE compile.
  Precompile right after download and show progress, or the first meeting looks
  like a hang.

**Migrate WhisperKit 0.18 to `argmaxinc/argmax-oss-swift`** (SPM, MIT, README
pins `from: "0.9.0"`). 0.18 is end-of-line and SpeakerKit only exists in the
successor package, so Notetaker forces a migration that was already planned.
Take the `WhisperKit` and `SpeakerKit` products; skip `TTSKit`.

Carry forward and **re-verify against the new package** every 0.18 landmine, all
of which cost real debugging time:

- `windowClipTime = 0`, or any audio under 1s decodes deterministically empty.
- The silence guard: Whisper hallucinates "Thank you." on speechless audio with
  `noSpeechProb` 0.00, so WhisperKit's own gate can never catch it. `trimSilence`
  returning nil is the fix. **Coupling:** warmup decodes 3s of silence by design
  and must keep bypassing the guard via `warmupDecode()`, or warmup silently
  stops priming.
- Never set `DecodingOptions.detectLanguage`. Use the explicit
  `detectLangauge(audioArray:)` call (the typo is theirs) plus the per-session
  pin, confidence >= 0.5 and >= 1s of speech.
- The ANE decoder wedge and `warmupSelfHealing()`. Confirmed on M1 and M2 Max.

### Two passes, like Wispr

- **Live pass** (during the meeting): the existing `StreamingChunker` per stream,
  cheap and volatile, so Erik can see it is working. Accuracy is not the job here.
- **Final pass** (on stop): re-transcribe each full stream with the language
  pinned and no chunk boundaries. This is where the quality comes from. Chunked
  streaming output is never what gets filed.

### Diarization: only on THEM

`SpeakerKit` runs Pyannote v4 (community-1) on CoreML: `diarize(audioArray:options:)`
with `PyannoteConfig` / `PyannoteDiarizationOptions`, then `addSpeakerInfo(to:)`
with the `.subsegment` strategy to attach speakers to Whisper segments. It is
batch, not streaming, which fits the final pass exactly.

It runs on the system-audio stream only. YOU is already known from the mic, so
half the problem is already solved and the clustering gets easier.

Seed `numberOfSpeakers` from the calendar attendee count when hq supplies one.
Knowing there are three people in the room is a large accuracy win over letting
the clusterer guess.

Clusters that cannot be named stay "Speaker 2" until renamed once in hq, where
the mapping persists against a contact.

### Calendar: ask hq, not the Mac

hq already reads Google Calendar server-side (`src/lib/calendar/google.ts`, with
the `visibleCalendars` privacy gate, as used by `/api/ops/calendar`). Bark is
already authenticating to hq for the upload, so it asks hq "what is on the
calendar right now" and gets back title, attendees and the matching company.

No EventKit, no Google OAuth inside a notarized Mac app, no new credential
sitting on a laptop that travels. Attendee domain maps to a `companies` row, so
a meeting lands on the right client without being told.

### Persistence

Bark's current invariant is that dictated text never touches disk. A notetaker
cannot exist under that rule, so **scope the invariant to dictation** and write
that scoping into CLAUDE.md, or a future session will "fix" it back.

- Audio: `~/Library/Application Support/Bark/Meetings/<uuid>/`, the two streams
  kept separately.
- Audio is deleted once the final pass succeeds and hq acknowledges the upload.
  Default is delete. "Keep audio" is a setting, off by default.
- The local transcript is the failure fallback. A meeting recorded at a client
  site with no network must never be lost: upload is a durable queue with retry,
  not a fire-and-forget POST.

### The hq write path

New route `src/app/api/meetings/route.ts`, modeled directly on
`src/app/api/todo/route.ts`: header token auth compared with `timingSafeEqual`,
and **all value mapping inside the route** so the client stays dumb. That is the
convention the `todo` CLI already proves.

- A **separate secret** from `TODO_API_SECRET`. A Mac app on a laptop that leaves
  the building is a different threat surface from a CLI on the dev box, and
  separate secrets mean independent revocation.
- The secret lives in the **macOS Keychain**, not UserDefaults. Bark currently
  puts all settings in UserDefaults; this one does not go there.
- **The endpoint is a setting, empty by default.** Bark is a public repo with
  real users and a README that promises nothing leaves the Mac. A shipped build
  that posts to hq.lab37.io would break that for strangers. Unset endpoint means
  local markdown export; set endpoint means hq. Decision 1 already says v1 is
  for Erik, so this costs nothing and keeps the public product honest.

### hq schema

Additive only, and deliberately shaped for the multi-session rule: additive
migrations on disjoint tables are order-independent, so this cannot collide
destructively with another session's work.

- `meetings`: `id` uuid pk, `teamId` FK cascade notNull, `companyId` FK set null,
  `title`, `startedAt`, `endedAt`, `language`, `source`, `calendarEventId`,
  `summary` text, `transcript` jsonb (the speaker-attributed segments),
  `audioDeleted` boolean, `createdAt` / `updatedAt`. Indexes on `team_id`,
  `company_id`, `started_at`.
- `meeting_speakers`: `id`, `meetingId` FK cascade, `label`, `contactId` FK set
  null, `displayName`. This is what makes renaming a speaker stick.
- `meeting_tasks`: join table, `meetingId` + `taskId`. A join table rather than a
  nullable `meetingId` column on `tasks`, because `tasks` is the hottest table in
  the file and an EOF append is the low-collision hunk.

Action items are created as ordinary `tasks` rows through the existing
`createTaskCore`, then linked. Meetings do not invent a parallel task system.

Migration mechanics: claim the number by listing `deploy/migrations/` and
announcing it, and do not assume the highest number on disk is the highest
applied. Write the `-down.sql` too; the directory convention has them. Message
the other hq2 session before committing the `schema.ts` append.

## What Erik sees

1. A call starts. Bark notices and the pill or notch island offers **Record**.
   One click. It never arms itself.
2. While recording: a persistent meeting state in the overlay, visually distinct
   from dictation, with elapsed time, plus the live transcript if he wants it.
   The existing red REC dot already means recording; a meeting must not look like
   a stuck dictation.
3. He stops. The final pass and diarization run, with honest progress.
4. The meeting appears in hq against the right client, speaker-attributed.
5. Claude Code reads it, summarizes, and files action items as linked hq tasks.

Hotkey and menu-bar start still exist as the manual path. Detection is an offer,
not the only door.

## Risk and reversibility

- **The WhisperKit migration is the real risk.** It touches every dictation path
  in a product that has shipped, signed and notarized, to real users. It is not
  notetaker code and it should not ride along with notetaker code. Land it as its
  own release, through the full gates, before any of this.
- **The hq migration is low risk and reversible.** Additive, disjoint tables, and
  a down file. It touches the production database, so it runs once and gets read
  back before anything depends on it.
- **Audio deletion has no rollback.** Deleting after a successful upload is
  correct, but a bug in "successful" loses a client meeting permanently. Keep
  audio until hq has acknowledged the row and the transcript reads back non-empty.
- **Permission denial is invisible.** No public API tells Bark whether audio
  capture was granted, so a denied prompt looks like a silent meeting. Detect it
  from the data and say so loudly, in the moment, not afterwards.
- **Speaker bleed on laptop speakers** produces confidently wrong attribution,
  which is worse than no attribution. Ship the honest limitation.
- **The public build must not phone home.** Endpoint unset by default. If this is
  ever wrong, Bark's README becomes a false claim in a public repo.

## Build order

Each phase is independently shippable, and the product is useful from P2 on.

- **P0** Migrate to argmax-oss-swift, land dual-model language routing, convert
  kb-whisper-large from KBLab's checkpoint. Ships as a Bark release on its own.
  Dictation gets better; no notetaker yet.
- **P1** `MeetingRecorder`: process tap plus aggregate device, two streams, local
  recording, raw transcript to a local file. No hq, no diarization.
- **P2** Final pass plus SpeakerKit on the THEM stream. You/Them labeling, local
  markdown output. Genuinely useful at this point.
- **P3** hq Meetings surface: schema, route, upload with the offline queue, and
  the hq UI to read a meeting.
- **P4** Detection plus one-click arm plus the overlay meeting state.
- **P5** Calendar enrichment (names, client mapping, speaker-count seed) and
  action items linked into hq tasks.

## Gates

- **bark-mac**: builds, installs, and one real meeting recorded end to end on
  headphones with both speakers correctly attributed. Not a harness, a meeting.
- **hq2**: gates green means four things, not two: `tsc`, `eslint`, `vitest` in
  both timezones, and the full Playwright suite. This adds a route, so e2e is
  mandatory regardless of port contention.
- CodeRabbit at the commit boundary, per the code-review skill.
- Releases batch. Do not cut a Bark release per phase.

## Verify at implementation time

These are facts to check, not decisions to make. Nothing here is an open fork.

1. ~~The `argmax-oss-swift` tag at build time.~~ **RESOLVED 2026-09-19:** latest
   is **v1.1.0**; v0.18.0 was the last 0.x and v1.0.0 was the rename. The README's
   `from: "0.9.0"` is a stale example. Bark is on 1.1.0, which also brings a
   70%+ peak-memory reduction on multi-hour audio, directly useful for meetings.
   Migration was clean: zero source changes needed for the APIs Bark uses.
2. Each WhisperKit 0.18 landmine, against the new package. **PARTLY RESOLVED
   2026-09-19:** `windowClipTime` still defaults to 1.0 and the decode loop is
   still `while seek < seekClipEnd - windowPadding` in `TranscribeTask.swift`, so
   sub-1s audio still decodes empty without Bark's `= 0` override. The typo'd
   `detectLangauge(audioArray:)` is still the array API (the correctly spelled
   `detectLanguage` is the `audioPath` overload, not a fix). Still unverified:
   whether `DecodingOptions.detectLanguage` is still broken, and whether the ANE
   wedge still reproduces (unreproducible on the M5 Pro, which is healthy).
3. The right "is a process using the microphone" signal for detection. Candidate
   is the CoreAudio process object list plus its running-input property; confirm
   the exact property against the macOS 14.4+ headers before building on it.
4. Whether `visibleCalendars` and `fetchEvents` expose attendee emails, or only
   the privacy-gated tile shape the ops route returns.
5. The highest **applied** migration number in the live database, not the highest
   on disk.
