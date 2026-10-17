# Runtime review — 2026-10-17

Reviewed main at `e218d0749767717bd86d5a69797d3f0c3d45c37b`, focusing on timers, refresh lifecycle, OAuth callback handling, diagnostic redaction and CI coverage. This is a targeted source review, not a complete security or macOS integration audit.

## Implemented

- **Diagnostic credential leakage:** `SensitiveDataRedactor.redactText` previously missed quoted JSON keys, OAuth `access_token`/`id_token`, camel-case refresh tokens and chunked session cookies. Redaction now handles those forms, preserves surrounding JSON/query parameters and matches complete keys. Regexes are compiled once rather than for every log message. This protects callers of `redactText`; it does not automatically sanitize every direct OSLog call.
- **Timer lifecycle:** `TimerManager.schedule` previously cancelled, created and registered a timer in separate operations, and `scheduledTimer` used the caller's RunLoop. Background callers could silently create timers that never fired. All timer operations now execute synchronously on the main thread, replacement is serialized, timers use common modes and completed one-shot timers are removed before calling client code. Background callers must not be awaited synchronously from the main thread.
- **Regression coverage:** added runtime helper checks and connected the existing Antigravity mapper checks to CI.

## Follow-up findings requiring dedicated integration coverage

1. **High — refresh/account response isolation.** `DataRefreshManager.fetchUsage()` resets a shared `pendingFetches` counter without preventing overlapping refreshes. `handleAccountChanged` clears data and starts another fetch, but existing completion handlers can still publish the previous account's results. Add a refresh generation/account identity check across *all* provider callbacks and Codex token refresh fallback callbacks; verify delayed responses during account switching, logout and cleanup. Simply adding an `isLoading` guard would suppress the new account's refresh and does not solve this.
2. **High — OAuth listener exposure and callback validation.** `OAuthCallbackServer.startListener` does not set a local endpoint/interface restriction, despite its localhost comment. Its request parser accepts query parameters on any path/method and assumes a complete request arrives in a single receive. Bind explicitly to loopback while testing IPv4/IPv6 localhost, accumulate bounded request headers, validate the callback route/method, and reject malformed/duplicate parameters. Preserve the coordinator's state/PKCE checks. Validate with Network.framework tests on macOS.
3. **Medium — loading lifecycle during Codex recovery.** `fetchCodexUsage` calls `noteFetchFinished` immediately after starting asynchronous token recovery, while `retryCodexWithAccessToken` independently changes `isLoading`. A single completion path should cover the full refresh/retry chain so UI loading and refresh animation remain accurate.
4. **Medium — quota reset verification scheduling.** `processCodexSuccess` cancels verification timers when the reset timestamp changes, but only schedules verification when the timestamp stays the same on a later fetch. Schedule checks for a newly observed future reset too, and cover transitions from missing timestamps and already-past timestamps.

## Validation

Executed with Swift 6.0.3 on Linux in Swift 5 language mode:

- `bash Scripts/test-runtime-helpers.sh` — passed (credential formats, preserved structure, idempotence, timer replacement, one-shot reuse, background scheduling and cancellation).
- `bash Scripts/test-usage-reset-detection.sh` — passed, 14 cases.
- `bash Scripts/test-cursor-login-navigation.sh` — passed, 16 cases.
- `bash -n Scripts/test-runtime-helpers.sh` and `git diff --check` — passed.

Local limitations: the Antigravity mapper uses a type-level `nonisolated` declaration unsupported by Swift 6.0.3; ring display checks import CoreGraphics. No source transformations were used to claim those tests passed. Full application build, common-mode UI interactions, Apple framework tests, and Antigravity checks require the macOS CI toolchain. No real account or companion-device testing was performed.
