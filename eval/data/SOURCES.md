# Sources for the local ASR evaluation set

Built 2026-11-20. 76 clips (72 speech + 4 synthetic non-speech), 13.7 min, about 26 MB,
all 16 kHz mono 16-bit PCM WAV. Clip-level detail is in `manifest.jsonl`.

Everything was fetched anonymously: the public Hugging Face datasets-server (`/rows`) and
public repo files. No token, no login, no gated terms accepted. Gated repos were skipped.

This set is for local benchmarking only. Several sources are non-commercial and one is
no-derivatives, so do not redistribute the clips.

## Datasets used

| Dataset (HF repo) | Config / split | Clips | Category | Licence or terms as stated on the card | Content and reference quality |
|---|---|---|---|---|---|
| `UBC-NLP/Casablanca` | Jordan, Palestine, Egypt, UAE / test | 5 + 5 + 4 + 3 | levantine, egyptian, gulf | `cc-by-nc-nd-4.0`. Card: only validation and test sets are released. | Dialogue from TV series, judging by the content: acted, not spontaneous. Human transcripts. |
| `facebook/omnilingual-asr-corpus` | apc_Arab / test (4), dev (1); arz_Arab / test (4) | 9 | levantine, egyptian | `cc-by-4.0` ("This corpus is released under CC-BY-4.0"). | Spontaneous prompted monologues. Human transcripts with `<hesitation>`/`<noise>` tags and word fragments; the Levantine ones use phonetic spelling and partial diacritics. |
| `MohamedRashad/simple-escwa` | default / train (only split) | 9 | codeswitch | No licence on the card. Unofficial mirror of ESCWA.CS; the official `QCRI/escwa` is gated and tagged `cc-by-nc-4.0`. | UN ESCWA meeting speech, 2019. Human transcripts. Speaker dialect is not labelled; I judged it from the text (8 Levantine, 1 Egyptian). |
| `sqrk/mixat-tri` | default / test | 3 + 2 | codeswitch, gulf | `cc-by-nc-sa-4.0`. | Emirati podcast speech. Human transcripts; English spans are wrapped in `[brackets]`. |
| `HuggingPanda/SDAIANCAI-Saudilang-Code-Switch-Corpus` | default / test | 2 | codeswitch | Card is empty. Upstream `SDAIANCAI/Saudilang-Code-Switch-Corpus` says `cc-by-sa-4.0` in metadata and "CC BY-NC-SA 4.0" in its text. | Saudi podcast (Thmanyah). SDAIA human transcripts in pre-processed form: normalised Arabic, no punctuation, lower-cased English. Unofficial re-upload that adds the audio. |
| `MohamedRashad/arabic-english-code-switching` | default / train (only split) | 1 | codeswitch | `gpl`. | Aggregate of ArzEn-derived interview transcripts and scraped YouTube subtitles, with no per-row provenance. Lower-confidence reference. |
| `MohamedRashad/SADA22` | default / test | 3 | gulf | `cc-by-nc-sa-4.0`. | Saudi TV shows (Najdi, Hijazi, Khaliji). Human transcripts. Community mirror of SDAIA's Kaggle release. |
| `google/fleurs` | ar_eg / test; en_us / test | 8 + 4 | msa, english | `cc-by-4.0`. | Read speech. Reference is the `raw_transcription` column. |
| `openslr/librispeech_asr` | clean / test | 4 | english | `cc-by-4.0`. | Read audiobooks. Upper-case references without punctuation. |
| `chikingsley/l2-arctic-manual-v5.0-16k` | default / test (2), validation (2), train (2) | 6 | english_arabic_accent | `cc-by-nc-4.0` ("remains under the original CC BY-NC 4.0 terms from L2-ARCTIC"). | English read by the four Arabic-L1 speakers (ABA, SKA, YBAA, ZHAA). Reference is the prompt text. Unofficial mirror of the TAMU release. |
| `edinburghcstr/edacc` | default / validation | 4 | english_arabic_accent | No licence tag. Card text: "Public Domain, Creative Commons Attribution-ShareAlike International Public License (CC-BY-SA)". | Spontaneous Zoom conversation between two L1-Arabic speakers (accent label "Egyptian"). Professional transcripts, upper-case, with UH/UM and `<LAUGH>`. |
| synthetic (ffmpeg lavfi) | n/a | 4 | silence | None; generated locally. | 3 s and 8 s digital silence, 5 s pink noise at -45 dBFS RMS, 4 s keyboard-like clicks. Empty reference. |

## Tried but not used

