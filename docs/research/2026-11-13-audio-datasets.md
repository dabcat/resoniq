---
type: "research"
tags:
  - "research"
  - "ai"
  - "datasets"
  - "licensing"
---
# Audio datasets on the Hugging Face Hub for the on-device models

**Asked:** which datasets on the Hugging Face Hub can test, and later perhaps train, the three AI pieces in
[PRODUCT_SPEC.md](../PRODUCT_SPEC.md) §3: the SoundAnalysis noise gate (§3.1), the speaker-defect classifier
(§3.4) and the anomaly model (§3.5). This is the "No training data" risk in [PLAN.md](../PLAN.md), phase 6.

**How it was checked (2026-11-13):** Hub search API (`/api/datasets?search=`), each dataset's API record
(`/api/datasets/{id}`: licence tag, gating, storage), the dataset viewer size endpoint, and each card's
`README.md`. Where a Hub entry mirrors a dataset published elsewhere, the original licence was read from the
Zenodo record. No audio was downloaded. Each fact below names its source: **card**, **API** (Hub API or viewer),
**Zenodo** (original record), or **inferred**.

## Summary

- **Noise gate:** well covered. Labelled environmental audio with commercially usable licences exists.
- **Anomaly model:** benchmark data exists (machine sounds, normal versus anomalous), but almost all of it is
  non-commercial, and none of it is loudspeakers. It can test the method, not the product.
- **Defect classifier:** nothing. No search on the Hub (loudspeaker, speaker defect, speaker fault, rub and
  buzz, buzz, rattle, crackle, clipping, declipping, distortion) returned a dataset of defective loudspeakers.
  The risk in the plan stands. Our own recordings plus synthetic defects are the only route.

### Recommended starting set

