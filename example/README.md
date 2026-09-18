# ulsync example — self-hosted to-do list

**Created:** 2026-09-17 17:05:37 +0300  
**Updated:** 2026-09-18 17:58:19 +0300  
**Version:** 5  
**Document type:** readme

## What this is

A **product-shaped** sample client, not a developer connect form. You choose
your own `ulsync-server`, prove it with `GET /health`, sign in with an access
key and `GET /v1/whoami`, then keep a to-do list in sync across two macOS
windows. Text, done checkboxes, trash, restore, and **Move done to trash**
(one `writeAll` batch) all ride the round-2 API: named parts (`full`, `done`,
`deleted`) as one **indivisible, complete** kit per to-do, and batched push
that never cuts that kit at the SPEC ceiling of 500.

Each window is a separate process with its own **device name** (`phone`,
`tablet`). The library opens a separate metadata instance per name; the app
does not resolve a filesystem path. The session strip shows **Live ·
host:port**, **Reconnecting · host:port** when the store is down, or
**Offline · saved on this device** only when you chose **Work offline** —
never the bearer token.

## There is no cloud alice

Everyone runs **their own** server on localhost. The JWT subject `alice` is a
label you mint with the dev HMAC secret — not a shared account. Production apps
get keys from their identity system; this sample only **pastes** a key.

## What you need

