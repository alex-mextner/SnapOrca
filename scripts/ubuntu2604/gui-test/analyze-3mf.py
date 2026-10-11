#!/usr/bin/env python3
# Checks the meshes and the plate layout of a 3MF saved by Snapmaker Orca (used by fix-model-test.sh;
# runs on the host, needs numpy, uses trimesh when it is installed).
# Per build item (= plate object): parts, open/non-manifold edges counted on the stored vertex
# indices (as the app's own mesh stats do), signed volume, size of each part mesh in its own frame,
# and the footprint on the bed after the item transform. Plate checks: every footprint inside the
# printable area (its bounding box: Snapmaker beds are rectangular), nothing below the bed, no two
# footprints (convex hulls) overlapping.
# Usage: analyze-3mf.py FILE.3mf [--count N] [--volume V] [--volume-tol T] [--size X,Y,Z] [--json OUT]
# Prints one "CHECK PASS|FAIL name: detail" line per criterion; exit status 1 when any check fails.
import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
import zipfile

import numpy as np

try:
    import trimesh
except ImportError:
    trimesh = None

NS = {"m": "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"}
PROD = "{http://schemas.microsoft.com/3dmanufacturing/production/2015/06}"


def transform(text):
    # 3MF matrices are row-vector 3x4: p' = p @ M + t.
    if not text:
        return np.eye(3), np.zeros(3)
    v = [float(x) for x in text.split()]
    return np.array(v[:9]).reshape(3, 3), np.array(v[9:12])


def read_model(zf, path, cache):
    if path not in cache:
        cache[path] = ET.fromstring(zf.read(path.lstrip("/")))
    return cache[path]


def object_parts(zf, path, objid, cache, M=None, t=None, seen=()):
    """Yield (mesh_key, V_local, F, M, t) for every mesh reachable from object objid in model path."""
    M = np.eye(3) if M is None else M
    t = np.zeros(3) if t is None else t
    key = f"{path}#{objid}"
    if key in seen:
        raise ValueError(f"component cycle at {key}")
    root = read_model(zf, path, cache)
    obj = root.find(f".//m:resources/m:object[@id='{objid}']", NS)
    if obj is None:
        raise ValueError(f"object {key} not found")
    mesh = obj.find("m:mesh", NS)
    if mesh is not None:
        V = np.array([[float(v.get(a)) for a in "xyz"] for v in mesh.iterfind("m:vertices/m:vertex", NS)]).reshape(-1, 3)
        F = np.array([[int(tr.get(a)) for a in ("v1", "v2", "v3")] for tr in mesh.iterfind("m:triangles/m:triangle", NS)], dtype=np.int64).reshape(-1, 3)
        yield key, V, F, M, t
    for comp in obj.iterfind("m:components/m:component", NS):
        cM, ct = transform(comp.get("transform"))
        sub = comp.get(PROD + "path") or path
        # Compose: p_world = (p @ cM + ct) @ M + t
        yield from object_parts(zf, sub, comp.get("objectid"), cache, cM @ M, ct @ M + t, seen + (key,))


def edge_stats(F):
    e = np.sort(np.vstack([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]]), axis=1)
    _, c = np.unique(e, axis=0, return_counts=True)
    d = np.vstack([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]])
    _, dc = np.unique(d, axis=0, return_counts=True)
    return int((c == 1).sum()), int((c > 2).sum()), int((dc > 1).sum())


def signed_volume(V, F):
    a, b, c = V[F[:, 0]], V[F[:, 1]], V[F[:, 2]]
    return float(np.einsum("ij,ij->i", a, np.cross(b, c)).sum() / 6.0)


def cross2(u, v):
    return u[0] * v[1] - u[1] * v[0]


def hull2d(P):
    # Andrew's monotone chain, counter-clockwise, no collinear points.
    P = np.unique(np.round(P, 6), axis=0)
    if len(P) < 3:
        return P
    P = P[np.lexsort((P[:, 1], P[:, 0]))]

    def half(pts):
        h = []
        for p in pts:
            while len(h) >= 2 and cross2(h[-1] - h[-2], p - h[-2]) <= 0:
                h.pop()
            h.append(p)
        return h

    lo, up = half(P), half(P[::-1])
    return np.array(lo[:-1] + up[:-1])


