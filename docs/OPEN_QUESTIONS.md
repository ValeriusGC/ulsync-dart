# Open questions

**Created:** 2026-09-01 14:25:15 +0500  
**Updated:** 2026-09-04 10:29:51 +0500  
**Version:** 2  
**Document type:** open questions

Findings that do not belong in the current change are recorded here; an empty
file at the start is expected.

## Live feed hides reconnect from the engine

**What:** The live stream hides disconnect and reconnect. The step-14 engine
wants a `SyncEvent` for "connection lost / restored", and the three
`LiveMessage` kinds cannot express that.

**Where:** `SyncTransport.live`, step 13 / future step 14.

**Why not here:** The step-13 prompt fixed three message kinds. A fourth kind
or a callback is a step-14 decision, not a hidden transport extension.
