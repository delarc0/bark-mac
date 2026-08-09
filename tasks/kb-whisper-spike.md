# KB-Whisper quality + streaming spike

Goal: prove the quality-first plan before any app migration.
Priority order: (1) quality, no compromise; (2) streaming to kill perceived lag.

## Phase A — quality (answers single-vs-dual model) — DONE 2026-07-21
Measured on FLEURS test, 60 clips/lang, whisper.cpp Metal, language pinned,
jiwer WER with Whisper-style normalization (M5 Pro):

| model          | sv WER | en WER |
|----------------|--------|--------|
| kb-whisper-large | **4.56%** | 40.85% (unusable) |
| kb-whisper-small | 6.71%  | 59.30% (unusable) |
| whisper-large-v3 | 8.43%  | **4.08%** |

- Swedish: KB-large cuts errors ~46% vs large-v3 (matches KBLab's published
  claim). Even KB-SMALL beats large-v3 on Swedish.
- English failure mode: KB-Whisper randomly TRANSLATES English audio into
  Swedish (verified on individual clips), even with `-l en` pinned. The
  Swedish fine-tune overrides the task. Not gradual degradation — task drift.
- **DECISION: dual model, routed by language. sv -> kb-whisper-large,
  everything else -> whisper-large-v3 (full, not turbo).**

## Phase B — streaming + integration — DONE 2026-07-21
- Community CoreML conversions already exist in WhisperKit layout
  (mickekringai/kb-whisper-coreml: base/small/medium/large). KB-large loads and
  runs in WhisperKit 0.18 via `WhisperKitConfig(model: "openai_whisper-large-v3",
  modelFolder: <kb-large>, download: false)` — tokenizer resolves from the
  large-v3 name (KB kept Whisper's tokenizer). Harness: scratchpad/stt-spike/wk-harness.
- Latency on M5 Pro (ANE decoder path), Swedish clip, language pinned:

  | buffer | KB-large decode | turbo decode |
  |--------|-----------------|--------------|
  | 1s     | 0.51s           | 0.63s        |
  | 3s     | 0.79s           | 0.67s        |
  | 5s     | 1.28s           | 1.16s        |
  | 8s     | 1.49s           | 1.19s        |
  | 18.9s full | 2.93s       | 2.53s        |

  KB-large (32-layer decoder) is only ~15% slower than turbo (4-layer) —
  encoder dominates. The quality upgrade is nearly latency-free.
- Warm load 1.24s, warmup 0.54s. FIRST load = 239s one-time CoreML/ANE compile
  (design for it: progress UI + precompile right after download).
- Streaming loop latency (AudioStreamTranscriber re-decodes the buffer each
  pass) = the prefix numbers above: ~0.5-1.5s perceived lag. Not Parakeet's
  80ms, but words-appear-while-speaking at ~1s. Quality-first trade accepted.
- Bonus proof: on the test clip turbo produced visible Swedish errors
  ("Buxar avgård", "bostadshuset", "Jackarbomtang") that KB-large got right.

## Decision gate — PASSED
Dual model routed by language: sv -> kb-whisper-large, else -> whisper-large-v3
(full). Stay on WhisperKit; add AudioStreamTranscriber streaming; keep the
ANE-wedge self-heal. For SHIPPING, convert KB-large ourselves with
whisperkittools from KBLab's official checkpoint (don't ship third-party
community weights; verify our conversion matches the GGML reference output).

## Notes
- Competitive moat: KB-Whisper Swedish ~5% WER vs Fluid/Parakeet ~15%, ~3x.
- Drop large-v3-turbo (quality compromise) for full large-v3 on English.