def separation(A, B):
    """Largest gap between two convex polygons along their edge normals (negative = overlap depth)."""
    best = -np.inf
    for poly in (A, B):
        for i in range(len(poly)):
            e = poly[(i + 1) % len(poly)] - poly[i]
            norm = np.linalg.norm(e)
            if norm == 0:  # degenerate footprint (fewer than 3 distinct points)
                continue
            n = np.array([e[1], -e[0]]) / norm
            pa, pb = A @ n, B @ n
            best = max(best, pb.min() - pa.max(), pa.min() - pb.max())
    return float(best) if np.isfinite(best) else float("inf")  # no edge at all: nothing to overlap


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--count", type=int)
    ap.add_argument("--volume", type=float)
    ap.add_argument("--volume-tol", type=float, default=1.0)
    ap.add_argument("--size")
    ap.add_argument("--size-tol", type=float, default=0.02)
    ap.add_argument("--json")
    a = ap.parse_args()

    zf = zipfile.ZipFile(a.file)
    cache = {}
    main_path = "/3D/3dmodel.model"
    root = read_model(zf, main_path, cache)
    names = {}
    try:
        cfg = ET.fromstring(zf.read("Metadata/model_settings.config"))
        for o in cfg.iterfind("object"):
            n = o.find("metadata[@key='name']")
            names[o.get("id")] = n.get("value") if n is not None else ""
    except KeyError:
        pass
    settings = json.loads(zf.read("Metadata/project_settings.config"))
    area = np.array([[float(x) for x in p.split("x")] for p in settings["printable_area"]])
    bed_min, bed_max = area.min(0), area.max(0)

    objects = []
    for item in root.iterfind("m:build/m:item", NS):
        oid = item.get("objectid")
        M, t = transform(item.get("transform"))
        parts, world = [], []
        for key, V, F, pM, pt in object_parts(zf, main_path, oid, cache, M=M, t=t):
            if len(F) == 0:
                continue
            open_e, nonmf, dup_dir = edge_stats(F)
            # Volume and size in the part's own frame; world volume differs only by det(M) (mirroring).
            part = {
                "mesh": key, "vertices": len(V), "facets": len(F), "open_edges": open_e,
                "nonmanifold_edges": nonmf, "same_direction_edge_pairs": dup_dir,
                "volume": round(signed_volume(V, F), 4), "size": [round(float(x), 4) for x in V.max(0) - V.min(0)],
                "world_volume": round(signed_volume(V @ pM + pt, F), 4),
            }
            if trimesh is not None:
                tm = trimesh.Trimesh(V, F, process=False)
                bodies = trimesh.graph.connected_components(tm.face_adjacency, nodes=np.arange(len(F)), engine="scipy")
                part.update(watertight=bool(tm.is_watertight), winding_consistent=bool(tm.is_winding_consistent),
                            bodies=len(bodies))
            parts.append(part)
            world.append(V @ pM + pt)
        if not world:
            objects.append({"object_id": oid, "name": names.get(oid, ""), "printable": item.get("printable", "1"),
                            "parts": [], "world_min": [0.0] * 3, "world_max": [0.0] * 3, "hull": np.zeros((0, 2))})
            continue
        W = np.vstack(world)
        objects.append({
            "object_id": oid, "name": names.get(oid, ""), "printable": item.get("printable", "1"), "parts": parts,
            "world_min": [round(float(x), 3) for x in W.min(0)], "world_max": [round(float(x), 3) for x in W.max(0)],
            "_lo": W.min(0), "_hi": W.max(0),  # full precision for the checks; world_min/max are for display
            "hull": hull2d(W[:, :2]),
        })

    checks = []

    def check(name, ok, detail):
        checks.append((name, bool(ok), detail))

    for o in objects:
        tag = f"object {o['object_id']}"
        np_ = len(o["parts"])
        check(f"{tag} single part", np_ == 1, f"{np_} part(s)")
        if np_ == 0:
            continue
        for p in o["parts"]:
            check(f"{tag} 0 open edges", p["open_edges"] == 0, f"open={p['open_edges']} nonmanifold={p['nonmanifold_edges']} "
                  f"V={p['vertices']} F={p['facets']}")
            check(f"{tag} consistent winding", p["same_direction_edge_pairs"] == 0, f"{p['same_direction_edge_pairs']} directed edges used twice")
            if a.volume is not None:
                check(f"{tag} volume", abs(p["volume"] - a.volume) <= a.volume_tol, f"{p['volume']:.4f} mm3 (expect {a.volume}±{a.volume_tol})")
            else:
                check(f"{tag} positive volume", p["volume"] > 0, f"{p['volume']:.4f} mm3")
            if a.size:
                want = sorted(float(x) for x in a.size.split(","))
                got = sorted(p["size"])
                check(f"{tag} size", all(abs(g - w) <= a.size_tol for g, w in zip(got, want)),
                      "x".join(f"{x:.2f}" for x in p["size"]) + f" (expect {a.size})")
            if "watertight" in p:
                check(f"{tag} trimesh watertight", p["watertight"] and p["bodies"] == 1,
                      f"watertight={p['watertight']} winding={p['winding_consistent']} bodies={p['bodies']}")
        if o["printable"] in ("0", "false"):  # not sliced; placement does not matter
            continue
        lo, hi = o["_lo"], o["_hi"]
        inside = (lo[:2] >= bed_min - 1e-3).all() and (hi[:2] <= bed_max + 1e-3).all()
        check(f"{tag} inside bed", inside, f"x {lo[0]:.2f}..{hi[0]:.2f} y {lo[1]:.2f}..{hi[1]:.2f} bed {bed_min.tolist()}..{bed_max.tolist()}")
        check(f"{tag} on bed", abs(lo[2]) <= 1e-3, f"z min {lo[2]:.4f}")

    gaps = []
    placed = [o for o in objects if o["parts"] and o["printable"] not in ("0", "false")]
    for i in range(len(placed)):
        for j in range(i + 1, len(placed)):
            gaps.append((separation(placed[i]["hull"], placed[j]["hull"]), placed[i]["object_id"], placed[j]["object_id"]))
    if gaps:
        g, i, j = min(gaps)
        check("no footprint overlaps", g > 0, f"smallest gap {g:.3f} mm (objects {i}/{j}); "
              f"{sum(1 for x in gaps if x[0] <= 0)} overlapping pair(s)")
    if a.count is not None:
        check("object count", len(objects) == a.count, f"{len(objects)} build items (expect {a.count})")
    else:  # a save that lost every object must not pass vacuously
        check("printable objects", placed, f"{len(placed)} non-empty printable build item(s)")

    for o in objects:
        p = o["parts"][0] if o["parts"] else {}
        print(f"object {o['object_id']:>3} {o['name'][:28]:28} parts={len(o['parts'])} V={p.get('vertices')} F={p.get('facets')} "
              f"open={p.get('open_edges')} vol={p.get('volume')} size={'x'.join(f'{x:.2f}' for x in p.get('size', []))} "
              f"bed x {o['world_min'][0]:.2f}..{o['world_max'][0]:.2f} y {o['world_min'][1]:.2f}..{o['world_max'][1]:.2f} z {o['world_min'][2]:.3f}")
    for name, ok, detail in checks:
        print(f"CHECK {'PASS' if ok else 'FAIL'} {name}: {detail}")
    if a.json:
        for o in objects:
            o["hull"] = o["hull"].round(3).tolist()
            o.pop("_lo", None)
            o.pop("_hi", None)
        with open(a.json, "w") as f:
            json.dump({"file": a.file, "bed": [bed_min.tolist(), bed_max.tolist()], "objects": objects,
                       "checks": [{"name": n, "pass": ok, "detail": d} for n, ok, d in checks]}, f, indent=1)
    sys.exit(0 if all(ok for _, ok, _ in checks) else 1)


if __name__ == "__main__":
    main()
