# Bark to hq API, contract v1

Bark (the Mac app) pushes finished meetings to hq and applies deletions made
in hq. This file is the whole contract for the hq side. Bark's client is
`BarkKit/Sources/BarkHQ`; the JSON examples below are its test fixtures
(`BarkKit/Tests/BarkHQTests/Fixtures`), and a test fails if this file and the
fixtures drift apart. A future Windows client follows the same contract.

## Basics

- `{base}` is the hq base URL the user set in Bark, for example
  `https://hq.lab37.io`: lowercase scheme and host, no trailing slash, no
  query. It is `https` always (`http://localhost` only for a dev server).
  Bark sends nothing anywhere until a base URL is set; it is empty by default.
- Every API request carries `Authorization: Bearer <device token>`,
  `Accept: application/json` and `Bark-API-Version: 1`. A breaking change
  gets a new version number; hq keeps serving v1 while v1 clients exist.
- Bark does not follow redirects on API requests (the token must only ever
  reach `{base}`); a 3xx is treated as a temporary failure.
- Meeting ids are UUIDs. Bark sends them lowercase; hq should compare them
  case-insensitively.
- Times are ISO 8601 in UTC. Bark sends whole seconds
  (`2026-10-15T09:00:00Z`). Segment and gap times are seconds from the
  meeting's `started_at`, millisecond precision.
- Error bodies are `{"error": "<message for the user>"}`. Bark shows the
  first 500 characters, control characters removed.

## 1. Pairing (zero typing)

1. The user clicks "Connect to hq" in Bark. Bark makes a fresh nonce (32
   random bytes, 64 lowercase hex characters) and opens in the browser:

   ```
   {base}/bark/connect?device=<device name>&nonce=<nonce>
   ```

   `device` is the Mac's name, percent-encoded (for example
   `device=Erik%E2%80%99s%20MacBook%20Pro`), for display only.
2. hq signs the user in if needed and asks them to approve the device,
   showing the device name.
3. On approval hq creates a device token for this user and this device and
   redirects the browser to:

   ```
   bark://hq-connected?token=<device token>&nonce=<same nonce>&base=<base URL>
   ```

   Every value percent-encoded. `nonce` is echoed exactly as received.
   `base` is hq's own base URL exactly as defined above (Bark refuses the
   callback when it differs from the base it opened).
4. On deny, hq shows a message and does not redirect.

Bark accepts a callback only for a pairing it started in the last 10
minutes, only with that pairing's nonce, and only once.

Device token:
- Opaque to Bark. 1 to 1024 characters, visible ASCII only (no spaces);
  at least 128 bits of randomness. Bark refuses any other token.
- One token per device. hq stores only a hash of it.
- Revocable in hq (a list of the user's devices with a revoke action).
  Every request with a revoked or unknown token gets `401`.
- Bark keeps it in the macOS Keychain and never logs it.

## 2. Push a meeting

```
PUT {base}/api/bark/meetings/{meeting id}
Content-Type: application/json
```

Idempotent: pushing the same id again replaces the whole meeting
(transcript, speakers, notes, gaps, title). Bark may push a meeting again
after it changed on the Mac, for example a rename, edited notes, or its
speakers found (a pass after the meeting is done, so the first push usually
has none) or named. The `{meeting id}`
in the path equals `meeting.id` in the body; hq answers `422` if not.

Body:

| Field | Type | Meaning |
|-------|------|---------|
| `meeting.id` | string, UUID | The meeting's id, made on the Mac. |
| `meeting.started_at` | string, ISO 8601 UTC | When recording started. |
| `meeting.ended_at` | string or null | When recording stopped. |
| `meeting.title` | string or null | The user's title. |
| `meeting.language` | string | The language the meeting was transcribed in (ISO 639-1, e.g. `sv`, `en`). |
| `meeting.mode` | `call`, `in_person` or `hybrid` | `call`: mic plus the call app's audio; `in_person`: one mic hearing the room; `hybrid`: both. |
| `segments[]` | array | The transcript in time order, streams interleaved. Stretches with no words are left out. |
| `segments[].stream` | `me`, `them` or `room` | `me`: the user's mic; `them`: the call's audio; `room`: a mic hearing everyone. Never mixed. |
| `segments[].start_s`, `end_s` | number | Seconds from `started_at`. Segments of different streams may overlap. |
| `segments[].text` | string | What was said. |
| `segments[].speaker` | string or null | A `speakers[].label` of this meeting, or null when not known. |
| `speakers[]` | array | The meeting's speakers. |
| `speakers[].label` | string | Unique within the meeting, e.g. `SPEAKER_1`. Bark sends `Me` for the user on a call's `me` stream and `Speaker 1`, `Speaker 2`, ... in order of first appearance for everyone else. |
| `speakers[].name` | string or null | The name the user gave, or null. |
| `notes` | string or null | The user's own notes, plain text. hq keeps them apart from anything its agent writes and never writes agent output into them. A re-push replaces them. |
| `gaps[]` | array | Where audio is missing or untranscribed. |
| `gaps[].at_s` | number | Seconds from `started_at`. |
| `gaps[].reason` | string | For example `sleep`, `decode failed`. |
| `calendar_event` | object or null | The Google Calendar event Bark matched the meeting to, or null (no calendar connected, or no event around the time). Added 2026-10-18, additive to v1. |
| `calendar_event.id` | string | Google's event id. |
| `calendar_event.title` | string or null | The event's title. Bark also uses it as `meeting.title` unless the user typed one. |
| `calendar_event.start`, `end` | string, ISO 8601 UTC | The event's scheduled times (the meeting's own times are in `meeting`). |
| `calendar_event.attendees[]` | array | The invitees, rooms left out. `name` is the display name or, failing that, the email; `self` marks the Bark user; `organizer` the event's organizer; `response` is Google's `accepted`, `declined`, `tentative`, `needsAction` or null. |
| `app_version` | string | Bark's version and build, e.g. `1.0.0 (42)`. |