- [ulsync-server](https://github.com/ValeriusGC/ulsync-server) on your machine
- Go (to mint a local HS256 token)
- macOS with Xcode tooling for `flutter build macos`
- Two windows via `open -n` (not two `flutter run` sessions)

## Mint a local access key

The server does not issue bearer tokens. Sign one with
`dev_hs256_secret: "local-dev-only"` in your server YAML:

```bash
cat >/tmp/mint_dev_jwt.go <<'EOF'
package main

import (
	"fmt"
	"os"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func main() {
	sub := "alice"
	if len(os.Args) > 1 {
		sub = os.Args[1]
	}
	t := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.RegisteredClaims{
		Subject:   sub,
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		IssuedAt:  jwt.NewNumericDate(time.Now()),
	})
	s, err := t.SignedString([]byte("local-dev-only"))
	if err != nil {
		panic(err)
	}
	fmt.Print(s)
}
EOF

cd /path/to/ulsync-server
export TOKEN=$(go run /tmp/mint_dev_jwt.go)
echo "$TOKEN"
```

## Pairing flow (two screens)

1. **Your server** — `Server address`, **Continue** runs `GET …/health` (no
   auth). On success you see the sign-in screen with the host in the subtitle.
2. **Sign in** — `Access key` (bearer), **Device name** (`phone` / `tablet`),
   **Sign in** runs `GET …/v1/whoami` first. On `401` the client does not
   open. On success the menu shows `Signed in as alice` from `user_id`; there
   is no User field on the form.

`--dart-define=ULSYNC_BASE_URL`, `ULSYNC_TOKEN`, and `ULSYNC_SOURCE_ID` may
prefill fields (MDM-style); labels are still **Server address** / **Access
key**, not Base URL / Token / Connect.

After sign-in the client calls `syncOnce` once, then `live()`. Local edits use
`write` / `writeAll` only — the engine drains dirty while the feed runs. Do
not call `syncOnce` after each add, checkbox, or trash action.

## Clean slate before a two-window run

Quit all `ulsync_example.app` windows (**Cmd+Q**), then:

```bash
rm -f ~/Library/Containers/dev.ulsync.ulsyncExample/Data/Library/Application\ Support/dev.ulsync.ulsyncExample/ulsync/phone.db
rm -f ~/Library/Containers/dev.ulsync.ulsyncExample/Data/Library/Application\ Support/dev.ulsync.ulsyncExample/ulsync/tablet.db
```

Reset the server SQLite file you use in your YAML when you need an empty store.

## Build and open two windows

```bash
cd /path/to/ulsync-dart/example
flutter pub get
export TOKEN=$(go run /tmp/mint_dev_jwt.go)   # from ulsync-server checkout
flutter build macos --debug \
  --dart-define=ULSYNC_BASE_URL=http://127.0.0.1:8080 \
  --dart-define=ULSYNC_TOKEN="$TOKEN"
open -n build/macos/Build/Products/Debug/ulsync_example.app
open -n build/macos/Build/Products/Debug/ulsync_example.app
```

In window 1: **Continue** → Device name `phone` → **Sign in**.  
In window 2: same server and key → Device name `tablet` → **Sign in**.

Both should show `Live · 127.0.0.1:8080` (or briefly `Connecting · …`).

## Work offline

The cloud icon in the app bar (**Work offline**) mutes **this window only**.
It is not airplane mode and not a downed store. The engine has no pause:
cancelling the live *subscription* does not stop ingest. This sample
**closes** the client and calls `UlsyncClient.open` again with the **same
device name** **without** `live()`, so local `write` / `writeAll` still queue.
Going online again is `syncOnce` (push dirty, then pull) plus `live()`. Do not
`syncOnce` on the way *into* offline — that would pull the remote edits the
mute is meant to hold back.

While Work offline is on, the strip shows **Offline · saved on this device**.
That text must not appear when the store is merely unreachable.

## Store unreachable

Both windows stay signed in. **Stop the `ulsync-server` process** you started
for this stand — do not use macOS airplane mode. Localhost often stays up in
airplane mode, so that is not this scenario.

With the feed still running and Work offline **off**, edits stay on this
device and the strip shows **Reconnecting · host:port**, not Offline. Start the
same server binary on the **same port** with the **same store database**; both
windows converge without Cmd+Q, without the cloud, and without a Retry
button. The engine catch-up you proved in step 34 does the work.

## Trash and batch

- **Trash** on a row writes part `deleted` (row stays in the map; hidden from
  the main list).
- **Trash** screen → **Restore** writes `deleted: false` without clearing
  **Done**.
- **Move done to trash** sends every done, visible row in one `writeAll` — not
  a loop of `write`.

## Manual acceptance (K1–K6)

Round 3 on **this example** means the hands checks in the step-35 TEMP
handoff. Use server `http://127.0.0.1:8080`, device names `phone` and
`tablet`, JWT from `/tmp/mint_dev_jwt.go` with secret `local-dev-only`. Stop
and restart the **server process** for outage — not airplane mode.

### What the list UI can do

Each row shows a **read-only** title, a **Done** checkbox, and **Trash**.
**New to-do** + **Add** always creates a **new** id. There is **no control to
rename** an existing row. You cannot change `Eggs` to `Free-range eggs` on the
same line after it was added.

That is enough for K1, K2, K5 (add while muted), and K6. It is **not** enough
to drive K3 or K4 on two macOS windows as written in the triad plan.

| Code | Runnable on two example windows? | Why |
|------|----------------------------------|-----|
| K1 | Yes | Add Milk / Bread (new rows) |
| K2 | Yes | Done + **Move done to trash** |
| K3 | **No** | Needs offline **title** edit on the same id; UI has no rename |
| K4 | **No** | Needs two offline **title** edits to one id; UI has no rename |
| K5 | Yes | Mute + **add** a row (or toggle done / trash — not rename) |
| K6 | Yes | Read the strip while the server is stopped |

**K3 and K4 on example:** mark **N/A (no title edit UI)** in your handoff
notes. The round-3 contract for those cases is proven in
`test/engine/offline_queue_test.dart` on step 34 (see TEMP **Hands** for test
names). Adding inline title edit to the example is **out of scope** for step
35.

| Code | Where (when runnable) | Success | Failure |
|------|------------------------|---------|---------|
| K1 | Stop server. Phone: Milk. Tablet: Bread. Start server | Both lists show Milk and Bread without Cmd+Q and without the cloud | Need a window restart, the cloud, or a button |
| K2 | Server down. Phone: mark several done, **Move done to trash**. Start server | On both windows done items are in trash completely | Half the rows or only one screen |
| K3 | *Not on example UI* — engine tests instead | — | — |
| K4 | *Not on example UI* — engine tests instead | — | — |
| K5 | Phone: cloud **Work offline**, add a row, **Online** | After Online both converge; phone list is not wiped | Journal lost, mute pushed, or restart needed |
| K6 | Server down, cloud **not** touched | Strip `Reconnecting · …`, not `Offline · saved on this device`. After start → `Live` | Outage looks like mute |

K4 (last-write-wins on one field) is the honest product price when two
devices edit the same cell offline, not a bug — but you only prove it via
engine tests until the example grows a rename control.

After K1–K6, if the stand is still live: add one item on phone — it should
appear on tablet without stopping the server (live exchange regression).

## Regression (I1–I7, J1–J4)

Round 2/2a scenarios still hold. I1–I4, I6, J1–J2, J4 — as before. I5, I7,
and J3 match K5 (Work offline mute). Green `flutter test` alone is not K1–K6.

| ID | What you prove |
|----|----------------|
| I1 | New text appears on the other window live |
| I2 | Done checkbox and edited time sync |
| I3 | Trash hides from list, visible in Trash on both |
| I4 | Restore keeps Done |
| I5 | Offline done + online trash → both deleted and done (= K5) |
| I6 | Move done to trash batch on both windows |
| I7 | Work offline queues edits; both windows converge after online (= K5) |

## Android emulator

Pass the host loopback for the emulator:

```bash
flutter run --dart-define=ULSYNC_BASE_URL=http://10.0.2.2:8080 \
  --dart-define=ULSYNC_TOKEN="$TOKEN"
```

Round-2 acceptance is macOS two-window; the emulator path is best-effort.

## Chrome / web

Local HTTP without CORS is not supported for sync. Use macOS or a mobile
simulator for server-backed runs.
