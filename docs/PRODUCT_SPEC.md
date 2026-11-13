# Resoniq — High-Level Product Specification

**Version:** 0.2  
**Platform:** Native iOS  
**Architecture:** 100% On-Device  
**Status:** MVP Specification

## 1. Product Vision

Resoniq is an intelligent iOS application for speaker diagnostics, audio system analysis, room acoustics measurement, and AR-guided speaker placement optimization.

The app combines Digital Signal Processing (DSP), on-device AI, LiDAR room scanning, and augmented reality to help users understand and improve their sound systems.

**Core concept: Diagnose → Measure → Optimize.**

The entire application runs locally on the iPhone, without accounts, cloud processing, or backend dependencies.

## 2. Core MVP Features

### 2.1 Speaker Health Check

Detect potential defects in speakers using the iPhone microphone and automated audio tests.

**Capabilities:**
- Guided speaker testing without equipment registration.
- Automated frequency sweeps and test signals.
- Frequency response analysis.
- Harmonic distortion analysis (THD).
- Detection of rattling, buzzing, crackling, and mechanical anomalies.
- Potential woofer, midrange, and tweeter malfunction detection.
- Left/right speaker comparison.
- AI-assisted anomaly detection.
- Clear diagnostic report with confidence indicators.

Results should distinguish between suspected hardware defects, environmental interference, and inconclusive measurements.

### 2.2 Audio System Analysis

Evaluate the overall sound reproduction quality of an audio system.

**Capabilities:**
- Real-time FFT spectrum analyzer.
- Frequency response measurement.
- Harmonic and non-harmonic distortion analysis.
- Stereo channel balance and comparison.
- Frequency irregularity detection.
- Audio visualization and measurement history.
- Simple explanations of detected problems.

### 2.3 Room Acoustic Analysis

Analyze how the listening environment influences sound quality.

**Capabilities:**
- Guided measurements at the listening position.
- Multiple measurement points.
- Room frequency response analysis.
- Detection of bass peaks and nulls.
- Room resonance identification.
- Impulse response and decay analysis where measurement quality permits.
- Comparison of acoustic measurements.
- Room-specific recommendations.

### 2.4 LiDAR Room Scanning

Use Apple RoomPlan to reconstruct the listening environment.

**Capabilities:**
- Guided 3D scanning.
- Automatic identification of walls, doors, windows, and major furniture.
- Room dimension extraction.
- 3D room visualization.
- Manual correction of detected geometry.
- Identification of speaker and listening positions.
- Locally saved room layouts.

LiDAR scanning requires a compatible device. A simplified manual room-layout workflow should be available on devices without RoomPlan support.

### 2.5 AR Speaker Positioning

Use ARKit and RealityKit to guide users toward better speaker placement.

**Capabilities:**
- Visualize speaker locations in the real room.
- Mark the listening position.
- Display speaker distances and orientation.
- Visualize stereo geometry.
- Recommend speaker spacing, wall distance, and toe-in angle.
- Guide physical speaker repositioning using AR overlays.
- Compare before-and-after measurements.

### 2.6 Intelligent Placement Optimization

Combine room geometry, DSP measurements, and optimization algorithms to recommend improved speaker positioning.

**Capabilities:**
- Analyze speaker placement relative to the listening position.
- Detect problematic acoustic response patterns.
- Suggest positioning adjustments.
- Optimize stereo symmetry and listening geometry.
- Support subwoofer placement recommendations.
- Compare alternative configurations.
- Validate improvements through repeated measurements.

Optimization should rely on actual acoustic measurements, not only geometric predictions.

### 2.7 Advanced AI Audio Diagnostics

Integrate on-device machine learning models to detect and classify audio anomalies.

**Capabilities:**
- Acoustic anomaly classification.
- Detection of suspicious nonlinear distortion patterns.
- Classification of buzzing, rattling, and crackling.
- Distinguish potential speaker defects from environmental noise.
- Analyze DSP-derived features using machine learning.
- Provide explainable diagnostic recommendations.
- Report uncertainty and request repeated measurements when necessary.

AI predictions must complement DSP measurements rather than replace them.

## 3. On-Device AI Models

The application should investigate and integrate suitable pretrained models while allowing custom speaker-diagnostics models to be introduced.

### 3.1 Apple SoundAnalysis

**Framework:** SoundAnalysis + Core ML

Use Apple's built-in audio classifier for environmental sound identification and initial audio classification.

Potential uses:
- Detect background noise and interference.
- Identify unwanted environmental sounds during measurements.
- Improve measurement quality validation.

