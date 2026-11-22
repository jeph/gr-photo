# GR IV Monochrome Custom-slot validation — 2026-11-21

**[Observed]** RICOH GR IV Monochrome, firmware **1.11**, using an independent JavaScript/Python prototype with a React UI, Chromium 155 and a local Linux BlueZ 5.87 companion. Protocol research baseline: `099d8d08c5621ea20fec1e776f57e8c4482026b1`. The GR Photo app was not tested.

## Procedure and results

All three Image Control Custom slots were read and backed up with the camera in shooting mode. Custom 1 Contrast was changed from **+4 to +3** and its name replaced with a **17-byte ASCII test name**. All three slots were read back, the app disconnected, and the owner turned the camera off/on. After reconnecting and reading again, the original settings and name were restored and all three slots read once more.

All three comparisons passed: after writing, after restart, and after restoration. The final saved snapshot also matched the original byte-for-byte across all six name/settings records. Custom 2 and 3 remained unchanged. No re-pairing, host radio reset or automatic write retry was needed during this sequence.

## Evidence

Sanitized projection of the application's transaction report and persistence comparison; times are relative to the write attempt. These are application-level results, not an ATT packet capture.

```text
+001.125s write: all-three-slots-match-intended
+127.800s after owner-confirmed camera restart: all-three-slots-match-intended
+156.645s restore: all-three-slots-match-original
```

The restart was confirmed by the camera owner; the subsequent comparison was performed by the app. Original, expected and restored records were retained privately. This excerpt excludes device identifiers, keys and raw payloads.

## Protocol observations and limits

- Each settings record was **56 bytes**, format **2**, Standard base **0x11**, with **11 parameter pairs**. Unchanged fields and trailing bytes were preserved.
- Each name read as **32 bytes** with NUL padding. The test wrote a short unpadded ASCII name; restoration wrote the full original padded record.
- Settings and name writes were sequential BlueZ `WriteValue` operations with `type: request`.
- Earlier Linux pairing/encrypted-read failures and an unusable bond remain unexplained. This successful trial does not establish connection reliability.
- No successful-transfer ATT capture, other base, full parameter-range coverage, 32-character visible name, non-ASCII name, interrupted write, or second restart after restoration was tested.
- These are **Image Control Custom 1–3**, not U1–U3 mode-dial presets. ISO, white balance, exposure and other settings outside those records were not tested.
