# Remaining reading roadmap

User authorized completing remaining items after vocabulary delivery (PR #4).
Base: ffa504aa, branch codex/translation-reliability in the existing isolated checkout.

## Required scope

- Translation errors/short responses remain retryable; completed words survive retries.
- Namespace cache by language pair, provider and format revision without a database downgrade or deletion of vocabulary.
- Current page first, cached hints immediately; short scroll debounce, no two-second page delay; deduplicate work and reject stale results.
- Native batches for Azure, Google Cloud and DeepL; bounded fallback and retry counts; preserve AI RPM limiter and serialize background classification with translation.
- Update CEFR metadata in place without clearing all paragraph translations.
- Preserve original text/spacing and inline links/emphasis while rendering hints. Validate source coverage and repair only missing words with original context.
- Finish remaining learning actions: selected phrases, existing TTS/context explanation on demand, native sharing with copying available.
- Regression checks, independent review, Windows/Android builds and stacked draft PR.

## Execution

1. [x] Reproduce empty/short-response, language-key and coverage bugs; implement testable small helpers and cache namespaces.
2. [x] Repair providers/bridge and background levels without retry storms or stale writes.
3. [x] Repair JS scheduling/rendering and verify cold/warm cache, page/scroll, cancellation and original DOM.
4. [x] Complete phrase/TTS/explanation/share actions using installed components.
5. [ ] Full checks, final review/corrections, builds, commit/push and draft PR.

## Boundaries and evidence

Old reverse-engineered Edge auth endpoint returned404 during a public two-phrase probe on2026-10-02. Do not restore an endpoint verified unavailable; Azure and AI remain supported paths. Never read personal provider credentials or send book text during tests.
Actual Anki UI import, physical-device p95 and cross-device sync need the respective runtime/device; report limits rather than asserting these checks passed. Automated backup reopen and CSV round-trip are already covered.
Roadmap stage6 deliberately follows daily use: automatic Telegram, local SRS, offline datasets and universal lemmatization remain deferred, not mandatory work in this pass.
