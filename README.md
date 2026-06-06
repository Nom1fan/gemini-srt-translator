# Gemini SRT Translator

Simple Windows app for translating `.srt` subtitle files with Gemini.

## Download

Download v1.0.0:

```text
https://github.com/Nom1fan/gemini-srt-translator/releases/download/v1.0.0/GeminiSrtTranslator-v1.0.0.zip
```

## What It Does

- Translates subtitle files from Hebrew to English.
- Can also translate English to Hebrew.
- Keeps SRT timing and numbering intact.
- Preserves common subtitle tags such as `<i>` and `{\\an8}`.
- Saves the translated file next to the original subtitle.

## How To Run

Double-click:

```text
Run Gemini SRT Translator.cmd
```

If that does not work, right-click `GeminiSrtTranslator.ps1` and choose **Run with PowerShell**.

## How To Use

1. Click **Browse...** and choose an `.srt` file.
2. Choose translation direction:
   - **Hebrew to English** is selected by default.
   - **English to Hebrew** is also available.
3. Click **Translate**.
4. Wait for the progress bar to finish.

The translated subtitle is created in the same folder as the source file.

Use **Cancel** to stop a translation. The app stops the background translation process and does not write an output file.

Before translating, the app checks a sample of the subtitle text. If the selected direction looks wrong, for example Hebrew to English on an already-English file, it warns you and stops.

Output names:

```text
Hebrew to English:  name.eng.srt
English to Hebrew:  name.heb.srt
```

## First Run: Gemini API Key

The first time you translate, the app asks for a Gemini API key.

To get one:

1. Open:

   ```text
   https://aistudio.google.com/app/apikey
   ```

2. Sign in with your Google account.
3. Click **Create API key**.
4. If asked, create or select a Google Cloud project.
5. Copy the key.
6. Paste it into the app and click **Save**.

After that, the app remembers the key and will not ask again.

The key is stored encrypted for your Windows user at:

```text
%APPDATA%\GeminiSrtTranslator\key.bin
```

Use **Reset API Key** if you need to replace it.

## Notes

- The app uses `gemini-3.5-flash`.
- Large subtitles are translated in chunks.
- If Gemini rate limits or quota are hit, try again later.
- Do not share your API key.

## Tests

Run the local tests from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-GeminiSrtTranslator.ps1
```

The tests check script parsing, core subtitle helpers, language-direction protection, Gemini response parsing errors, mock worker success, and mock worker cancellation without calling Gemini.

To also run the opt-in live Gemini end-to-end tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-GeminiSrtTranslator.ps1 -Wet
```

The wet tests use the saved API key and make two tiny live Gemini API calls. They translate one Hebrew subtitle to English and one English subtitle to Hebrew, then check the worker status, logs, output file, timing, and detected output language.