Supports real-time analysis with `SNAudioStreamAnalyzer`.

### 3.2 YAMNet

**Architecture:** MobileNet-based audio event classifier  
**Source:** Google / TensorFlow  
**Deployment:** Core ML conversion

YAMNet is pretrained on AudioSet and recognizes 521 classes of audio events.

Potential uses:
- Environmental noise recognition.
- Detection of audible buzzing and mechanical noises where represented by its training classes.
- Audio feature embeddings for specialized downstream classifiers.

YAMNet is not a pretrained speaker-defect diagnostic model and requires evaluation or adaptation for this application.

### 3.3 PANNs — Pretrained Audio Neural Networks

**Candidate architecture:** CNN14 or smaller compatible variants  
**Deployment:** PyTorch → Core ML

Potential uses:
- Rich audio feature extraction.
- Classification of acoustic anomalies.
- Transfer learning for speaker failure recognition.
- More advanced sound-event recognition.

Model size, conversion compatibility, and inference performance must be evaluated before inclusion.

### 3.4 Custom Speaker Anomaly Classifier

**Recommended architecture:** Lightweight CNN / MobileNet-style network  
**Input:** Log-mel spectrograms and selected DSP features  
**Deployment:** Core ML

Target classes:
- Normal speaker reproduction.
- Mechanical rattling.
- Voice-coil rubbing.
- Buzzing.
- Crackling.
- Potential driver malfunction.
- Environmental interference.
- Unknown anomaly.

A specialized model should be trained or fine-tuned using recordings of known-good and defective speakers, ideally captured across multiple devices and environments.

### 3.5 Acoustic Anomaly Detection Model

**Recommended architecture:** Lightweight autoencoder or comparable novelty-detection network.

Potential uses:
- Identify unexpected spectral patterns.
- Detect deviations from expected test-signal reproduction.
- Flag anomalies not covered by predefined classes.
- Assist with unknown defect detection.

Training, thresholds, and evaluation should account for microphone differences, playback levels, and room acoustics.

### AI Implementation Principles

- All inference runs through Core ML locally.
- Prefer efficient models suitable for Apple Neural Engine execution.
- Combine multiple measurements before diagnosing faults.
- Use DSP-derived features alongside neural network predictions.
- Optimize inference latency, energy consumption, and model footprint.
- Maintain replaceable model interfaces for future improvements.

## 4. Audio DSP Engine

Implement a dedicated native DSP engine independent of the UI.

**Core capabilities:**
- Test signal generation.
- Audio recording and synchronization.
- FFT and spectral analysis.
- Frequency response estimation.
- Impulse response estimation.
- THD and harmonic analysis.
- Non-harmonic distortion and Rub & Buzz analysis.
- Noise-floor estimation.
- Stereo comparisons.
- Acoustic measurement aggregation.

**Primary technologies:**
- AVAudioEngine
- AVAudioSession
- Accelerate / vDSP
- Core Audio
- Core ML
- SoundAnalysis

The DSP engine should expose reusable interfaces for measurement sessions, audio processing, and diagnostic results.

## 5. Technology Stack

| Component | Technology |
|---|---|
| Language | Swift |
| User Interface | SwiftUI |
| Architecture | Modular native iOS |
| Audio Capture / Playback | AVAudioEngine / Core Audio |
| DSP | Accelerate / vDSP |
| AI Inference | Core ML |
| Sound Classification | SoundAnalysis |
| Room Scanning | RoomPlan |
| AR Tracking | ARKit |
| 3D Visualization | RealityKit |
| Local Persistence | SwiftData / FileManager |
| Data Visualization | Swift Charts / Metal where needed |
| Concurrency | Swift Concurrency |

No backend, authentication service, remote inference, or cloud database is required for the MVP.

## 6. User Experience

The application must be extremely simple for first-time users.

### Main Features

**Check Speaker**

Quick guided test for detecting potential speaker problems.

**Analyze Sound**

Measure sound reproduction and inspect frequency response and distortion.

**Optimize My Room**

Scan the room, analyze acoustics, and receive AR-guided speaker placement recommendations.

### UX Principles

- No registration.
- No onboarding questionnaire.
- No mandatory equipment model selection.
- Minimal manual configuration.
- Guided step-by-step measurements.
- Clear visual results.
- Simple explanations instead of technical jargon.
- Advanced technical data available on demand.
- Automatic saving of completed measurements.

Users should be able to launch the app and start a basic speaker test immediately.

