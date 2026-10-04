---
name: model-convert
description: Convert CAD and mesh models (STEP, IGES, IFC, STL, OBJ, PLY, 3MF, ...) into SketchUp .skp components, and build part libraries, catalogue sheets, and bills of materials from them. Use when asked to convert 3D models to SketchUp, batch-process a vendor catalogue of parts, lay parts out as a reference sheet, or count components in a .skp.
---

# Converting models into SketchUp

## The one hard constraint

**Nothing but SketchUp can write `.skp`.** The format is proprietary and has no
open writer. So every path here ends by driving the real application: the
harness launches SketchUp with a job file, a plugin does the work, and the app
quits. Consequences you cannot design around:

- **SketchUp must be closed before any harness command.** They refuse to run
  otherwise, rather than interfere with a live session. Ask the user to close
  it; never kill an app they are working in.
- **A run takes over the GUI** for its duration.
- **Always clear a pending job** (`rm "$STATE/job.json"`) if you abort, or it
  fires against whatever model the user opens next.

The state directory is `~/.local/share/model-convert` (override with
`MODELCONV_STATE`). The plugin is installed automatically to the user's
SketchUp Plugins folder as `model_convert_batch.rb`; it is inert unless a job
file exists.

## Formats

Everything a stock FreeCAD reads, with no extra dependencies:

| Kind | Extensions | Notes |
|---|---|---|
| B-rep | `step stp iges igs brep brp` | tessellated; deflection is yours to choose |
| Mesh | `stl obj ply amf 3mf off nas bms` | already triangulated, used as-is |
| BIM | `ifc` | via the ifcopenshell bundled with FreeCAD |

IGES loads through `Part.insert` rather than `Import.insert`, and carries
surfaces rather than solids — the reader falls back automatically.

Requires **FreeCAD** (`brew install --cask freecad`) and **SketchUp**.

## Commands

All live in `harness/` next to this file.

```bash
convert  [-o DIR] [-a DEG] [-d MM] [--smooth DEG] [--no-guides] FILE|DIR...
sheet    [--scheme NAME] [--no-pipes] [-g MM] LIBRARY_DIR
bom      [-o CSV] MODEL.skp
describe MODEL.skp                 # dump a Dynamic Component's attributes
fetch.py MANIFEST.json LIB [GROUP] [--base URL] [--exts "step ifc"]
```

`convert` is the core. `-a` (angular deflection) is the dominant quality knob —
30° is the default, 45–60° for background props, 15° for close-up detail. It
matters far more than `-d`.

## Library layout

The other tools expect this shape. Nothing about it is vendor-specific:

```
LIBRARY/
  index.csv                 code, name, counts, sizes
  <CODE>/
    part.json               {"code", "name", "group", ...} - any extra keys
    stp/  <CODE>.<SIZE>.stp     become component metadata
    skp/  <CODE>.<SIZE>.skp
```

`part.json` is optional but recommended: every key lands on the component as a
`stp2skp` attribute and in the BOM. The filename convention `CODE.SIZE.ext` is
what lets `sheet` group parts into rows and columns.

## Size codes

A catalogue encodes size in the filename suffix, and every vendor does it
differently. `sheet --scheme` decides how that suffix becomes a column:

| Scheme | For | Example |
|---|---|---|
| `dn` | metric bore | `001204` → 12, `001622` → 16, `000015` → 15 |
| `thread` | 2 digits per port | `0004` → 1/2", `040504` → 1/2×3/4×1/2 |
| `number` | first run of digits | generic fallback |
| `none` | one column | unsized parts |
| `re:PAT` | anything | first capture group is the key |

Check a sample of filenames before choosing, and say which you picked. If none
fit, `re:` takes a regex — numeric groups sort numerically, others alphabetically
after them. Codes matching nothing collect in a `misc` column.

## Fetching a catalogue

