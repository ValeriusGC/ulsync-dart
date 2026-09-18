# ulsync example — self-hosted to-do list

**Created:** 2026-09-17 17:05:37 +0300  
**Updated:** 2026-09-18 13:21:00 +0300  
**Version:** 3  
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
host:port** or **Offline · saved on this device** — never the bearer token.

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
It is not airplane mode. The engine has no pause: cancelling the live
*subscription* does not stop ingest. This sample **closes** the client and
calls `UlsyncClient.open` again with the **same device name** **without**
`live()`, so local `write` / `writeAll` still queue. Going online again is
`syncOnce` (push dirty, then pull) plus `live()`. Do not `syncOnce` on the
way *into* offline — that would pull the remote edits the mute is meant to
hold back.

## Trash and batch

- **Trash** on a row writes part `deleted` (row stays in the map; hidden from
  the main list).
- **Trash** screen → **Restore** writes `deleted: false` without clearing
  **Done**.
- **Move done to trash** sends every done, visible row in one `writeAll` — not
  a loop of `write`.

## Manual acceptance (I1–I7)

Use server `http://127.0.0.1:8080`, device names `phone` and `tablet`, JWT from
`/tmp/mint_dev_jwt.go` with secret `local-dev-only`. Each scenario needs its
own mint, YAML, server process, build, and client DB wipe. Details for operators
live in the step-31 TEMP handoff in the triad HQ repo.

| ID | What you prove |
|----|----------------|
| I1 | New text appears on the other window live |
| I2 | Done checkbox and edited time sync |
| I3 | Trash hides from list, visible in Trash on both |
| I4 | Restore keeps Done |
| I5 | Offline done + online trash → both deleted and done |
| I6 | Move done to trash batch on both windows |
| I7 | Work offline queues edits; both windows converge after online |

Round 2 closes only after a human runs all seven on two windows. Green
`flutter test` alone is not enough.

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
