# Claude Usage

A macOS menu bar app showing your current Claude Code usage, computed locally
from the transcript logs in `~/.claude/projects` — no credentials, no network.

**Menu bar:** `CC 1.3M · $10.30` — tokens and estimated cost of the current
5-hour billing block (`CC idle` when there is no active block).

**Dropdown menu:**
- Current 5h block: token breakdown (input / output / cache write / cache read),
  estimated cost, burn rate, and time until the block resets
- Today's totals
- Refresh / Quit

Data refreshes automatically every 60 seconds.

## Build & run

```bash
./build.sh
open "Claude Usage.app"
```

Requires Xcode Command Line Tools (`swiftc`).

## Launch at login

System Settings → General → Login Items → add `Claude Usage.app`.

## Notes

- The 5-hour block boundary uses the same algorithm as ccusage: the block
  starts at the first message's timestamp floored to the hour and lasts 5 hours.
- Cost is an estimate based on list API pricing (Opus/Fable, Sonnet, Haiku
  tiers); subscription plans don't bill per token, so treat it as a usage
  gauge, not a bill.
