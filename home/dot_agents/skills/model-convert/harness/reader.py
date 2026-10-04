"""Headless CAD/mesh -> mesh JSON. Run under FreeCAD's python (freecadcmd).

Formats, all with no dependencies beyond a stock FreeCAD:
  B-rep   step stp iges igs brep     (tessellated at the given deflection)
  mesh    stl obj ply amf 3mf off nas bms
  IFC     ifc                        (via the bundled ifcopenshell)

Parameters arrive as environment variables, not argv: freecadcmd treats every
trailing argument as a document to open and would try to load them itself.

  STP2SKP_SRC  STP2SKP_DST  STP2SKP_LINEAR  STP2SKP_ANGULAR

Output is a JSON document of triangulated parts in millimetres:

  {"parts": [{"name": str, "v": [x,y,z, ...], "f": [i,j,k, ...]}]}

SketchUp's Collada importer is asynchronous - it returns true and populates the
model later - so handing it a file and saving immediately yields an empty .skp.
The Ruby side therefore builds geometry directly from this JSON instead.
"""
import json
import math
import os
import re
import sys

import FreeCAD


def log(msg):
    sys.stderr.write("[stp2skp] %s\n" % msg)


def decode_step_text(text):
    """STEP encodes non-ASCII as \X2\<utf-16be hex>\X0\ - decode to real text."""
    def sub(match):
        try:
            return bytes.fromhex(match.group(1)).decode("utf-16-be")
        except ValueError:
            return match.group(0)
    return re.sub(r"\\X2\\([0-9A-Fa-f]+)\\X0\\", sub, text).strip()


def read_metadata(src):
    """Catalogue metadata from part.json plus the STEP file's own PRODUCT id.

    part.json is written by the downloader next to the stp/ directory, so a
    file at <code>/stp/<code>.<size>.stp finds it one level up.
    """
    meta = {}
    candidates = [
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(src))), "part.json"),
        os.path.join(os.path.dirname(os.path.abspath(src)), "part.json"),
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                with open(path, encoding="utf-8") as fh:
                    meta.update(json.load(fh))
                break
            except Exception as exc:
                log("  could not read %s: %s" % (path, exc))

    stem = os.path.splitext(os.path.basename(src))[0]
    meta["file"] = stem
    code = meta.get("code")
    if code and stem.startswith(code + "."):
        meta["size_code"] = stem[len(code) + 1:]

    # The STEP header carries the manufacturer's own designation, which is
    # more authoritative than anything derived from the filename.
    try:
        with open(src, encoding="utf-8", errors="replace") as fh:
            head = fh.read(200000)
        match = re.search(r"PRODUCT\s*\(\s*'([^']*)'\s*,\s*'([^']*)'", head)
        if match:
            meta["designation"] = decode_step_text(match.group(1))
            meta["product"] = decode_step_text(match.group(2))
    except Exception as exc:
        log("  could not read STEP product id: %s" % exc)

    return meta


def circle_centers(shape):
    """Connection points at circular openings, taken from the B-rep.

    Tessellation destroys arcs, so a pipe bore becomes a polygon with nothing
    at its middle to snap to. The analytic geometry still knows where the
    centre is, so emit it as a construction point. Closed circles only -
    open arcs are mostly fillet edges and would just add clutter - and
    concentric circles collapse to one point.
    """
    import Part

    found = {}
    for edge in shape.Edges:
        # Exotic curve types raise "undefined curve type" out of OCC. Snap
        # extraction is a bonus feature - it must never cost us the model.
        try:
            curve = edge.Curve
        except Exception:
            continue
        circle = None
        if isinstance(curve, Part.Circle):
            circle = curve
        elif hasattr(curve, "Circle"):
            continue          # ArcOfCircle: fillets and rounds, skip
        if circle is None or not edge.isClosed():
            continue

        c, axis = circle.Center, circle.Axis
        # Canonical axis direction so the two ends of one bore share a key.
        d = axis.normalize()
        if (d.x, d.y, d.z) < (-d.x, -d.y, -d.z):
            d = d.negative()
        # Identify the axis LINE, not just its direction: the point on the
        # line closest to the origin distinguishes parallel bores.
        t = c.x * d.x + c.y * d.y + c.z * d.z
        foot = (round(c.x - t * d.x, 2), round(c.y - t * d.y, 2),
                round(c.z - t * d.z, 2))
        key = (round(d.x, 4), round(d.y, 4), round(d.z, 4), foot)
        found.setdefault(key, []).append((t, c))

    # Keep only the extremes along each axis - the openings at the ends of a
    # bore - and drop every internal step, shoulder and seat between them.
    # Direction points out of the solid: -axis at the low end, +axis at the
    # high end, which is what a mating part needs to snap against.
    snaps = []
    for key, group in found.items():
        d = FreeCAD.Vector(key[0], key[1], key[2])
        group.sort(key=lambda item: item[0])
        ends = [(group[0][1], d.negative())]
        if len(group) > 1:
            ends.append((group[-1][1], d))
        for c, out in ends:
            snaps.append({"p": [c.x, c.y, c.z], "d": [out.x, out.y, out.z]})
    return snaps


