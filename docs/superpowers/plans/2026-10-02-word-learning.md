# Word Learning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement task-by-task.

**Goal:** Known/learning word states, persistent contextual vocabulary and Anki export.
**Architecture:** SQLite owns words/cards; Flutter edits and exports; Translator receives a status map and reports tapped words without network calls.
**Tech Stack:** existing Flutter 3.47.2, sqflite, uuid, csv, Foliate JS.
**Spec:** ../specs/2026-10-02-word-learning-design.md

## Global Constraints

- Preserve interlinear/CEFR behavior and original DOM/reading position.
- Existing dependencies only; no network on word-state actions.
- Do not open the user's library during tests.
- Source-language auto must be resolved explicitly before saving.
- User authorization: continue the previously agreed learning/Anki phase; routine implementation choices use this spec.

## Review Focus

- All existing database versions migrate without losing books, notes or cache.
- Case/apostrophe normalization matches JS and Dart without stripping accents.
- Known/learning visibility applies to both JSON and marker translation formats.
- Different senses retain examples and stable Anki IDs; cache clearing does not delete vocabulary.
- Tap does not interfere with swipe/selection/link/annotation behavior; other-book navigation must not duplicate reader GlobalKeys.

### Task 1: Storage and export

Files: lib/dao/database.dart, lib/dao/vocabulary.dart, lib/models/vocabulary.dart,
lib/service/vocabulary/anki_export.dart, test/vocabulary_test.dart.

- [ ] Add regression test for missing v9 tables; run RED.
- [ ] Implement two-table migration, normalized keys, transaction save/status changes and queries.
- [ ] Add tests for persistence, duplicate ID, different context, language isolation, backup copy and cache independence.
- [ ] Implement plain UTF-8 CSV with Anki directives using existing csv; check escaped multiline fields and repeated IDs.
- [ ] Run tests and commit.

### Task 2: Personal interlinear hints and tap

Files: assets/foliate-js/src/translator.js, view.js, interlinear-smoke.html,
lib/page/book_player/epub_player.dart, lib/widgets/reading_page/vocabulary_word_dialog.dart.

- [ ] Extend browser check for known/learning priority and tap payload; run RED.
- [ ] Capture paragraph CFI before ruby changes; delegate short tap/keyboard actions, preserving selection and gestures.
- [ ] Apply local status map without network; retain raw translations for editing hidden hints.
- [ ] Connect Flutter popup/save/refresh with resolved book language and mounted checks.
- [ ] Run browser and Flutter checks; commit.

### Task 3: Dictionary and delivery

Files: lib/page/vocabulary_page.dart, reading_settings.dart, app_en.arb/app_ru.arb,
docs/word-learning.md; rebuild dist/bundle.js.

- [ ] Add search/status/book filtering, editing, reset, copy, context navigation and export.
- [ ] Reuse existing reader navigation while avoiding duplicate GlobalKeys.
- [ ] Generate localizations, build JS, run full tests and analyzer.
- [ ] Independent focused review and corrections; Windows/Android builds.
- [ ] Commit/push new branch and create stacked draft PR against codex/upstream-refresh.
