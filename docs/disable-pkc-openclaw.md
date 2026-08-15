# Disable PKC OpenClaw (handoff checklist)

The new ingest plugin owns the OpenClaw channel. PKC must NOT also run OpenClaw
at the same time. This page walks you through turning PKC's OpenClaw off while
keeping PKC itself for any other toys you still want.

## The exact switch

- Switch: `pkcOpenClawEnable` (BOOL)
- Default when off: `NO`
- Where it lives: PKC's own settings suite (`NSUserDefaults`). PKC exposes the
  toggle inside WeChat's own Settings screen via its `addOpenClawSection` row
  set, so you do not need to touch plists by hand.

## What to do

1. Open WeChat on the phone where PKC is injected.
2. Go to `Me` → `Settings`.
3. Find the PKC section (the one with the OpenClaw rows, built by
   `addOpenClawSection`).
4. Flip the OpenClaw enable switch to **OFF**. This writes
   `pkcOpenClawEnable = NO`, which stops PKC from connecting to the gateway,
   listening on its WebSocket port (`pkcOpenClawWSPort`), or replying to
   group/DM events.
5. Leave every other PKC setting and toy as-is. You do not need to uninstall
   PKC or clear its SSH / gateway values; only the enable switch matters.
6. (Optional but recommended) Verify in WeChat that PKC's OpenClaw section no
   longer shows a connected/active state, then restart WeChat so no stale
   socket survives.

## Keep PKC, but only as a non-OpenClaw toy

- The disable step above is scoped to `pkcOpenClawEnable` only.
- PKC's other features (anything not under the OpenClaw section) are untouched
  and keep working.
- Do NOT hook or patch PKC's symbols at runtime. The new plugin coexists by
  relying on the switch, not by tampering with PKC's code.

## Why: the dual-client failure mode

If both PKC and the new ingest plugin have OpenClaw enabled at the same time,
you get **two clients**:

- **Duplicate group replies.** Both clients see the same group `@` message.
  Both decide it is a command. Both send a reply back into the group. The group
  gets the same answer twice (and both copies show your own echo back to you).
- **Command double-processing.** One command can trigger two gateway
  connections, two event writes, and two reply pipes. Side effects (posting,
  file writes, external actions) happen twice.
- **Port conflict.** PKC binds its WebSocket port (`pkcOpenClawWSPort`) and the
  new plugin binds `18790`. If they end up on the same port, one client fails
  to bind and silently drops events; if they use different ports, both stay
  alive and both reply.

The fix is always the same: leave exactly one OpenClaw client enabled. This
plugin is that client, so PKC's switch must be OFF.

## One-line summary

`Me → Settings → PKC section → OpenClaw enable = OFF` (`pkcOpenClawEnable = NO`),
keep PKC for other toys, never run two OpenClaw clients, or every group
command is answered twice.