BREP_EXT = (".step", ".stp", ".iges", ".igs", ".brep", ".brp")
MESH_EXT = (".stl", ".obj", ".ply", ".amf", ".3mf", ".off", ".nas", ".bms")


def parts_from_mesh(src):
    """Already-tessellated formats: read the triangles as they are.

    No deflection applies - the file's own tessellation is what you get.
    """
    import Mesh

    doc = FreeCAD.newDocument("mesh")
    Mesh.insert(src, doc.Name)
    parts = []
    for obj in doc.Objects:
        mesh = getattr(obj, "Mesh", None)
        if mesh is None:
            continue
        points, facets = mesh.Topology
        if not facets:
            continue
        verts = []
        for p in points:
            verts.extend((p.x, p.y, p.z))
        tris = []
        for f in facets:
            tris.extend((f[0], f[1], f[2]))
        parts.append({"name": obj.Label, "v": verts, "f": tris, "snaps": []})
    FreeCAD.closeDocument(doc.Name)
    return parts


def parts_from_step(src, linear, angular):
    import Import
    import MeshPart
    import Part

    doc = FreeCAD.newDocument("conv")
    try:
        Import.insert(src, doc.Name)
    except Exception as exc:
        log("  Import.insert: %s" % exc)
    if not doc.Objects:
        # IGES and some BREP files load nothing through Import but read fine
        # through Part, which also accepts surface-only data (no solids).
        Part.insert(src, doc.Name)
        log("  (read via Part, %d object(s))" % len(doc.Objects))

    parts = []
    for obj in doc.Objects:
        shape = getattr(obj, "Shape", None)
        if shape is None or shape.isNull():
            continue
        try:
            mesh = MeshPart.meshFromShape(
                Shape=shape,
                LinearDeflection=linear,
                AngularDeflection=math.radians(angular),
                Relative=False,
            )
        except Exception as exc:
            log("  tessellation failed for %s: %s" % (obj.Label, exc))
            continue

        points, facets = mesh.Topology
        if not facets:
            continue
        verts = []
        for p in points:
            verts.extend((p.x, p.y, p.z))          # FreeCAD works in mm
        tris = []
        for f in facets:
            tris.extend((f[0], f[1], f[2]))
        try:
            snaps = circle_centers(shape)
        except Exception as exc:
            log("  snap extraction failed for %s: %s" % (obj.Label, exc))
            snaps = []
        parts.append({"name": obj.Label, "v": verts, "f": tris, "snaps": snaps})

    FreeCAD.closeDocument(doc.Name)
    return parts


def parts_from_ifc(src):
    import ifcopenshell
    import ifcopenshell.geom

    model = ifcopenshell.open(src)
    settings = ifcopenshell.geom.settings()
    try:
        settings.set("use-world-coords", True)
    except Exception:
        settings.set(settings.USE_WORLD_COORDS, True)

    parts = []
    it = ifcopenshell.geom.iterator(settings, model)
    if it.initialize():
        while True:
            shape = it.get()
            geo = shape.geometry
            verts, faces = list(geo.verts), list(geo.faces)
            if faces:
                # ifcopenshell emits metres; SketchUp side expects millimetres.
                parts.append({
                    "name": getattr(shape, "name", "") or shape.type,
                    "v": [c * 1000.0 for c in verts],
                    "f": faces,
                })
            if not it.next():
                break
    return parts


src = os.environ["STP2SKP_SRC"]
dst = os.environ["STP2SKP_DST"]
linear = float(os.environ.get("STP2SKP_LINEAR", "0.5"))
angular = float(os.environ.get("STP2SKP_ANGULAR", "30"))

ext = os.path.splitext(src)[1].lower()
try:
    if ext == ".ifc":
        parts = parts_from_ifc(src)
    elif ext in MESH_EXT:
        parts = parts_from_mesh(src)
    elif ext in BREP_EXT:
        parts = parts_from_step(src, linear, angular)
    else:
        log("unsupported format '%s'" % ext)
        sys.exit(2)
except Exception as exc:
    log("FAILED to read %s: %s" % (os.path.basename(src), exc))
    sys.exit(1)

if not parts:
    log("no geometry found in %s" % os.path.basename(src))
    sys.exit(1)

with open(dst, "w") as fh:
    json.dump({"parts": parts, "meta": read_metadata(src)}, fh)

tris = sum(len(p["f"]) // 3 for p in parts)
pts = sum(len(p.get("snaps", [])) for p in parts)
log("%s -> %s (%d part%s, %d triangles, %d snap points)" % (
    os.path.basename(src), os.path.basename(dst),
    len(parts), "" if len(parts) == 1 else "s", tris, pts))
