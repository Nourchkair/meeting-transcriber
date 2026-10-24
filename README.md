# Sawti

Sawti is an independent macOS transcription application derived from [Meeting Transcriber](https://github.com/pasrom/meeting-transcriber). The project keeps its own app identity, local data paths, development build, and roadmap. Its first internal milestone is focused on preserving recordings and transcripts before adding online-meeting capture.

## Alpha development scope

The current code provides a microphone-only recording route through an in-bundle helper process, on-device transcription through the existing WhisperKit and Parakeet engines, a full transcript viewer, and plain-text export. The engine's original segment text is saved separately before normalization or speaker labeling; the final transcript remains a separate artifact. Transcript and audio files are written with owner-only file permissions.

The signed development app has now passed authorized microphone capture, a spoken-marker check (all nine phrases recognized), a 10:12 microphone session with local ASR, and a real force-quit recovery through saved transcript output. The recovered 49-second recording also completed local transcription and diarization after recovery. This completes Sawti's internal Alpha functional milestone; it does not make this checkout release-ready.

## Local processing and network use

Recording and inference use local macOS audio capture and local models; Sawti does not require a paid transcription API or subscription. The selected model may need to be fetched on first use. The user accepted the offline Wi-Fi check for project sequencing; model inference also completed from the local cache. Optional protocol providers remain available, but the default provider is disabled so transcripts are not sent to a summarization service by the core workflow.

## Build

Requires macOS 14.2 or later and the Swift toolchain declared by the package. Build the local development app bundle without fetching the optional echo-cancellation model:

```bash
SAWTI_SKIP_OPTIONAL_MODEL_FETCH=1 ./scripts/run_app.sh --build-only
```

The bundle is created at `app/MeetingTranscriber/.build/MeetingTranscriber-Dev.app`. Use `./scripts/run_app.sh` to build and launch it. macOS may ask for microphone permission when a recording is started. Local self-signed or ad-hoc signatures are for development only and cannot be used for distribution or notarization.

Run the isolated unit and integration suite from the repository root:

```bash
./scripts/test-isolated.sh
```

That suite uses a disposable test home and skips tests that require downloading or loading real ASR/VAD models. It does not qualify actual audio capture, transcription accuracy, or performance.

## Data locations

- App data and recovery recordings: `~/Library/Application Support/Sawti/`
- Default protocol and transcript output: `~/Downloads/Sawti/`
- Logs: `~/Library/Logs/Sawti/`

Sawti does not import or migrate data from an installed Meeting Transcriber app. Original and final transcript files are stored separately when the corresponding output preference is enabled. Use the in-app transcript viewer's **Export Copy…** action to create a user-selected plain-text copy.

## Current limitations

- The microphone Alpha flow passed on the signed Sawti development app, including spoken-marker transcription, a 10-minute session, and force-quit recovery. Clean-install TCC persistence and rebuild continuity still need qualification.
- Google Meet, Zoom, and Teams audio capture have not passed Sawti's Beta validation. Existing upstream app-audio mechanisms remain in the codebase; the Alpha helper route is microphone-only.
- The development signing identity is self-signed and is not suitable for distribution or notarization. Clean-install permission prompts, TCC persistence after rebuilds, and release signing remain unverified.
- WhisperKit model initialization took 185.36 seconds and 180.55 seconds on two recent launches on the MacBook Air M2/8 GB host, with high Neural Engine compiler activity. Transcription succeeded after loading, but this startup delay is a measured usability risk. Peak memory, thermal behavior, long-session word accuracy, and MacBook Pro-specific behavior remain unqualified. The 10-minute transcript had no ground-truth script; the spoken-marker check is a limited accuracy sample.
- AcademiaOS integration is deferred until Sawti is dependable as an independent application.

See [`docs/OPTIMIZATION_BACKLOG.md`](docs/OPTIMIZATION_BACKLOG.md) for planned product improvements and release-qualification work, [`docs/validation/VALIDATION.md`](docs/validation/VALIDATION.md) for evidence and pending checks, and [`docs/CAPABILITY_REGISTER.md`](docs/CAPABILITY_REGISTER.md) for the disposition of inherited features. The repository retains the upstream MIT license and notices.

For beta release publishing, first-install instructions, and Sparkle updates, see [`docs/BETA_DISTRIBUTION.md`](docs/BETA_DISTRIBUTION.md).