`fetch.py` is source-agnostic: it takes a manifest you build however you like
(scraping is your job, not the tool's).

```json
[{"code": "ABC.123", "name": "Elbow 90", "url": "/files/abc123.zip"}]
```

It handles the things that break naive downloads: archive members named in
CP866/CP1251 (Info-ZIP refuses these outright), filenames carrying internal
designations that need normalising to the part code, and non-archive responses
saved as single files. Extra `--key=value` options are written into every
`part.json`, so vendor/material tags are yours to choose.

## Verify, always

These tools report success from inside SketchUp, where a lot can silently go
wrong. Two habits, both learned the hard way:

- **Count files on disk afterwards**, do not trust the batch total. A job that
  reports "248/248 converted" may have been handed only 248 of 266 inputs
  because stage 1 dropped some.
- **Read the build log's numbers**, not just its "ok". Face counts, volumes,
  bounding boxes and removed-material figures are printed precisely so a wrong
  result is visible without opening the file.

## Traps

Each of these cost real debugging time.

**SketchUp API**
- `BoundingBox`: `width` is X, **`height` is Y**, **`depth` is Z**.
- `a.subtract(b)` removes **a from b** — the cutter is the receiver.
- `Model#import` is **asynchronous**: it returns true and populates later, so
  saving immediately writes an empty file. Build geometry directly instead.
- `Transformation#xaxis` is **normalised** — it never reveals scale. Take the
  scale from the matrix column norm.
- `Group#to_component` may re-base the definition origin and compensate in the
  instance transform; compose placements with it or everything is offset.
- Creating a definition and exploding an instance into it leaves it momentarily
  empty, and SketchUp purges empty definitions at transaction end — **crashing**
  in `CDefinitionList::PurgeEmpty`. Build a group and `to_component` it.
- Reading `.bounds` on an entity invalidated by `make_unique` **crashes** in
  `CComponent::ComputeBounds`. Measure before, not after.
- Wrap work in `start_operation(name, true)`, or SketchUp reports each change
  interactively ("visible geometry merged with hidden geometry").
- `intersect_with(..., hidden = true, ...)` drags hidden geometry into the cut.

**Geometry**
- A coplanar or tangent cut plane yields **no intersection edges at all**.
  Predicting it is unreliable; check the result and retry ~0.02 mm off.
- Hidden geometry still counts toward a component's bounding box.
- `AUTO_SOFTEN` smooths real feature edges, making a part unsnappable. Soften
  by measured dihedral angle instead (~20°), and ~10° for traced outlines.

**Dynamic Components** (see `harness/rail.rb`, `describe`)
- Two coordinate spaces: built-ins and formulas evaluate in **millimetres**
  when `_lengthunits` is set; raw stored values are **inches**.
- Pin child sizes with **formulas**, never raw values — raw ones are ignored
  and the child stretches with its parent.
- Set `_lengthunits` on **every** sub-component or its `LenX` returns inches
  while the parent's returns millimetres.
- **`MIN`/`MAX` fail silently**, and the error propagates through dependent
  formulas with no warning. Use nested `IF`. `IF`, `ROUND`, `FLOOR`, `ABS` work.
- The engine evaluates **instances**; copy the dictionary from the definition
  to the instance and call `$dc_observers.get_latest_class.redraw_with_undo`.
- Wait for `$dc_observers` — the DC extension may load after your plugin.
- `_options` parses as `name=value` pairs; a bare `"0|5|10"` crashes
  `dcbridge.js`. Prefer a TEXTBOX.
- Restrict scaling with the DC `scaletool` attribute, **not**
  `Behavior#no_scale_mask` — the DC engine overrides the latter.
- DC cannot cut geometry. To get sub-module resolution, pre-cut the variants
  and reveal one with `hidden` formulas.

## Scope

Conversion is **one-way and lossy**: B-rep becomes triangles, so there are no
true arcs and no centre snaps on a bore. Say so rather than implying otherwise.
Reduce the triangle count by removing fillets and internal detail *before*
converting — it beats any tessellation setting.

Large sheets get heavy fast: ~11k faces per part × 145 parts ≈ 1.6M faces and a
120 MB file that SketchUp may refuse to save interactively. Warn at that scale
and offer a coarser `-a`.
