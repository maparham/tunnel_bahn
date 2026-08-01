# Speed Test UI Redesign

Date: 2026-08-01
Status: approved approach (Option B: full redesign with live charts)

## Goal

Improve the Speed Test view's visual hierarchy, make the running state show live progress in place (no layout collapse into a spinner), and make the Tunnel vs Direct comparison first-class.

## Scope

- `TunnelBahn/Views/SpeedTestView.swift` — full visual rework.
- `TunnelBahn/Services/SpeedTestService.swift` — small addition: publish live throughput samples during download/upload phases.
- No persistence, no new settings, no schema/compat work (no-legacy-code policy).

## Service change

- `SpeedTestEngine` emits a new `latencySummary` event after the latency phase (NDJSON `latency_summary` line from the helper), carrying the settled median and jitter.
- `liveReadout` is replaced by `SpeedTestService.liveRun: LiveRunData?`, reconstructed host-side from engine/helper events: the latency ticking text, the settled latency median and jitter, and per transfer phase the whole-window average Mbps (the hero number, converging to the final figure) plus the instantaneous sample series (the live chart). Number and chart come from the same tick, so they always agree.

## View design

### Card layout (both Tunnel and Direct cards, shared structure)

1. **Header** — unchanged idiom: title, profile name badge, `questionmark.circle` with `instantTooltip`, Run/Cancel button on the right.
2. **Download block**
   - Caption row: `arrow.down` icon + "Download" label, in the download accent color (blue).
   - Hero value: large (`.title`-scale) monospaced-digit number, `%.1f`, with a smaller secondary "Mbps" unit label beside it.
   - Sparkline below: line + gradient area fill in the same blue; subtle dashed horizontal rule at the average Mbps; fixed height (~56pt); axes hidden.
3. **Upload block** — same structure in green (`arrow.up`).
4. **Footer row** — Latency and Jitter as two compact label/value pairs side by side, monospaced digits, plus the existing "Tested \<relative time\>" caption.

### Running state (same layout, live data)

- The card does NOT collapse. All blocks stay in place.
- A small phase indicator sits under the header: three steps — Latency, Download, Upload — with the active step highlighted and a small `ProgressView` next to it.
- Latency phase: latency footer value ticks with `liveRun.latencyReadout`; download/upload blocks show dimmed placeholders ("--").
- Download phase: download hero number ticks with the live rate and the sparkline grows in place from `liveSamples`; upload block dimmed.
- Upload phase: download block shows its finished numbers; upload hero + sparkline live.
- Blocks not yet measured render dimmed placeholder values so the card height stays stable.

### Empty state

- Keep the existing centered hint text, but height-matched to the filled card so the two columns align.

### Comparison strip ("Tunnel vs Direct")

- Shown only when both results exist (unchanged condition).
- A horizontal strip below the cards with four labeled deltas: Download, Upload, Latency, Jitter.
- Each delta: label caption + signed value (percent for throughput, ms for latency/jitter), colored green when the tunnel is better and red when worse. Better = higher throughput, lower latency/jitter. Zero/negligible delta renders secondary gray.
- Monospaced digits; no chart overlay.

## Error handling

- Unchanged: `errorMessage` / `statusNote` render above the cards as today.
- Cancel keeps the previous finished result for that path visible (existing behavior) and clears `liveSamples`.

## Testing

- `SpeedTestMath` logic is already unit-tested; no math changes.
- Service change verified by existing build + a manual run; view verified visually (run app, run tunnel and direct tests, screenshot).
- Delta color logic (better/worse mapping) extracted into a small pure helper so it can be unit-tested alongside `SpeedTestMathTests` if nontrivial.

## Out of scope

- Run history / persistence.
- Overlaid tunnel-vs-direct curves.
- Any change to measurement methodology.
