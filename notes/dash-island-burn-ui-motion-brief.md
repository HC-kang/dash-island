# Dash Island burn UI — motion brief
Refs: Dynamic Island energy morph · AW Activity rings · CC battery/thermal · analog instrument needle.  
Context: dual rings + red burn needle; `burnRatio` 0 rest → 1 cruise → 2 redline; `needleUnit = ratio/2`.

## 1. Five premium motion principles
1. **Morph energy, don't flip modes** — continuous lerp of opacity/amp/period across tiers (Island morph, not discrete skins).
2. **Amplitude before hue** — escalate with glow alpha + micro-jitter only; needle stays fixed instrument red (CC thermal calm).
3. **Critically damped settle** — needle snaps with ~1 soft overshoot ≤2°, never rubber-band bounce (AW ring ease-out).
4. **Alive idle, near-zero** — rest has sub-threshold breathing so chrome doesn't freeze-dead; below conscious notice.
5. **Secondary discipline** — % + rings own first glance; burn motion stays hairline until hot, then presence without panic.

## 2. Burn-ratio tier map (Canvas params)
| Tier | burnRatio | glow α | needle jitter amp | period (s) | note |
|------|-----------|--------|-------------------|------------|------|
| **rest** | 0.00–0.35 | 0.00–0.08 | 0.15–0.35° | 2.8–3.6 | barely breathing hub/glow |
| **cruise** | 0.35–1.15 | 0.10–0.22 | 0.35–0.70° | 1.8–2.4 | steady analog live |
| **hot** | 1.15–1.70 | 0.24–0.40 | 0.70–1.20° | 1.1–1.6 | urgency via rate, not color |
| **redline** | 1.70–2.00+ | 0.42–0.58 | 1.20–1.80° | 0.75–1.05 | soft-cap α≤0.58; no flash |

Interp: smoothstep within tier; cross-tier 180–280ms ease-in-out. Cap ratio>2 at redline params (no runaway).  
Ring fill: only on value change (strongEaseOut); never continuous ring pulse. Needle tip glow uses α; stroke α ~0.75–0.95 flat.

## 3. Hard DO-NOT
- Rainbow / multi-hue progress, heatmaps, traffic-light needle recolor  
- Bounce, elastic spring, cartoon squash, progress “pop”  
- Strobe, blink, heartbeat double-thump, full-opacity flash  
- Emoji, particles, fire/smoke, neon bloom, scanlines  
- Continuous ring spin, chasing dashes, confetti at redline  
- Syncing all widgets to one phase (phase-offset per widget ≥0.2s)
