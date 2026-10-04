# Harness

Support code for the `model-convert` skill. See `../SKILL.md` first.

| File | Role |
|---|---|
| `convert` | CLI: models -> `.skp` components (stage 1 FreeCAD, stage 2 SketchUp) |
| `sheet` | CLI: a part library -> one catalogue `.skp`, rows = parts, columns = sizes |
| `bom` | CLI: walk a `.skp`, tally components, write CSV (+ cut list for scaled parts) |
| `describe` | CLI: dump a Dynamic Component's attributes and formulas to JSON |
| `fetch.py` | Download a catalogue from a JSON manifest into a library |
| `reader.py` | Runs under `freecadcmd`: any supported format -> mesh JSON |
| `sketchup_batch.rb` | The SketchUp plugin. Inert unless a job file exists |
| `rail.rb` | Optional: resize a segmented rail component in place |

## How a run works

1. A CLI writes `$STATE/job.json` describing the work.
2. It copies `sketchup_batch.rb` into the user's SketchUp Plugins folder.
3. It launches SketchUp; the plugin sees the job, does the work, writes
   `$STATE/job.done` and a human-readable `$STATE/job.log`.
4. The CLI prints the log and quits SketchUp.

`$STATE` is `~/.local/share/model-convert` unless `MODELCONV_STATE` says otherwise.

Job modes handled by the plugin: default batch build, `sheet`, `bom`,
`describe`, `survey`, `pipes`, `profiles`, `variants`, `rail`.

## Adding a format

`reader.py` dispatches on extension into `BREP_EXT`, `MESH_EXT`, or IFC. To add
one, put it in the right tuple — FreeCAD does the rest. Anything needing a
module FreeCAD does not bundle does not belong here.
