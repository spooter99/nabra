# Contributing

Thanks for wanting to improve Nabra. Issues and pull requests are welcome.

## Getting set up

```bash
git clone https://github.com/spooter99/nabra.git
cd nabra
scripts/build.sh          # builds build/Products/Release/Nabra.app
```

See the README for requirements. To keep macOS permissions between rebuilds, add your own signing
identity in `Config/Signing.local.xcconfig` (explained in `Config/Signing.xcconfig`).

## Before you open a pull request

1. Run the logic checks. They cover the key gestures, text rules, learning and the safety guards:

   ```bash
   build/Products/Release/Nabra.app/Contents/MacOS/Nabra --selftest
   ```

2. If you touched recognition (anything under `Nabra/Core/ASR`), run the evaluation and compare
   with the numbers in the README. Small changes here have large, non-obvious effects:

   ```bash
   # once: rebuild the public test clips, following "Rebuilding" in eval/data/SOURCES.md
   APP=build/Products/Release/Nabra.app/Contents/MacOS/Nabra
   $APP --eval eval/data/manifest.jsonl --mode auto --out out.jsonl && python3 eval/score.py out.jsonl
   ```

3. Add a check to `Nabra/App/SelfTest.swift` for any new text rule or gesture.

## Guidelines

- Nabra must keep working with no network connection after the model is downloaded, and must not
  send audio or text anywhere.
- Prefer leaving the user's words untouched over a clever rewrite that is sometimes wrong.
- Keep comments about why the code does something, not what changed.

## Reporting a bad transcription

The most useful report says what you said, what was typed, and includes the matching lines from
`~/Library/Application Support/Nabra/nabra.log` (each dictation logs how the language was chosen).
Please do not attach recordings that contain anything private.
