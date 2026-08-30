# Notice

whoopmaxx is an independent project. It is not affiliated with, sponsored by, or endorsed by
WHOOP, Inc., and contains no WHOOP source code, binaries, firmware, or copyrighted assets.

## Licensing, in short

The repository as a whole is **PolyForm Noncommercial 1.0.0** — see `LICENSE`. That is not a
choice; it is inherited. The parts below say which code carries it and which does not.

| Directory | Origin | Terms |
|---|---|---|
| `Packages/StrapProtocol` | written here, from OpenStrap/protocol | MIT |
| `Packages/StrapStore` | written here, from OpenStrap/protocol | MIT |
| `Packages/StrapAnalytics` | written here, from OpenStrap/analytics | MIT |
| `Core/BLE`, `Core/Collect` | **derived from ParthJadhav/noop** | PolyForm Noncommercial 1.0.0 |
| everything else | written here | PolyForm NC as part of the combined work |

## The derived layer

**`Core/BLE` and `Core/Collect`** are derived from
[ParthJadhav/noop](https://github.com/ParthJadhav/noop), PolyForm Noncommercial License 1.0.0,
Copyright 2026 NoopApp. The Bluetooth connection, session and offload machinery there is
substantially that project's work, carried over and modified.

This is stated plainly because an earlier revision of this project removed the attribution, and
removing it was wrong. PolyForm Noncommercial permits redistribution and modification, but only
for noncommercial purposes and only with the licence and its `Required Notice:` lines retained.
Both are retained in `LICENSE`.

A replacement was attempted and did not succeed. The three derived packages were replaced outright
and deleted, and the code that took their place is the MIT-licensed work described below. The
Bluetooth layer was not replaced. A rewrite of `Core/BLE` and `Core/Collect` was attempted and
measured afterwards at 92-99% identical to the original, so it would have remained a derivative
either way; `BLEManager.swift` is also 3,589 lines with no test coverage, because a simulator has no
Bluetooth radio to test against. Attributing the layer was the honest answer, and safer than
shipping an untested rewrite to a device people wear.

## Independently written packages

**`Packages/StrapProtocol`** is derived from
[OpenStrap/protocol](https://github.com/OpenStrap/protocol), MIT License, Copyright (c) 2026
OpenStrap. The Bluetooth protocol support in that project was independently developed by observing
the band's own Bluetooth communications.

```
Permission is hereby granted, free of charge, to any person obtaining a copy of this software
and associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

**`Packages/StrapStore`** is derived from the same OpenStrap project, under the same permission
notice reproduced above.

**`Packages/StrapAnalytics`** is derived from
[OpenStrap/analytics](https://github.com/OpenStrap/analytics), MIT License, Copyright (c) 2026
OpenStrap, under the same permission notice reproduced above.

These three share no code with the derived layer above, which is why they carry their own
`Packages/LICENSE` and can be used on their own under MIT.

## Dependencies

**GRDB.swift** — MIT, Copyright (c) 2015-2026 Gwendal Roué.
**ZIPFoundation** — MIT, Copyright (c) 2017-2026 Thomas Zoechling.