## 7. Measurement Workflow

### Speaker Health Check

1. Select **Check Speaker**.
2. Follow simple microphone positioning instructions.
3. Start automated audio tests.
4. Record and analyze the speaker response.
5. Display detected anomalies and confidence.
6. Optionally repeat for the second speaker.

### Room Optimization

1. Select **Optimize My Room**.
2. Scan the room using RoomPlan or enter a simplified room layout.
3. Mark speakers and listening position.
4. Run guided acoustic measurements.
5. Analyze acoustic response.
6. Generate placement recommendations.
7. Display adjustments in AR.
8. Repeat measurements to validate improvements.

No equipment registration is required.

## 8. Reliability & Safety

The system must account for smartphone microphone limitations and environmental interference.

**Requirements:**
- Use repeatable and controlled measurements.
- Validate ambient noise before testing.
- Minimize microphone processing and automatic gain adjustments.
- Avoid excessively loud or potentially damaging test signals.
- Detect clipping and invalid recordings.
- Identify inconclusive results.
- Provide optional external microphone support in the future.
- Validate suspected anomalies through repeated measurements.
- Avoid claiming confirmed physical defects without sufficient evidence.

Results should be presented as diagnostic guidance, not laboratory certification.

RoomPlan provides room geometry, not acoustic material properties. Acoustic recommendations must incorporate measured sound response.

## 9. Local Data & Privacy

All application data remains on the device.

**Locally stored data:**
- Audio measurement sessions.
- Analysis results.
- Room scans.
- Speaker positions.
- Diagnostic history.
- Saved optimization configurations.
- Optional recordings.

Use SwiftData for structured data and local files for audio and 3D assets.

Audio recordings and room scans are not uploaded to external services.

Internet connectivity is not required for core functionality.

## 10. MVP Scope

The complete initial MVP includes:

- Native Swift/SwiftUI application.
- Automated speaker health diagnostics.
- Real-time spectrum analyzer.
- DSP-based acoustic measurements.
- Advanced on-device AI diagnostics.
- Frequency response and distortion analysis.
- Room acoustics analysis.
- LiDAR scanning with RoomPlan.
- AR speaker positioning.
- Intelligent speaker placement optimization.
- Subwoofer positioning recommendations.
- On-device measurement storage.
- Diagnostic reports and comparison history.
- Fully offline operation.

These capabilities are part of MVP scope, although implementation can progress incrementally.

## 11. Future / Premium Features

The following are outside the initial MVP:

- Equipment registration and model catalog.
- Manufacturer-specific speaker profiles.
- Speaker reference measurement database.
- Automatic equipment recognition.
- Model-specific diagnostics.
- Professional calibrated microphone workflows.
- Advanced multichannel home-theater calibration.
- Exportable professional certification reports.
- Large-scale defect model training datasets and specialized model updates.
- Optional ecosystem integrations.
- Android version.

## 12. Development Approach

Build the project around independently testable modules.

**Module A — Audio Engine**

Audio input/output, test generation, DSP and measurement management.

**Module B — AI Diagnostics**

Core ML inference, anomaly detection and diagnostic confidence estimation.

**Module C — Room Intelligence**

RoomPlan integration, room geometry and spatial coordinates.

**Module D — AR Optimization**

AR visualization, speaker positioning and acoustic optimization.

**Module E — User Experience**

SwiftUI workflows, reports, visualizations and measurement history.

Development should be incremental, but all five modules belong to the MVP.

## 13. Product Success Criteria

- Users can run a speaker test without technical knowledge.
- Common audible speaker faults can be detected under validated conditions.
- Measurements are reproducible under comparable conditions.
- AI recommendations are supported by measurable evidence.
- AR guidance is easy to follow.
- Speaker positioning improvements can be verified.
- Core functionality operates entirely offline.
- The application remains responsive on supported devices.

---

## Core Product Principles

**1. Native by design.** Built specifically for Apple hardware and frameworks.

**2. Fully on-device.** No backend or cloud processing.

**3. Zero-friction UX.** Open the app and start measuring.

**4. DSP first, AI enhanced.** Mathematical measurements provide the foundation.

**5. Measure, don't guess.** Recommendations must be testable.

**6. Spatial intelligence.** Combine physical room geometry with real acoustic measurements.

**7. Progressive sophistication.** Simple for beginners, powerful for enthusiasts.

**8. Modular architecture.** Allow algorithms and models to evolve independently.

**Resoniq — Diagnose. Measure. Optimize.**
