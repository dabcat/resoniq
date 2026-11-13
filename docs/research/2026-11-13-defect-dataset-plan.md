---
type: "research"
tags:
  - "research"
  - "ai"
  - "datasets"
  - "defect-classifier"
---
# A plan for the first speaker-defect dataset

**Asked:** how the first dataset for the speaker-defect classifier ([PRODUCT_SPEC.md](../PRODUCT_SPEC.md) §3.4)
and the anomaly model (§3.5) can be collected with the app's own recordings, given that none exists
([audio datasets note](2026-11-13-audio-datasets.md): no dataset of defective loudspeakers on the Hub).

**Status:** a proposal. Nothing here has been collected. The numbers marked *guess* are orders of magnitude to
plan with, not results. The code that would take the data already exists and is tested on the Mac: the features
(`DefectFeatures`, `LogMelSpectrogram`), the model contract (`DefectModelDescription`) and the rules for how a
model's answer joins a report (`ModelAdvice`), all in [ResoniqDiagnostics](../modules/ResoniqDiagnostics.md).

## What one saved example must hold

One example is one speaker test (three runs) of one speaker, kept in full so that features can be recomputed when
the DSP changes:

| Part | Why |
|---|---|
| Each run's raw recording (mono float, 48 kHz) and the noise-floor recording | The model's input is recomputed from these; nothing derived is trusted alone |
| The sweep's parameters (start, end, duration, level, fade, sample rate) and the route delay | Deconvolution and THD depend on them; `LogSweep.measurement` may change |
| Each run's `RecordingCheck`, splice count and whether the phone moved | To exclude or weight bad runs the same way the app does |
| The `SpeakerReport` the app made, with its schema version | The DSP's own verdict, the baseline the model must beat |
| `DefectFeatures` and the `LogMelSpectrogram` configuration used | So a stored example and a live one are computed the same way |
| Device model, iOS version, audio route (built-in microphone, speaker output: AirPlay, Bluetooth, wired) | Phones and routes colour the recording; the split and the evaluation need them |
| Speaker identity: make, model, an id for this unit, driver layout, and a room id | To split by speaker and by room (below) |
| The label, who gave it, how (below), and how sure | Labels differ in strength; the training must know which is which |

