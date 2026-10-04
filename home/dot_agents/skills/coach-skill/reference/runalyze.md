# Runalyze CSV Import Reference

How to parse a Runalyze activity export (`runalyze-activities*.csv`) into an athlete assessment. Runalyze is a self-hosted/hosted training log popular with runners; its export is a **very wide CSV** (170+ columns), but only a handful matter for coaching.

Read this file when the athlete chooses "Import Runalyze CSV" (Option C in SKILL.md).

---

## Getting the export

The athlete gets this file from Runalyze via **Settings → Account → Export account data**, or by exporting the activity table. The file is named like `runalyze-activities.csv` (or `runalyze-activities(2).csv` for repeat exports).

Confirm it loads before parsing:

```bash
wc -l /path/to/runalyze-activities.csv && head -1 /path/to/runalyze-activities.csv
```

Parse with **Python** — the file is too wide for `head`/`awk`/`cut` to be useful, and `csv.DictReader` handles the quoting.

---

## Column reference (the ones that matter)

| Column | Meaning | Unit / format | Coaching use |
| ------ | ------- | ------------- | ------------ |
| `id` | Activity ID | int | Dedup / reference |
| `time` | Activity **start** | **Unix timestamp, seconds** | Date via `datetime.utcfromtimestamp(int(time))` |
| `s` | **Moving time** | seconds | Duration, pace (`s ÷ distance`) |
| `elapsedTime` | Elapsed time incl. stops | seconds | Do **not** use for pace |
| `distance` | Distance | **kilometers** | Volume, long-run detection |
| `sportid` | Sport | **account-specific numeric ID** | Group & infer sport — never hardcode |
| `typeid` | Workout type | **account-specific ID** (often blank) | easy / long / interval / race |
| `pulseAvg` | Average HR | bpm | Zone estimation, decoupling |
| `pulseMax` | Max HR | bpm | Max-HR estimate |
| `trimp` | Training load (TRIMP) | points | Weekly load, CTL proxy |
| `vo2max` | **Effective VO2max** (see below) | ml/kg/min | Fitness trend, race prediction |
| `vo2maxByTime` / `vo2maxWithElevation` | Variants of the estimate | ml/kg/min | Cross-check |
| `power` / `xPower` | Running (or cycling) power | watts | Intensity if HR missing |
| `cadence` | Cadence | spm (running) | Form check |
| `gap` | Grade-adjusted pace | min/km | Hilly-route context only |
| `xPace` | Runalyze "effective" pace | min/km | Unreliable when elapsed ≫ moving — avoid |
| `kcal` | Calories | kcal | Fueling context |
| `title` | Activity title | text | Often flags races ("... 10k", "Marathon", "Полумарафон") |
| `elevationUp` / `elevationDown` | Elevation | meters | Hilly context |
| `race_officialDistance` / `race_officialTime` / `race_name` / `race_placeTotal` | Official race result fields | — | Ground-truth benchmarks when present |
| `notes`, `rpe`, `subjectiveFeeling` | Athlete notes / RPE | — | Context, injuries, how sessions felt |

### Compute pace yourself

```python
pace_min_per_km = (int(row["s"]) / 60) / float(row["distance"])   # min/km
```

`xPace`/`gap` distort badly when a run has long stops (elapsed ≫ moving), so derive pace from moving time and distance instead.

---

## Effective VO2max (Runalyze's algorithm)

Runalyze does **not** report raw lab VO2max. It reports **Effective VO2max**, which bundles VO2max *and* running efficiency into a single number usable as a direct race predictor. Understand this before using the `vo2max` column:

- VO2max is the maximal oxygen uptake, highly correlated with maximal running performance. But two athletes with equal VO2max need not perform equally — their **running efficiency** differs. The useful quantity for prediction is the **combination** of VO2max and efficiency: the *Effective VO2max*.
- Runalyze estimates Effective VO2max for **every run that has heart-rate data**, from the relationship between heart rate and pace (optionally accounting for elevation). The **average** of these per-run values is taken as the athlete's current shape.
- Because everyone's heart rate behaves differently, Runalyze applies an **individual correction factor**, computed automatically from the athlete's **best race and its heart rate** (or set manually by the athlete).

**Coaching implications:**

