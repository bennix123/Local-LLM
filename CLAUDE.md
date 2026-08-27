# Penny — instructions for AI coding sessions

These rules apply to EVERY change in this repository, by any session.

## 1. Feature parity: Mac AND iPhone, always

Every feature ships in BOTH the macOS app (`PennyMac/PennyApp`) and the iOS app
(`PennyMac/PennyiOS`) in the same change. Shared logic goes in `PennyMac/PennyCore`
(both apps import it); UI is wired per platform.

**Single exception:** LLM model downloads (MLX weights, ModelStore download UI) are
macOS-only — iOS is Apple-Intelligence-only by product decision (`allowMLXFallback: false`).

iOS verification on this machine: the iOS simulator runtime is not installed, so at
minimum cross-compile PennyCore for iOS (`swift build --triple arm64-apple-ios17.0
--sdk "$(xcrun --sdk iphoneos --show-sdk-path)"`) and typecheck the PennyiOS sources.
Say clearly in the commit message what level of iOS verification was done.

## 2. Prompt a manual check after EVERY change

After making any change — however small — rebuild the app, relaunch it, and explicitly
prompt Rahul to verify it manually, listing exactly what to check and what the expected
behavior is. Never mark work finished on green tests alone; tests plus Rahul's manual
confirmation is the definition of done.

## Working agreements (context for any session)

- One heavy job at a time on this machine (builds/tests/model loads) — it has crashed
  under stacked load before.
- The regex router (`FinanceQuery.swift`) is FROZEN for new intent patterns — new
  understanding capabilities go to the PennyFinance engine. Bug fixes to existing
  handlers are fine; check with Rahul before adding any new handler.
- Every manually-found bug gets a regression test pinning the exact phrasing, in the
  same commit as its fix.
- Coordinate before working: if another AI session is active on this checkout, do not
  run concurrently — commits have collided here before.
