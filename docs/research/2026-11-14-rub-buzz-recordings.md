---
type: "research"
tags:
  - "research"
  - "dsp"
  - "rub-and-buzz"
  - "datasets"
---
# Three real rub and buzz recordings, and what our DSP says about them

**Asked:** what the Kit's measures say about real recordings of a good, a borderline and a bad loudspeaker, and
what the sources the owner collected on 2026-11-14 add to the [datasets note](2026-11-13-audio-datasets.md) and the
[defect dataset plan](2026-11-13-defect-dataset-plan.md).

## The recordings

Three WAV files from Listen, Inc. (maker of the SoundCheck test system), given by the owner as a reference unit, a
unit with strong distortion and a borderline unit of one loudspeaker model, recorded for rub and buzz testing.

| File | Format | Content |
|---|---|---|
| `rtw-tone-sn-57-scaled-10E0-Pa-FSD.wav` | 44.1 kHz, 24-bit, mono, 10.1 s | A steady 256 Hz tone |
| `rtw-tone-sn-76-scaled-10E0-Pa-FSD.wav` | same | same |
| `rtw-tone-sn-97-scaled-10E0-Pa-FSD.wav` | same | same |

- **They are not in the repository.** The page they come from states no licence, only "Copyright © Listen, Inc.",
  and this repository is public. They live in `data/listen-rub-buzz/`, which git ignores; a test that needs them
  is skipped when they are absent.
- **Which serial number is which unit is not stated in the file names.** The measurements below make sn-57 the bad
  unit beyond doubt. That sn-76 is the borderline one and sn-97 the reference is inferred from a 3.5 dB difference
  and should be confirmed against the source.
- They are a measurement microphone close to the driver, a steady tone, no room. The app records a sweep with a
  phone in a living room. What follows shows what the measure can separate in the best case, not what the app
  will achieve.

## Measured (2026-11-14)

`ToneDistortion.analyze` on the settled middle of each file (the first and last second left out), run by
`RealRubBuzzTests` in `ResoniqDSPTests`:

| Unit | THD, orders 2–10 | Non-harmonic residue (everything above the tenth harmonic, noise share removed) |
|---|---|---|
| sn-57 | 4.18 % | −40.3 dB |
| sn-76 | 1.55 % | −58.1 dB |
| sn-97 | 1.51 % | −61.6 dB |

An independent script (numpy, not the Kit) gave the same figures and two more: in sn-57 the energy above ten times
the tone repeats once every cycle of the tone (correlation 0.99 at one period; 0.49 and 0.61 for the others), which
is what a part touching once per excursion does; its level there is −40.6 dB against −59.5 and −61.9 dB.

## What it tells us

- **THD alone misses the bad unit.** 4.2 % is far under `DiagnosisThresholds.distortionPercent` (10 %), so today's
  diagnosis would call sn-57 clean. The first guess of 10 % is not the problem; the measure is. Rub and buzz lives
  in the high orders, and `HarmonicDistortion.defaultOrders` is 2 to 5.
- **The high-order residue separates it by about 18 dB**, and the Kit already computes it for a steady tone
  (`ToneDistortionResult.nonHarmonicResidue`). The app does not use `ToneDistortion` anywhere.
- **Borderline against good is 3.5 dB**, which is inside what a room and a phone will move. No claim is made that
  the app can tell those two apart.

## The other sources read the same day

| Source | What it is | Use here |
|---|---|---|
| Stanford CS231N 2025, "AI-based Acoustic Defect Detection for Speaker Manufacturing" (Yitong Lu) | OK / not-good classifier for one speaker model on a production line, from the mel spectrogram of a one-second sweep. Private factory data: 450 good and 750 bad labelled, 5,000 to 8,000 unlabelled | The recipe closest to ours. A two-layer CNN on 300 samples reached 94 %; ImageNet-pretrained models did no better (93 %), and heavy augmentation fell to 80.5 %; relabelling more strictly gave 95.2 % with no false positives in 112; masked-reconstruction pretraining on the unlabelled recordings, then fine-tuning, gave 96.4 %. On two other speaker types 87 %. Sensitive to background noise. It states that no open model or dataset for speaker defects exists |
| Klippel dB-Lab TFA documentation | A spectrogram tool (wavelet, STFT, cumulative spectral decay, Bark filter bank) | Method only: a loose particle shows as vertical lines in the spectrogram of a sweep. No detection algorithm, no data |
| Listen, Inc. CLEAR Perceptual Rub & Buzz sequence page | A stepped sine from 20 kHz down to 50 Hz, distortion weighted by a hearing model, in phons against frequency, limit 25 phons, audible from about 20 | The idea of weighting by audibility. No algorithm step is described on the page; the sequence note PDF and the AES paper it cites were not read |
| ToyADMOS2 (Zenodo 4580270) | Toy cars and trains, normal and deliberately damaged, 48 kHz | 169 GB in all, a 10.5 GB benchmark example; non-commercial. Method comparison for the anomaly model only |
| NISQA (Zenodo 4728081) | Speech quality over codecs and calls, 15.9 GB | None: speech, not loudspeakers |
| Timbral Constancy (Zenodo 18966) | Listening tests on loudspeaker and room coloration, 2.5 GB, CC BY-NC 4.0 | None: perception, no defects |
| SMARD (Aalborg University) | Three loudspeakers, four microphone arrays, one room, 48 configurations, 48 kHz FLAC with sweeps and impulse responses, about 15 to 19 GB | Healthy speakers in a real room with the played signal recorded alongside: could test deconvolution. No licence is stated on its pages; no defects |
| Loudspeaker directivity (Zenodo 10255555) | Anechoic directivity of four sources (two Genelec monitors, an omni source, a spherical one), 3.3 GB, CC BY 4.0 | How level falls off axis by frequency, measured: relevant to "could be the phone's angle" for the top-end dip. No defects |

## Open questions

1. Which serial number is the borderline unit? Confirm on the source page.
2. Can the high-order residue be read from the sweep the app already plays (the harmonic impulse responses above
   order 10 land before the linear one), or does it need a steady tone step added to the test? Not measured.
3. What does the residue read for a healthy speaker through a phone in a room? The floor decides whether −40 dB
   is detectable there. Needs device recordings, which the app does not keep yet.
4. May the Listen recordings be used in tests of a commercial app? Owner or legal decision; until then they stay
   local.