- Treat `vo2max` as a **performance/shape predictor**, not a physiological lab value. It's most meaningful as a **trend** (rising = improving shape) and for **race-time prediction**.
- Its accuracy depends on the correction factor being calibrated to a genuine hard race. If the athlete has no recent all-out race, flag that the value may be off and lean more on actual race times and threshold efforts.
- Runs **without HR** have no Effective VO2max — don't treat those blanks as fitness gaps.
- Corroborate with real benchmarks (recent race rows / `title` matches) before using it to set marathon pace.

---

## sportid / typeid are account-specific

**Critical:** `sportid` and `typeid` are numeric IDs unique to each Runalyze account. The IDs in one athlete's export mean nothing in another's. **Never hardcode them.** Instead, infer and then confirm:

```python
import csv, datetime
from collections import defaultdict, Counter

with open(PATH) as f:
    rows = list(csv.DictReader(f))

bysport = defaultdict(list)
for r in rows:
    bysport[r["sportid"]].append(r)

for sid, rs in sorted(bysport.items(), key=lambda x: -len(x[1])):
    dists = sorted(float(r["distance"]) for r in rs if r["distance"] and r["distance"] != "0")
    durs  = sorted(int(r["s"]) for r in rs if r["s"])
    med_d = dists[len(dists)//2] if dists else 0
    med_m = (durs[len(durs)//2] / 60) if durs else 0
    has_pw = sum(1 for r in rs if r["power"] and r["power"] != "0") / len(rs) * 100
    titles = [t for t, _ in Counter(r["title"] for r in rs if r["title"]).most_common(3)]
    print(f"{sid:12s} n={len(rs):4d} medDist={med_d:5.1f}km medDur={med_m:5.1f}min pow%={has_pw:3.0f} {titles}")
```

**Inference heuristics:**

- **Running** — the group with many mid-distance efforts (3–20 km typical), running power and/or cadence usually present, high HR coverage.
- **Cycling** — higher distances/speeds, power present, lower cadence numbers.
- **Walking / hiking** — low speed, long duration, no power.
- **Other (climbing, snowboard, ski, kayak, skate)** — often `distance` = 0 or GPS-only, no running power; identify from `title`.

Then **confirm the mapping with the athlete** via AskUserQuestion (present your inference, let them correct). Do the same for `typeid` within the running group — sample titles and median distance per `typeid` to guess easy / long run / interval / race, then confirm.

---

## Building the assessment

Work from the running rows (the confirmed run `sportid`). Use a recent block (last **8–12 weeks**) for *current form* and the full history for *foundation*.

```python
now = max(int(r["time"]) for r in rows)
recent = [r for r in runs if int(r["time"]) > now - 84*86400]   # last 12 weeks
weeks = 12
weekly_km = sum(float(r["distance"]) for r in recent if r["distance"]) / weeks
weekly_h  = sum(int(r["s"]) for r in recent if r["s"]) / 3600 / weeks
longest   = max(float(r["distance"]) for r in recent if r["distance"])
```

Then populate the standard assessment object (same schema as Strava/manual):

- **foundation.raceHistory** — race rows (via race `typeid`, `race_*` fields, or `title` matches like "10k", "Marathon", "Полумарафон"), with dates and times.
- **foundation.peakTrainingLoad** — highest sustained weekly hours across history.
- **foundation.foundationLevel / yearsInSport** — span from earliest to latest activity, total volume.
- **currentForm.weeklyVolume** — km/week and h/week from the recent block (running; note other sports separately).
- **currentForm.longestSessions.run** — longest recent run (and all-time for context).
- **currentForm.consistency** — number of recent weeks with ≥1 run.
- **strengths / limiters** — e.g. strong long-run volume vs. lack of speed work (few interval `typeid` rows).
- **constraints** — pull from `notes`/`rpe` if the athlete logs injuries or fatigue.

### Benchmarks & zones

- **Threshold pace / race predictions** — recent race rows give real 5k/10k/HM times; derive threshold pace and a predicted marathon time. Cross-check with the latest **Effective VO2max**.
- **LTHR / HR zones** — estimate from HR in hard/threshold efforts and `pulseMax`; **state that zones are estimates and should be field-validated** (see `zones.md`).
- **Cross-training load** — non-running sports (cycling, rock climbing, hiking, etc.) add real fatigue. Sum their recent hours and factor them into recovery/volume decisions even though they aren't the target sport. A big weekly block of, say, climbing hours means less headroom for run volume.

Because this is real logged data, you can be as confident as with Strava — skip the extra conservatism of manual entry, but still validate zones and the sport/type mapping with the athlete before finalizing the plan.