Example:

```json
{
  "meeting": {
    "id": "3f2b6c1e-8a4d-4f7e-9b1a-2c5d6e7f8a90",
    "started_at": "2026-10-15T09:00:00Z",
    "ended_at": "2026-10-15T09:42:10Z",
    "title": "Weekly sync",
    "language": "sv",
    "mode": "call"
  },
  "segments": [
    { "stream": "me", "start_s": 0.84, "end_s": 4.2, "text": "Hej, hör ni mig?", "speaker": null },
    { "stream": "them", "start_s": 3.9, "end_s": 8.25, "text": "Ja, vi hör dig bra.", "speaker": "SPEAKER_1" },
    { "stream": "them", "start_s": 9.1, "end_s": 12.6, "text": "Ska vi börja med budgeten?", "speaker": "SPEAKER_1" }
  ],
  "speakers": [
    { "label": "SPEAKER_1", "name": "Anna" },
    { "label": "SPEAKER_2", "name": null }
  ],
  "notes": "Budget: fråga om Q4.\nSkicka offert på fredag.",
  "gaps": [
    { "at_s": 1520.5, "reason": "sleep" }
  ],
  "calendar_event": {
    "id": "7q3k9v2m1p8d4s6f0a5h2j7n1b",
    "title": "Weekly sync",
    "start": "2026-10-15T09:00:00Z",
    "end": "2026-10-15T09:45:00Z",
    "attendees": [
      { "name": "Erik", "email": "erik@example.test", "self": true, "organizer": true, "response": "accepted" },
      { "name": "Anna Svensson", "email": "anna@example.test", "self": false, "organizer": false, "response": "accepted" }
    ]
  },
  "app_version": "1.0.0 (42)"
}
```

Responses:

| Status | Meaning | Bark does |
|--------|---------|-----------|
| `200` or `201` | Stored (`201` for a new meeting, `200` for a replace). The body is ignored. | Marks the meeting acknowledged. |
| `401` | Token revoked or unknown. | Stops all uploads, asks the user to reconnect. |
| `413` | Too large, permanently. | Marks the meeting failed with the `error` message; no automatic retry. |
| `422` | Invalid, permanently (`error` says why). | Same as `413`. |
| `5xx`, any other status, no answer | Temporary. | Retries that meeting after 1 min, 5 min, 30 min, 2 h, then every 6 h. |

The meeting stays on the Mac whatever the answer; Bark only marks it
acknowledged. hq should accept bodies of at least 10 MB (a 90-minute
meeting is well under 1 MB).

## 3. Deletions

Deleting a meeting in hq deletes it on the Mac.

```
GET {base}/api/bark/deletions?since=<server_time from the previous answer>
```

`since` is omitted on the first sync after pairing; hq then returns the
deletions it still remembers (at least the last 30 days). Bark sends back
the previous `server_time` verbatim, so its format is hq's choice within
ISO 8601.

Answer `200`:

```json
{
  "deleted": [
    "3f2b6c1e-8a4d-4f7e-9b1a-2c5d6e7f8a90"
  ],
  "server_time": "2026-10-15T12:00:00Z"
}
```

- `deleted`: ids of this user's meetings deleted in hq after `since`. At most
  10,000 ids; when there are more, hq returns the oldest 10,000 and sets
  `server_time` to the deletion time of the last one returned, so the next
  call continues from there.
- `server_time`: hq's clock when it answered (or as above), ISO 8601.
- Bark deletes each listed meeting it has that is finished, ignores ids it
  does not have, and never deletes a meeting still recording. It refuses
  the whole answer (and keeps its old `since`) when any id is not a UUID,
  `server_time` is not ISO 8601, or the body is over 2 MB.
- `401` as above. Any other status: Bark tries again on its next sync.