Storage stays on the device. Getting examples off it needs an explicit export by the owner (a file the user
chooses to share), never an upload: the app has no networking ([CLAUDE.md](../../CLAUDE.md), "Offline and
private"). Nothing is collected from other users before a consent screen and a privacy review exist.

## How labels can be obtained honestly

In order of strength:

1. **The owner's own known speakers.** Speakers whose state is known independently: new or bench-checked units as
   `normal`, and units with a fault confirmed by taking them apart or by a repair shop (a loose dust cap, a rubbing
   coil, a torn surround). This is the only source of strong labels for the defect classes.
2. **Damage made on purpose to cheap drivers**, as the DCASE machine datasets did ("anomalies were collected by
   deliberately damaging target machines", see the datasets note): a loose screw or a grain of rice behind the
   grille for rattle, a pressed cone for rub, a cut surround, an overdriven amplifier for clipping. Strong labels,
   but for faults made in a lab, which may not look like faults that grow with age.
3. **The swap test as a weak label.** When the app asks the user to swap left and right and the problem moves with
   the speaker, that is evidence the fault is in the speaker; if it stays with the side, it is the room or the
   wiring. It says nothing about which defect class, so it can label `normal` against `not normal` only, and it
   must be stored as weak.
4. **Never the model's or the DSP's own output as a label.** Training on the app's verdicts would teach the model
   to repeat the DSP, which is the thing it has to beat.

The classes `environmentalInterference` and `unknownAnomaly` need no damaged speaker: the first comes from
healthy speakers measured with interference played on purpose (speech, music, a vacuum cleaner), the second is
what the anomaly model is for.

## How many examples

*Guess:* a first classifier on features plus a small spectrogram network needs on the order of **100 tests per
defect class from at least 20 different speakers per class**, and several hundred `normal` tests from as many
speakers as can be found. The reason it is a guess: there is no published learning curve for loudspeaker faults
recorded by a phone, and how separable the classes are depends on things not yet measured (how loud a rattle is
against the sweep, how much the room and phone colour the result). The first collection should be planned as a
pilot whose own learning curve (accuracy against the number of speakers) decides whether to collect more.

The anomaly model needs only healthy speakers, so its data can come first: *guess*, a few hundred tests of healthy
speakers across at least five phones and ten rooms.

## Splitting without flattering the result

- **Split by speaker unit, not by recording.** Three runs of one speaker are nearly the same signal; if one run is
  in training and another in test, the model is graded on a speaker it has already heard. Every example of a unit
  goes to one side.
- **Hold out whole rooms and whole phone models as well**, at least in a second evaluation, because the app will
  meet rooms and phones the training never saw.
- **Hold out a speaker model** (make and model) for a third evaluation: two units of the same model are closer to
  each other than to anything else.
- Keep the test set fixed once chosen, and look at it only for the final numbers.

## What synthetic augmentation can and cannot do

**Can:** widen the conditions a real example is seen in, and test the pipeline before real data exists.

- Simulated distortion and defects on healthy recordings: hard and soft clipping, polynomial waveshaping, bursts
  of high harmonics locked to the low-frequency excursion (rub and buzz), impact bursts when excursion crosses a
  threshold (rattle), noise modulated by the low frequencies (air leak). The DSP tests already simulate a buzz this
  way (`SimulatedSpeaker`).
- Room responses: convolve with measured room impulse responses, only from subsets that allow commercial use:
  [`audioSP-UoY/narrowband-truncated-rirs`](https://huggingface.co/datasets/audioSP-UoY/narrowband-truncated-rirs)
  subsets under CC BY 4.0, MIT or Apache 2.0 (not `c4dm`, CC BY-NC-SA).
- Noise at chosen signal-to-noise ratios: [`philgzl/demand`](https://huggingface.co/datasets/philgzl/demand)
  (CC BY 4.0), and speech and music interference from [`openslr/librispeech_asr`](https://huggingface.co/datasets/openslr/librispeech_asr)
  (CC BY 4.0) and the CC0 and CC BY clips of FSD50K
  ([`Fhrozen/FSD50k`](https://huggingface.co/datasets/Fhrozen/FSD50k), per-clip licence). Attribution goes in the
  app's licences screen if anything trained on them ships.

**Cannot:** stand in for real defects. A simulated rattle is the simulation's idea of a rattle; a model trained on
it learns the simulation. Synthetic examples may be used for training only alongside real ones, never in the test
set, and a model is judged only on real recordings of real speakers. Non-commercial sets (DCASE, ESC-50,
UrbanSound8K, Treble10) may be used to compare methods on the Mac, never to train anything that ships.

## What the model must beat to ship

The baseline is the app as it is: **the DSP rules alone** (`SpeakerDiagnosis`), run on the same held-out test set.
The comparison is per class and for "something is wrong" against `normal`:

- On the defects the DSP already measures (a buzz from THD, a dip, a quiet driver), the model must not be worse,
  or it adds nothing and risks contradicting a measurement.
- On the defects the DSP cannot measure from a sweep (rattle, rub, crackle), it must find a useful share of real
  faults at a **false-alarm rate on healthy speakers no higher than the DSP's own** (a false "possible rattle" on a
  good speaker is the worst outcome for this product).
- Its confidences must be calibrated on the test set, so that `ModelAdviceThresholds.minimumDefectConfidence`
  (0.7, a first guess) can be set from data: at the chosen threshold, the share of correct lines should match what
  "possible" promises the user.

Until a model clears all three on held-out speakers, rooms and phones, none ships, and the report says nothing on a
model's behalf, as it does today.