| Dataset | Outcome |
|---|---|
| `nadsoft/Jordan-Audio` | Not accessible: the Hub API returns 401 and datasets-server says it does not exist or needs authentication. |
| `QCRI/escwa`, `KoelLabs/L2Arctic`, `KoelLabs/L2ArcticSpontaneousSplit`, `echonova-ai/arabic-dialect-asr-benchmark`, `oi-uae/EmiratiAudioDataset-20H`, `Mennatu/ARZEN-ST` | Gated (automatic approval, but needs a login). Not accessed. |
| `STT-DATASET/en-accent-arl2eng-arabic-l1` (and its mixat, escwa, zaebuc, edacc siblings), `Arabic-STT/ASR_Code_Switch`, `MaryamAlAli/Mixat_Voice`, `dlion168/L2_arctic_all_transcribed`, `MagicLuke/l2-arctic` | Gated (manual approval). Not accessed. |
| `mozilla-foundation/common_voice_17_0` | Empty on HF. Its card says Common Voice is available only through Mozilla Data Collective since October 2025. Not pursued. |
| `pain/MASC` | Public (`cc-by-4.0`), but the viewer refuses it because it relies on a loader script. I did not run the script or look for raw archives. |
| `google/fleurs` through `/rows` | The viewer fails for these splits (502, "Scan size limit exceeded"). I streamed the start of the repo's `audio/test.tar.gz` instead. |
| `arbml/ESCWA` | Public, but `/rows` fails ("Scan size limit exceeded"). Used `MohamedRashad/simple-escwa`. |
| `MBZUAI/MIXAT` | Public, train split only, no licence. Used `sqrk/mixat-tri`, which has a test split and a licence. |
| `MBZUAI/ArzEn` | Repo exists but is empty. |
| `ahmedsamirtarjama/MBZUAI_ArzEn_wav`, `Moamen-dcp/arazn_codeSwitched_mp3_full_notLower` | Public ArzEn re-uploads with no licence. Not used: to my knowledge ArzEn is distributed by its authors under a research agreement (not re-checked here). |
| `MightyStudent/Egyptian-ASR-MGB-3` | Public, no licence. Fixed 30 s windows re-synced from YouTube, longer than the target range. |
| `SDAIANCAI/Saudilang-Code-Switch-Corpus` | Official repo holds only a CSV of transcripts and YouTube timestamps, no audio. Used the re-upload above. |
| `RoberButros/syrian-arabic-tech-speech-with-code-switching` (and the `GraduationTeam` copy) | Syrian tech podcasts with English terms, the closest topical match. No card or licence, fixed 30 s windows (5 of 1173 rows are 25 s or shorter), transcripts of unknown origin with normalised spelling. Skipped. |
| `oddadmix/arabic-audio-collection-syrian-podcast`, `Overtech/syrian-arabic-speech-dataset` | Real Syrian podcast speech, but the first card says transcripts are "AI-assisted", so the references are machine-made. The second appears to hold the same clips and text without diacritics, under a custom licence. Skipped. |
| `xtz999/jordanian_arabic_speech_amir`, `xtz999/lebanese_arabic_speech_aisha` | Fully diacritised scripted sentences; they look like synthetic TTS. Skipped, along with the same-named siblings, which I did not open. |
| `SpeechDataAI/levantine-arabic-conversational-speech` | Vendor listing: card only, no data files. Its Gulf and Egyptian siblings were not opened. |
| `otozz/levantine_test_set` | Only precomputed model features, no audio. |
| `saramadi/Jordan_dialect`, `crtvai/jordan-dataset-v9` | The first is text with YouTube ids only. The second is an 8-row test split of caption-style fragments with no licence. |
| `MINERVA-TEAM/minerva-ar-en-edu-codeswitch-dataset` | References look machine-generated. |
| `Nash-pAnDiTa/ASR_En_Ar_CodeSwitching`, `Seif-Eldeen-Sameh/asr_codeswitched_dataset`, `abdo1819/arabic-english-code-switching-synthetic-asr` | YouTube subtitle fragments of unverifiable alignment, or synthetic speech. |
| `ymoslem/MediaSpeech` (ar) | Public (`cc-by-4.0`), train split only; text is normalised and cut at clip boundaries. Not needed. |
| `changelinglab/speechaccentarchive-pr` | Speech Accent Archive mirror (`cc-by-nc-sa-2.0`). Arabic speakers are there (ids `arabic1`…), but each clip is the whole "Please call Stella" paragraph (32 to 45 s on the three I measured) and the transcript column is IPA, not English text. |
| `MushanW/GLOBE_V2` | Common Voice derivative (`cc0-1.0`) with accent labels. The one filter query that completed found no accent label containing "rab" in the test split; the index was unavailable for every other attempt, so val and train are unchecked. Not used. |

## Reading the references

References are verbatim from each dataset, so conventions differ. Normalise before scoring.

- **Tags and markup**: Omnilingual has `<hesitation>`, `<noise>`, `<unintelligible>` and
  hyphenated fragments. Mixat wraps English in `[brackets]`. EdAcc has `<LAUGH>`.
- **Case and punctuation**: LibriSpeech and EdAcc are upper-case without punctuation.
  Saudilang is unpunctuated with lower-case English and no apostrophes. ESCWA puts spaces
  before punctuation.
- **Arabic spelling**: the Omnilingual Levantine clips write qaf as hamza and add partial
  diacritics, so raw WER against conventional spelling will look worse than it is.
- **Not verified by ear**: no one listened to these clips while building the set. Checks
  were automatic: format, level, duration and characters per second of speech.

## Rebuilding

Helper scripts are in `eval/tools/`. Run them with `python3 -I`.

- `build_eval_set.py rows --selection selection.json` fetches the 60 hand-picked rows.
- `build_eval_set.py fleurs --config ar_eg --category msa --rows 0,1,2,3,30,31,32,33`
  and `fleurs --config en_us --category english --rows 5,8,15,22` stream the FLEURS
  clips. Re-running these two and `silence` into an empty directory reproduced the
  shipped files byte for byte.
- `build_eval_set.py silence` generates the synthetic clips; `verify` re-checks everything.

When the FLEURS clips were first chosen, recordings quieter than -35 dBFS RMS were
skipped. Most of the en_us test split is that quiet, and every loud-enough clip found
was a male voice. The ar_eg test and dev splits contain only female voices.
