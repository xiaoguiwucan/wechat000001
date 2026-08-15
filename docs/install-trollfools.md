# Installing WeChatIngest into WeChat with TrollFools

This guide loads the WeChatIngest dylib into WeChat on a TrollStore-capable iPhone
so the tweak can forward new messages to the ingest gateway. It uses TrollFools
to inject without a jailbreak: the phone only needs TrollStore installed. No
jailbreak steps are involved.

Prerequirements:

- An iPhone running iOS 14 or later with TrollStore installed (TrollFools itself
  is a TrollStore app, loaded from IPA via TrollStore).
- A Mac with Xcode installed (for the iphoneos SDK used by the build script).
- A gateway host reachable from the phone over SSH (default SSH port 22) with the
  WeChatIngest service running and listening on port 18790.

## 1. Build the dylib

From the project root:

```bash
bash scripts/build-dylib.sh
```

The script compiles `tweak/Tweak.m` (or `Tweak.x`) plus `tweak/Settings.m` and
`tweak/hooks/MessageHooks.m` with `-fobjc-arc -framework Foundation` into:

```
build/WeChatIngest.dylib
```

When the iphoneos SDK is present, the output is an arm64 iOS dylib that
TrollFools can inject into WeChat. If only the macOS SDK is present the script
prints a warning and the output is a host-arch build for syntax validation only:
it is NOT device-injectable, so rebuild on a machine with the iphoneos SDK before
copying to the phone.

## 2. Copy the dylib to the phone

Use AirDrop, iCloud Drive, a file app, or any transfer method that drops the file
into a directory the phone can reach (the Files app is fine). If you prefer a
wireless transfer from the Mac:

```bash
scp build/WeChatIngest.dylib HOST:/tmp/
```

`HOST` is the placeholder for the address the gateway listens on. If the phone
stores the file anywhere else, note the path for the next step: TrollFools needs
to be pointed at the actual file.

## 3. Inject into WeChat with TrollFools

1. Open TrollFools on the phone.
2. Tap the plus or "Import" button and select `WeChatIngest.dylib`.
3. In the app list, pick **WeChat** (bundle id `com.tencent.xin`).
4. Tap "Inject" (the dylib is listed with an enabled toggle after import).

TrollFools registers the dylib with the WeChat container. Do not remove or toggle
off the entry or WeChat will stop loading the tweak.

## 4. Grant the needed permissions

TrollStore-based injection runs under WeChat's own sandbox, so grant what WeChat
asks for on first launch. When WeChat next starts, it may prompt for local
network permission: allow it, because the tweak opens outbound TCP connections to
the gateway over the local network (or cellular data, if the gateway is reachable
that way). If a notification or background-refresh prompt appears, allow it as
well so message capture keeps running.

## 5. Restart WeChat

Force-quit WeChat completely (swipe it away from the app switcher), then reopen
it. A dylib injected via TrollFools is only loaded at process start, so the
restart is what actually loads `WeChatIngest.dylib`.

## 6. Fill in SSH and token settings

The tweak reads its settings from WeChat's standard user defaults. The settings
screen inside WeChat lets you enter them; you can also set them programmatically
through the same keys. Required values:

| Setting | Default | Meaning |
|---|---|---|
| SSH host | (empty) | Address the phone uses to reach the gateway: use `HOST` |
| SSH port | 22 | Port the gateway's SSH listener accepts connections on |
| SSH user | (empty) | Username for the SSH connection |
| SSH password | (empty) | Password for the SSH connection |
| Gateway token | (empty) | Shared secret the gateway validates on each request: use `TOKEN` |
| Gateway port | 18790 | Port the WeChatIngest gateway listens on (default `18790`) |

The gateway port defaults to `18790` and only needs changing if the deployed
service was started on a different port.

Fill in the SSH host (`HOST`), the gateway token (`TOKEN`), and verify the
gateway port (`18790`). The settings screen includes a connectivity test that
probes SSH reachability first and then the gateway port; run it and confirm both
report reachable.

## 7. Verify ingest

Send a message from another account into the WeChat chat that is being watched.
The tweak's captured event should appear in the gateway log (the `wechat-ingest`
systemd unit, or the foreground log if the gateway runs manually):

```bash
journalctl -u wechat-ingest -f
```

A captured message proves the full chain: dylib loaded, permission granted, and
SSH + token + gateway port all correct. If nothing arrives, rerun the settings
connectivity test, confirm the restart actually happened after injection, and
confirm `build/WeChatIngest.dylib` was built against the iphoneos SDK (step 1).

## Troubleshooting

- **WeChat ignores the dylib**: confirm the file is the iphoneos-arm64 build (not
  the host fallback), and that the TrollFools toggle for `WeChatIngest.dylib` is
  on before restarting WeChat.
- **Connectivity test fails on SSH**: check `HOST` and the SSH credentials; the
  gateway must accept SSH from the phone.
- **Connectivity test fails on the gateway port**: confirm the service is
  listening on `18790` and that nothing (a firewall on the gateway, or the
  carrier) blocks it.
- **Messages captured but not forwarded**: recheck `TOKEN`; a mismatch makes the
  gateway reject the events.
