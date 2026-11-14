---
type: "explanation"
status: "draft"
tags:
  - "explanation"
  - "copy"
  - "onboarding"
---
# How Resoniq measures, and why it needs its own test sound

The explanation for a person who asks "why can't I just play some music?". It is the source for copy in the
app: a candidate fourth intro page, the "sound is coming from this iPhone" state and the test sound files
screen ([App](modules/App.md)). Nothing here is in the app's intro yet; that needs a mockup first
([design/screens](../design/screens/README.md)).

## The short answer

Resoniq compares what was played with what the microphone heard. That only works when it knows exactly what was
played, so it plays its own test sound: a tone that rises from the deepest bass to the highest treble. Music
cannot stand in for it.

## Why music cannot be used

- **The app has to know what went in.** With an unknown song it cannot tell "the speaker does not play 80 Hz"
  from "the song has nothing at 80 Hz right now".
- **Music does not cover everything.** The test sound passes through every pitch from 10 Hz to 22 kHz at the same
  level. A song leaves parts of the range empty, and those parts of the speaker would go unchecked.
- **A buzz is found by what was not played.** Distortion is measured by playing one clean pitch at a time and
  looking for sound at other pitches. Music is full of overtones already, so the speaker's cannot be told from
  the recording's.
- **Repeating needs the same signal.** The test runs three times, and what shows up in only one run is treated
  as a noise in the room. That works only when each run is identical.

## Why the file is a WAV

When the test sound is played from another device ([phase 7](plans/phase-7-external-playback.md)), the file is
an uncompressed WAV. MP3 and AAC cut the highest notes and add distortion of their own, and the app would count
both against the speaker. A lossy copy may still measure, but the top of the range and the distortion figures
are not to be trusted.

## What music is good for

"Watch the sound live" on Measure shows the spectrum of whatever is playing. It is for looking, and it gives no
verdict on a speaker.

## Is the test sound safe

It plays at a quarter of full level (−12 dBFS), fades in and out so it cannot click, and lasts four seconds a
run. The volume is the person's own; the app asks for a normal listening level.

## Candidate copy for the app

Not built. In the design system's voice (plain, first person, no jargon), for a mockup to be drawn from.

**An intro page, or a "How it works" entry in Settings**

> Kicker: How it works
> Headline: I play a sound I know, and listen to what comes back.
> Body: A tone rises from the deepest bass to the highest treble. I know exactly what I played, so whatever is
> missing, too loud or rough in what I hear is the speaker or the room. That is why I can't use your music: I
> wouldn't know what it was supposed to sound like.

**On the test sound files screen**

> Play the file as it is. A copy converted to MP3 or AAC loses the highest notes, and I would blame the speaker.

**One line for the "sound is coming from this iPhone" state** (already says this in other words)

> I have to play the test sound through your speakers, because I compare what I play with what I hear.
