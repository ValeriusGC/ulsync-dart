# ulsync example

**Created:** 2026-09-08 08:31:05 +0300  
**Updated:** 2026-09-08 13:27:00 +0300  
**Version:** 4  
**Document type:** readme

## What this is

One person, two processes, one local server. The library example is a normal
Flutter app launched twice on macOS — not seven panes in one window. Each plus
button writes one immutable tap record; the on-screen number is the sum of
those records. When you press plus in the phone window, the tablet window
updates through the live feed without a refresh button.

## There is no cloud alice

Everyone who clones this package runs **their own** `ulsync-server`. The JWT
(JSON Web Token) subject `alice` is a local development label you mint with
a shared secret — not a shared cloud account. `alice` on machine A and
`alice` on machine B never meet unless you deliberately point both apps at
the same server URL. If several people paste the same token into one public
demo host, they become one user in that server's database. Production apps
supply tokens from their own identity system; this example does not show a
login screen.

## What you need

- A checkout of [ulsync-server](https://github.com/ValeriusGC/ulsync-server)
  running on your machine (Docker or `go run` — follow that repository's
  README).
- Go installed to mint a local HS256 token (see below).
- This example (`example/` in the `ulsync-dart` repository).
- For the two-window demo: macOS with Xcode tooling so `flutter build macos`
  succeeds.

## Mint a local token

The server does not issue bearer tokens. Sign one locally with the development
HMAC secret from your server `config.yaml` (`dev_hs256_secret: "local-dev-only"`).

Create the helper once:

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
```

Run it from the `ulsync-server` directory (needs that repo's `go.mod`):

```bash
cd /path/to/ulsync-server
export TOKEN=$(go run /tmp/mint_dev_jwt.go)
echo "$TOKEN"
```

Another subject (for example `bob`):

```bash
go run /tmp/mint_dev_jwt.go bob
```

The `User` field in the Connect form must match the token's `sub` claim.

## Clean slate before a two-window run

The library keeps a **separate metadata file per Device ID** (sync cursor,
dirty queue). The example stores them under the macOS app sandbox. Wiping
only the server's `./data/ulsync.db` **without** deleting these files used to
leave the client cursor **ahead** of the server — live opened with
`since=<local cursor>` and **skipped** new envelopes (tablet stayed at `0`
while phone showed `pushed … cursor 18`). The engine **auto-heals** on Connect
(`syncOnce`) and before live:

1. Read local cursor `L` from the metadata file for this Device ID.
2. Probe server feed head `H` with `pull(since: 0)` (server is read-only).
3. When `L > H`, reset the local cursor and replay from the beginning
   (idempotent apply).

After a server-only reset, the two-window plus test works **without** deleting
client metadata below. Deleting those files is still recommended for a
perfectly clean demo. **Disconnect** does not remove metadata; quit the app
(**Cmd+Q**) first.

Other files in `ulsync-server/data/` (`ulsync-load.db`, ad-hoc names) are
**not** the operator store; only `ulsync.db` matters for this demo.

```bash
# Quit all ulsync_example.app windows first (Cmd+Q).

# Server store (stop ./ulsync-server with Ctrl+C before rm)
cd /path/to/ulsync-server
rm -f ./data/ulsync.db ./data/ulsync.db-wal ./data/ulsync.db-shm
./ulsync-server -config config.yaml

# Example metadata (one file per device id used in Connect)
rm -f ~/Library/Containers/dev.ulsync.ulsyncExample/Data/Documents/ulsync_example_phone.db
rm -f ~/Library/Containers/dev.ulsync.ulsyncExample/Data/Documents/ulsync_example_tablet.db
rm -f ~/Library/Containers/dev.ulsync.ulsyncExample/Data/Documents/ulsync_example_watch.db
```

Rebuilding the server binary (`go build`) is **not** required for a clean run —
only the database files above.

## Run two windows on macOS

Build once, then open two separate processes with `open -n`:

```bash
cd /path/to/ulsync-dart/example
flutter pub get
export TOKEN=$(go run /tmp/mint_dev_jwt.go)   # from ulsync-server checkout
flutter build macos --debug \
  --dart-define=ULSYNC_BASE_URL=http://127.0.0.1:8080 \
  --dart-define=ULSYNC_TOKEN="$TOKEN"
open -n /path/to/ulsync-dart/example/build/macos/Build/Products/Debug/ulsync_example.app
open -n /path/to/ulsync-dart/example/build/macos/Build/Products/Debug/ulsync_example.app
```

In **window 1**: User `alice`, Device ID `phone`, paste the same token, Base
URL `http://127.0.0.1:8080`, tap **Connect**.

In **window 2**: User `alice`, Device ID `tablet`, same token and URL, **Connect**.

Press **+** in the phone window. The tablet counter becomes `1` without
pressing refresh. Both windows show `1`. After the first plus, phone Events
should show a **small** cursor (for example `cursor 1`), not a large number
left over from an old metadata file.

Do not run two `flutter run` sessions against the same build output — they
overwrite each other. Use one build and two `open -n` launches.

## Offline switch

The **Offline** switch mutes **this window only**. It is not macOS airplane
mode and not Wi‑Fi off. Do not use airplane mode for this demo.

With phone **Offline**, press **+** twice. Phone shows `2`; tablet stays `0`.
Turn phone **Online** again. Tablet should show `2`, not `1` — both taps were
queued locally and flushed with `syncOnce`.

## A second person

Mint a token with subject `bob`, open a third window (`open -n` again), set
User `bob`, Device ID `watch`, paste the bob token, **Connect**. The counter
stays at `0` while alice's windows show `1` or more. A plus in alice's phone
does not change bob's total.

## Why both clicks arrive

The server stores **records**, it does not add integers. Each plus creates a
new tap with a unique `id` and `delta: 1`. The on-screen total is the sum of
all deltas in the local journal. Last-write-wins on a single `{value: int}`
field would drop one of two simultaneous pluses and look like broken sync.

## Round 1 limitation

Round 1 sends one envelope per `POST /v1/sync/push`. Three pluses are three
HTTP requests. Batching is planned for a later round.

## Android emulator

The default Base URL in code is `http://127.0.0.1:8080` (macOS loopback). Inside
an Android emulator, `127.0.0.1` is the emulator itself, not your host machine.
**You must pass:**

```bash
flutter run --dart-define=ULSYNC_BASE_URL=http://10.0.2.2:8080 \
  --dart-define=ULSYNC_TOKEN="$TOKEN"
```

`10.0.2.2` is the host loopback as seen from the emulator.

Chrome against a local HTTP server is **not** supported: `ulsync-server` does
not send CORS headers. Use macOS, iOS simulator, or the Android emulator.
