# Claude Usage

A macOS menu bar app showing your current Claude Code usage: plan limit
percentages from your Claude account (optional sign-in), plus token/cost stats
computed locally from the transcript logs in `~/.claude/projects`.

**Menu bar:** a colored progress ring (worst limit) plus each limit's
percentage — `◔ 5h 42%  W 13%  F 27%` — tinted orange at 70% and red at 90%.
Without sign-in it falls back to `CC 1.3M · $10.30` for the current 5-hour
block (`CC idle` when there is no active block).

**Dropdown menu:**
- Plan usage limits as circular gauges (5-hour, weekly, per-model) with reset
  times, colored green / orange / red
- Insights — only shown when there is something to act on:
  - usage spike: last 15 minutes vs today's average pace, with the project
    driving it
  - oversized session context (>120k tokens): suggests `/clear` or `/compact`,
    since the whole context is re-sent (and re-billed) every message
  - on pace to hit a limit before it resets, projected from sampled history
  - model mix: when one heavy model dominates today's cost
- Active sessions: project · model · context size · cost today
- Current 5h block: token breakdown (input / output / cache write / cache read),
  estimated cost, burn rate, time until the block resets, per-model breakdown
- Today's totals, hourly spend mini-chart, per-model breakdown
- Last 7 days totals
- "Menu bar shows" — choose tokens, cost, or both in the fallback title
- Launch at login toggle, sign in/out, Refresh / Quit

Data refreshes automatically every 60 seconds. Files are parsed once and
cached by (mtime, size), so the first refresh scans a week of logs and later
refreshes only re-read files that changed.

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
