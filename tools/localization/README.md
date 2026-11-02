The app selects the first supported language in macOS language preferences (Chinese or English), falling back to English. Restart the app after changing its language. User-created prompts, filenames and saved content are preserved.

- Add interface text with `AppLanguage.text("中文", arguments...)`; numbered `{0}` placeholders are replaced only in the template.
- Add its English translation to `Resources/Localization/en.json` and its source entry to `inventory.json`, then run `python3 tools/localization/generate.py`.
- Keep shared, text-free artwork in `Resources/`. Baked text has a matching composition in `Resources/en.lproj/`; load it through `AppLanguage.resource`.
- Permission descriptions live in both `InfoPlist.strings` files. The installer background has no language-specific text.
- Run `python3 tools/localization/check.py`, Chinese regression checks with `MACOSX_TEST_LANGUAGE=zh`, and English settings checks with `MACOSX_TEST_LANGUAGE=en`. The environment variable is a fixture override, not a user setting.
- `extract.py` is a migration helper; do not overwrite the original inventory after extraction. Its lexer also visits literals nested inside interpolated expressions.

The GitHub README is static documentation; it does not follow a local computer's language.