| # | Hub id | For | Licence | Commercial use |
|---|---|---|---|---|
| 1 | [`Fhrozen/FSD50k`](https://huggingface.co/datasets/Fhrozen/FSD50k) | Noise gate: test, later training | CC-BY-4.0 for the collection; each clip has its own licence | Only clips marked CC0 or CC-BY; filter by the per-clip licence file |
| 2 | [`philgzl/demand`](https://huggingface.co/datasets/philgzl/demand) | Noise gate: real room and street noise at 48 kHz; noise to mix into DSP tests | CC-BY-4.0 | Yes, with attribution |
| 3 | [`corypaik/musan`](https://huggingface.co/datasets/corypaik/musan) | Noise gate: speech and music as interference | CC-BY-4.0 overall, mixed per source | Mostly; check the per-source `licenses/` files |
| 4 | [`audioSP-UoY/narrowband-truncated-rirs`](https://huggingface.co/datasets/audioSP-UoY/narrowband-truncated-rirs) | Room simulation for DSP tests and for augmenting all three models | Per subset; most CC-BY-4.0 | Yes for the CC-BY-4.0, MIT and Apache subsets; not `c4dm` |
| 5 | [`LakoreAI/stgram-mfn-dcase2020-dev`](https://huggingface.co/datasets/LakoreAI/stgram-mfn-dcase2020-dev) | Anomaly model: benchmark the method only | CC-BY-NC-SA-4.0 | No. Evaluation of the approach only; nothing trained on it ships |

## 1. Noise gate (SoundAnalysis, §3.1)

The need: clips with a known label (speech, music, traffic, appliance, dog) to measure how often the built-in
classifier catches each kind of interference, and real background noise at known levels.

| Hub id | Contents | Size | Rate, format | Labels | Licence | Gated | Use here |
|---|---|---|---|---|---|---|---|
| [`Fhrozen/FSD50k`](https://huggingface.co/datasets/Fhrozen/FSD50k) | Copy of FSD50K from Zenodo: Freesound clips of sound events (card) | 51,197 clips, 108.3 h; dev 40,966 / eval 10,231 (card); 34.5 GB (API) | 44.1 kHz, 16-bit mono WAV (card) | 200 classes from the AudioSet ontology, multi-label (card) | Tag `cc-by-4.0` (API). Card: collection is CC-BY; each clip keeps its Freesound licence, "some forbidding further commercial reuse". Zenodo tags the record `other-at` | No (API) | Test and training, after filtering to CC0 and CC-BY clips |
| [`philgzl/fsd50k`](https://huggingface.co/datasets/philgzl/fsd50k) | Same data, re-encoded (card) | 51,197 clips; dev 80 h, eval 28 h (card); 3.0 GB (API) | 48 kHz mono Opus (card) | Same; clip licences in `dev_clips_info_FSD50K.json` and `eval_clips_info_FSD50K.json` (card) | Tag `cc-by-4.0`; card lists clip licences CC0, CC-BY, CC-BY-NC, CC Sampling+ | No | Lighter download for tests. Opus is lossy, so not for training a model that judges audio quality |
| [`philgzl/demand`](https://huggingface.co/datasets/philgzl/demand) | Mirror of DEMAND: multichannel recordings of real environments (card) | 48k split 24.0 h, 7,200 segments; 16k split 22.7 h, 6,800 segments; each channel a separate file (card); 0.9 GB (API) | 48 kHz and 16 kHz, mono Opus (card) | Environment name in the file name (inferred from the `name` column) | `cc-by-4.0` (card, API, and Zenodo record 1227121) | No | Test and training: "is the room too noisy" at controlled SNR |
| [`voice-biomarkers/DEMAND-acoustic-noise`](https://huggingface.co/datasets/voice-biomarkers/DEMAND-acoustic-noise) | DEMAND as WAV, copied from Kaggle (card) | 560 examples declared; 15.4 GB (API) | 48 kHz and 16 kHz WAV, 16 channels as separate files (card) | File name | `cc-by-4.0` (card, API) | No | Use instead of the Opus mirror when lossless audio matters |
| [`corypaik/musan`](https://huggingface.co/datasets/corypaik/musan) | MUSAN (OpenSLR 17): music, speech, noise (card) | About 109 h: music 42 h, speech 60 h, noise 6 h (card); 12.5 GB (API) | 16 kHz mono (card) | `music` / `speech` / `noise` plus source (API features) | Tag `cc-by-4.0`. Card: mixed by source; Freesound noise is US public domain, Sound Bible noise is assorted Creative Commons, music and speech carry their own terms; per-clip LICENSE files kept under `licenses/` | No | Test: speech and music as interference. 16 kHz only, so the top of the band is missing |
| [`agkphysics/AudioSet`](https://huggingface.co/datasets/agkphysics/AudioSet) | AudioSet: 10 s clips from YouTube, downloaded March 2023 (card) | Balanced train 18,683 clips, eval 17,141, unbalanced 1,738,788 (card); balanced config about 49.5 GB, full about 2.4 TB (API) | Mostly 48 kHz, about 10 % 44.1 kHz, FLAC (card) | AudioSet ontology, multi-label (card) | Tag and card say `cc-by-4.0` | No | Test only, balanced config. See the caution below: the CC-BY licence covers the labels; the audio is YouTube content |
| [`danavery/urbansound8K`](https://huggingface.co/datasets/danavery/urbansound8K) | UrbanSound8K, copied from Kaggle (card) | 8,732 clips of 4 s or less; 7.0 GB (card, API) | WAV; rate, depth and channels vary per file (card) | 10 classes: air conditioner, car horn, children playing, dog bark, drilling, engine idling, gun shot, jackhammer, siren, street music (card) | `cc-by-nc-4.0` (API; same on Zenodo record 1203745) | No | Test only. Non-commercial |
| [`ashraq/esc50`](https://huggingface.co/datasets/ashraq/esc50) | ESC-50 (card links the original repository) | 2,000 clips; 0.77 GB (API) | 44.1 kHz (declared in the features of [`confit/esc50-parquet`](https://huggingface.co/datasets/confit/esc50-parquet), the same data in five folds) | 50 classes, including dog, vacuum cleaner, washing machine, clock tick, engine | No licence tag. Card: "Creative Commons Attribution Non-Commercial" | No | Test only. Non-commercial. The classes match our interference list best |
| [`philgzl/wham`](https://huggingface.co/datasets/philgzl/wham) | WHAM! 48 kHz noise: cafes, restaurants, bars (card) | Train 59 h, validation 12 h, test 7 h; 28,273 segments (card); 4.3 GB (API) | 48 kHz stereo Opus (card) | None beyond split | `cc-by-nc-4.0` (card, API) | No | Test only. Non-commercial |
| [`wetdog/TUT-urban-acoustic-scenes-2018-development`](https://huggingface.co/datasets/wetdog/TUT-urban-acoustic-scenes-2018-development) | TUT Urban Acoustic Scenes 2018 development set (card) | 8,640 segments of 10 s, 24 h; 24.9 GB (card, API) | 48 kHz, binaural recording (card) | 10 scenes: airport, bus, metro, park, street traffic and others (card) | Tag `afl-3.0` is wrong. The card's licence text allows "experimental and non-commercial" use and says commercial use "is strictly prohibited"; Zenodo record 1228142 is `other-nc` | No | Test only. Non-commercial. Outdoor and transport scenes, of little use for living rooms |
| [`quinnlue/tau-urban-acoustic-scenes-2022-mobile-split5`](https://huggingface.co/datasets/quinnlue/tau-urban-acoustic-scenes-2022-mobile-split5) | Subset of TAU Urban Acoustic Scenes 2022 Mobile, 1 s segments (card) | About 10,000 WAV files, 1.3 GB (API) | WAV; rate not stated in the card | 10 scenes | Card: "Non-commercial research use only"; Zenodo record 6337421 is `other-nc` | No | Not recommended: 1 s segments, non-commercial |
| [`benjamin-paine/freesound-laion-640k-commercial-16khz-full`](https://huggingface.co/datasets/benjamin-paine/freesound-laion-640k-commercial-16khz-full) | Freesound clips limited to licences that allow commercial work (card) | 403,146 clips, 37.5 GB; smaller variants from 1.84 GB (card) | 16 kHz (card) | No class labels; per-clip `license`, `attribution_required`, `commercial_use` columns (API features) | Tag `cc-by-4.0`; per-clip licence | No | Later, as unlabelled background audio for augmentation. The card itself says labels are missing |

## 2. Speaker-defect classifier (§3.4)

**No dataset of defective loudspeakers was found on the Hub.** Nothing real exists there for rattle, voice-coil
rub, buzz, crackle or a torn driver. The table lists the closest proxies; none is a substitute.

| Hub id | Contents | Size | Rate, format | Labels | Licence | Gated | Use here |
|---|---|---|---|---|---|---|---|
| [`overfitprolabse/subjective_audio_quality`](https://huggingface.co/datasets/overfitprolabse/subjective_audio_quality) | Pairs of 1 s clips: original and a version degraded by audio codecs, with a quality score from 0 to 1 produced by "visqol-like algorithms" (card) | 612,020 pairs (card); 224 GB (API) | 44.1 kHz mono WAV in WebDataset shards (card) | Score only; no defect class | `mit` (API). The card does not say where the source audio comes from | No | Weak proxy. Codec artefacts are not driver defects. Could pretrain a "degraded versus clean" feature extractor; not recommended before we have our own data |
| [`hamezksm/machine_noise_dataset`](https://huggingface.co/datasets/hamezksm/machine_noise_dataset) | Clips of running machinery; some are synthetic augmentations (card) | 99 clips, 13 MB (card, API) | Mostly 16 kHz, 16-bit mono WAV (card) | `normal`, `bearing_fault`, `belt_slip`, 33 each (card) | `unknown` (API) | No | Not usable: tiny, unknown licence, wrong domain. Listed because it is the only labelled "fault sound" classifier set the search found |

### How to get data instead (proposal, not a measurement)

1. **Record our own.** A handful of cheap drivers, recorded healthy with the app's sweep and tones, then
   damaged on purpose (loose screw or foreign object for rattle, shifted coil for rub, torn surround, overdriven
   amplifier for clipping) and recorded again, on several iPhones and in several rooms. This is what §3.4 asks
   for, and it is the only source of real labels. The DCASE machine datasets were made the same way: the
   DCASE 2023 Task 2 card says anomalies "were collected by deliberately damaging target machines".
2. **Simulate defects on healthy recordings.** Take the clean test signal, apply a defect model, then pass it
   through a room and add noise (inferred recipe; the defect models need checking against real recordings from
   step 1 before any training relies on them):
   - clipping and amplifier distortion: hard and soft clipping, polynomial waveshaping;
   - rub and buzz: short bursts of high-order harmonics locked to the peaks of cone excursion at low
     frequency;
   - rattle: impact noise bursts triggered when the low-frequency displacement crosses a threshold;
   - air leak: band-limited noise amplitude-modulated by the low-frequency signal;
   - then convolve with a measured room response (section 4) and mix in DEMAND noise at a chosen SNR.
3. **Keep the classifier behind DSP.** Until step 1 exists the defect classes come from DSP rules, as
   [ARCHITECTURE.md](../ARCHITECTURE.md) already decides. Synthetic data can test those rules on the Mac today.

## 3. Anomaly model (§3.5)

Machine-condition-monitoring sets give the right problem shape (train on normal sound only, test on normal plus
anomalous) and let us compare an autoencoder against published baselines. They contain fans, pumps, valves and
toy cars, not loudspeakers, so a result on them says nothing about detection rates in the app.

| Hub id | Contents | Size | Rate, format | Labels | Licence | Gated | Use here |
|---|---|---|---|---|---|---|---|
| [`LakoreAI/stgram-mfn-dcase2020-dev`](https://huggingface.co/datasets/LakoreAI/stgram-mfn-dcase2020-dev) | Redistribution of the DCASE 2020 Task 2 development set (MIMII and ToyADMOS machines): fan, pump, slider, valve, ToyCar, ToyConveyor (card) | 30,987 WAV files, 10.1 GB (API) | 16 kHz mono, 10 s, 16-bit WAV (card) | `train/` normal only; `test/` normal and anomaly; machine type and id in the path (card) | `cc-by-nc-sa-4.0` (card, API, Zenodo record 3678171) | No | Benchmark the method. Non-commercial and share-alike |
| [`renumics/dcase23-task2-enriched`](https://huggingface.co/datasets/renumics/dcase23-task2-enriched) | DCASE 2023 Task 2 development set, seven machine types, plus precomputed embeddings (card) | 94 GB including embeddings (API) | 16 kHz (card) | `label` normal / anomaly, `domain` source / target (card) | Tag `cc-by-4.0`; the card and the Zenodo description both say the original is CC BY-NC-SA 4.0 (the Zenodo licence field says `cc-by-4.0`). Treat as non-commercial | No | Benchmark only |
| [`ltuncay/chime-mimii-dg`](https://huggingface.co/datasets/ltuncay/chime-mimii-dg) | Repackaged MIMII DG, five machine types, three domain sections; the card calls it a "prepared candidate", not an admitted release | 17,999 audio files, 5.8 GB (card, API) | Native audio kept, no resampling (card); rate not stated | Source anomaly labels kept (card) | Tag `other`. Card: the source description says CC-BY-NC-SA-4.0 and the Zenodo field says CC-BY-4.0; the Zenodo description of record 6529888 confirms CC BY-NC-SA 4.0 | No | Benchmark only |
| [`HTill/dcase2025_task2_dev`](https://huggingface.co/datasets/HTill/dcase2025_task2_dev) | DCASE 2025 Task 2 development set: bearing, fan, gearbox, slider, ToyCar, ToyTrain, valve (API features) | 6,700 rows, 2.1 GB (API) | Not stated in the card | `normal` / `anomaly` / `unknown`, `source` / `target` domain (API features) | Tag `mit` is wrong: Zenodo record 15097779 is `cc-by-nc-sa-4.0` | No | Benchmark only |

The original **MIMII** dataset is the one machine set with a licence that allows commercial use: CC BY-SA 4.0
(Zenodo record 3384388, licence field and description; 16 kHz, 16-bit, eight-channel array). No verified copy
of it with that licence was found on the Hub (see "Not verified"). If a commercially clean benchmark is wanted,
take it from Zenodo. Share-alike applies to copies and adaptations of the data.

For the product itself the "normal" class has to be our own recordings of healthy speakers playing the app's
test signals. That data needs no defective units, so it can be collected before anything else in phase 6.

## 4. Supporting material: rooms, music, speech

| Hub id | Contents | Size | Rate, format | Labels | Licence | Gated | Use here |
|---|---|---|---|---|---|---|---|
| [`audioSP-UoY/narrowband-truncated-rirs`](https://huggingface.co/datasets/audioSP-UoY/narrowband-truncated-rirs) | Measured room impulse responses from 13 open collections, truncated per band to remove the noise tail (card). The card says the page is still under construction | 29,971 files, 13.9 GB (API) | 48 kHz float32 WAV (card) | Subset name | Tag `other`; per subset (card): `th_koeln`, `arni`, `motus`, `openair`, `mrtd`, `sauna`, `reverb_challenge`, `dechorate` CC BY 4.0; `but` Apache 2.0; `iks` MIT; `c4dm` CC BY-NC-SA 4.0; `echothief` custom; `mit` unspecified | No | Simulate rooms in Kit DSP tests on the Mac and augment training data. Use only the CC BY, MIT and Apache subsets |
| [`benjamin-paine/mit-impulse-response-survey`](https://huggingface.co/datasets/benjamin-paine/mit-impulse-response-survey) | MIT IR Survey: impulse responses of everyday places, 1.5 m between source and microphone (card) | 270 files, 16 MB (API) | Rate not stated in the card (a separate 16 kHz copy exists) | Location class, e.g. Bedroom, DiningRoom (API features) | Tag and card `cc-by-4.0`. Two other Hub copies disagree: [`davidscripka/MIT_environmental_impulse_responses`](https://huggingface.co/datasets/davidscripka/MIT_environmental_impulse_responses) says "unknown", and the collection above says "Unspecified" | No | Small and handy for unit tests. Confirm the licence at the source before shipping anything derived from it |
| [`treble-technologies/Treble10-RIR`](https://huggingface.co/datasets/treble-technologies/Treble10-RIR) | Simulated responses of 10 furnished rooms (bathrooms, bedrooms, living rooms, meeting rooms), 14 to 46 m³, reverberation time 0.17 to 0.84 s, with source and receiver positions and room metrics (card, API features) | 3,085 responses per format (mono, 6-channel, 8th-order ambisonic); 61 GB in total, mono split 0.7 GB (API) | 32 kHz (card) | Room, positions, EDT, T30, C50 per band | `cc-by-nc-sa-4.0` (API) | No | Test only. Useful because geometry and positions are known, which matches placement tests. Non-commercial |
| [`EaseZh/rirs_noises`](https://huggingface.co/datasets/EaseZh/rirs_noises) | OpenSLR 28: simulated and real room responses, isotropic and point-source noise (card) | One 1.3 GB zip (API) | 16 kHz, 16-bit (card) | Folder structure | `apache-2.0` (card, API) | No | Fallback. 16 kHz is too low for full-band speaker work |
| [`openslr/librispeech_asr`](https://huggingface.co/datasets/openslr/librispeech_asr) | LibriSpeech read English speech (card) | About 1,000 h (card); 124 GB (API) | 16 kHz (card) | Transcript, speaker id | `cc-by-4.0` (card, API) | No | Speech interference for the noise gate, test and training. Only the `test.clean` split is needed |
| [`philgzl/fma-medium`](https://huggingface.co/datasets/philgzl/fma-medium) | Free Music Archive, medium set (card) | 24,908 tracks, 208 h (card); 11.3 GB (API) | 24 and 48 kHz, mono and stereo, Opus (card) | Genre and track licence in `tracks.csv` (card) | Tag `other`: each track under the licence its artist chose; metadata CC BY 4.0 (card) | No | Music interference for the gate, test only, unless tracks are filtered by licence |

## Licence cautions

- **A Hub licence tag is not the licence.** Three tags found here are wrong against the original source:
  `HTill/dcase2025_task2_dev` (`mit`, original CC BY-NC-SA 4.0), `wetdog/TUT-urban-acoustic-scenes-2018-development`
  (`afl-3.0`, original non-commercial), `renumics/dcase23-task2-enriched` (`cc-by-4.0`, original CC BY-NC-SA 4.0
  by its own card). The search also lists `MahiA/UrbanSound8K` as `mit` although UrbanSound8K is CC BY-NC 4.0.
  Read the card and the original record every time.
- **Mirrors are unofficial.** Apart from `openslr/librispeech_asr` and `treble-technologies/Treble10-RIR`, every
  entry above is a third-party copy (inferred from the account names and the cards). The original licence governs.
- **Non-commercial sets** (ESC-50, UrbanSound8K, WHAM!, TUT/TAU, all DCASE Task 2 sets, MIMII DG, MIMII DUE,
  Treble10): do not train a shipped model on them. Whether measuring a commercial app's accuracy on them in
  house counts as commercial use is a legal question this note does not answer; the owner should decide before
  they enter CI.
- **Share-alike** (CC BY-SA on original MIMII, CC BY-NC-SA on the DCASE sets) applies to redistributed copies and
  adaptations of the data. Whether a trained model is an adaptation is unsettled; avoid the question by keeping
  these sets for evaluation.
- **Per-clip licences** (FSD50K, MUSAN, FMA, Freesound subsets): the collection licence does not override the
  clip's. Build the filter from the per-clip metadata first and keep the attribution list; CC-BY needs credit,
  which for an app means an acknowledgements screen or a file in the repository.
- **AudioSet:** the card says CC-BY-4.0, but the audio was downloaded from YouTube, and the uploader of each video
  holds the rights (inferred; Google's licence covers the labels and ontology). Test only.
- **No audio ships in the app.** All of this is test and training material. Nothing here changes the offline
  rule in [CLAUDE.md](../../CLAUDE.md); datasets stay out of the repository and are fetched by a script.
- **Lossy mirrors.** The `philgzl/*` copies are Opus. Fine for a classifier test; wrong for anything that
  measures distortion or noise floor.

## Open questions

1. May non-commercial datasets be used for internal accuracy tests of a paid app? Owner or legal decision.
2. Which sample rate do the models take? Several sets are 16 kHz (MUSAN, LibriSpeech, all machine sets), which
   removes everything above 8 kHz. Buzz and rub products sit high in the band, so the anomaly model probably
   needs 44.1 or 48 kHz data, which only our own recordings provide.
3. Does the built-in SoundAnalysis classifier's label set map cleanly onto FSD50K and ESC-50 classes? Needs a
   label-mapping table before any accuracy number means anything. Not checked here.
4. How many drivers, phones and rooms make a usable defect set, and who damages the drivers? Needs a plan note
   before phase 6.
5. Do the synthetic defect models in section 2 resemble real defects? Unknown until a few real damaged drivers
   are recorded.
6. Is the MIT IR Survey CC BY 4.0? The Hub copies disagree; check the source page.

## Not verified

- **Original MIMII on the Hub.** [`stdt1/mimii_pump_datasets`](https://huggingface.co/datasets/stdt1/mimii_pump_datasets)
  holds pump data as mel spectrograms with `label` and `snr` columns (API), but has an empty card and no licence.
- **MIMII DUE, ToyADMOS, ToyADMOS2.** No standalone Hub entry found. MIMII DUE is CC BY-NC-SA 4.0 on Zenodo
  (record 4740355). ToyADMOS licences were not checked.
- **[`taohu/egfxset`](https://huggingface.co/datasets/taohu/egfxset).** Electric guitar notes through effects,
  8,970 clips at 44.1 kHz with an `effect` column, 6.5 GB (API). Possible proxy for nonlinear distortion. No card,
  no licence, effect list not read.
- **[`kuhlmannm/is25-local-distortions`](https://huggingface.co/datasets/kuhlmannm/is25-local-distortions).**
  Tagged `mit`, 7,032 rows, 3.8 GB (API); file paths look like LibriSpeech speech with local distortions. Empty
  card, so contents and distortion types are unknown.
- **[`ARTPARK-IISc/Vaani-Noise-Event-Dataset`](https://huggingface.co/datasets/ARTPARK-IISc/Vaani-Noise-Event-Dataset).**
  Tagged `cc-by-4.0`, gated (automatic approval), 90,637 clips with `NoiseCategory` and time-stamped noise tags
  (API). The card needs a login and was not read.
- **[`FluidInference/musan`](https://huggingface.co/datasets/FluidInference/musan).** The most downloaded MUSAN
  copy, but 1.15 GB and 801 files (API) cannot hold the 109 h its card claims. Probably a subset.
- **[`bilguun/musan-noise`](https://huggingface.co/datasets/bilguun/musan-noise)** (930 noise files, tagged
  `cc-by-4.0`) and **[`m-a-p/GTZAN`](https://huggingface.co/datasets/m-a-p/GTZAN)** (tagged `cc-by-4.0`): empty
  cards. GTZAN is commercial music clips; the tag is doubtful (inferred).
- **[`ltnghia/DNS-Challenge`](https://huggingface.co/datasets/ltnghia/DNS-Challenge).** Copy of the Interspeech
  2020 DNS Challenge repository, 80 GB, no licence tag. Its card lists DEMAND as CC BY-SA 3.0, which contradicts
  the DEMAND Zenodo record (CC BY 4.0). Not examined further.
- **DESED, SONYC-UST, MUSDB18, MTG-Jamendo, VCTK.** Hub entries exist; cards not read.
- **Sample rates** of `benjamin-paine/mit-impulse-response-survey`, `ltuncay/chime-mimii-dg`,
  `HTill/dcase2025_task2_dev` and `quinnlue/tau-urban-acoustic-scenes-2022-mobile-split5` are not stated in the
  card text that was read.
- **Hours** were taken from cards, not computed from audio.
