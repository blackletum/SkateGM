import os
import struct
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "exporter"))
from mapgen import stream


def check(label, ok):
    print("%-74s %s" % (label, "OK" if ok else "<-- WRONG"))


rects = [(64, 64), (64, 64), (128, 32), (32, 128)]
placed = stream.shelf_pack(rects, 256)
check("pages pack into an atlas", placed is not None and len(placed) == 4)
boxes = [(placed[i][0], placed[i][1], placed[i][0] + rects[i][0], placed[i][1] + rects[i][1]) for i in range(4)]
overlap = any(a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3] for i, a in enumerate(boxes) for b in boxes[i + 1:])
check("... without overlapping, inside it", not overlap and all(b[2] <= 256 and b[3] <= 256 for b in boxes))
check("a page bigger than the atlas doesn't fit", stream.shelf_pack([(300, 10)], 256) is None)

faces = np.arange(3 * 40000).reshape(-1, 3)
chunks = list(stream.split_faces(faces))
check("a group past 65535 vertices is split", len(chunks) == 2 and sum(len(c) for c in chunks) == 40000)
check("... each part within the limit", all(len(np.unique(c)) <= stream.MAX_VERTS for c in chunks))

light = np.full((4, 4, 4), 64, np.uint8)
img = stream.page_image(light, np.array([0.5, 0.5, 0.5]))
check("a small lightmap page keeps its size", img.shape == (4, 4, 3))
check("... and goes in at half the shader's overbright", 0 < int(img[0, 0, 0]) < 255)
big = stream.page_image(np.full((512, 512, 4), 64, np.uint8), np.array([0.5, 0.5, 0.5]))
check("a big page is halved", big.shape == (256, 256, 3))
bright = stream.page_image(np.full((4, 4, 4), 128, np.uint8), np.array([0.5, 0.5, 0.5]))
check("more light, a brighter page", int(bright[0, 0, 0]) > int(img[0, 0, 0]))

floor = np.array([[[0, 0, 100], [400, 0, 100], [0, 400, 100]], [[400, 0, 100], [400, 400, 100], [0, 400, 100]]], float)
roof = floor + np.array([0, 0, 500.0])
wall = np.array([[[0, 0, 0], [0, 400, 0], [0, 0, 300]]], float)
with tempfile.TemporaryDirectory() as tmp:
    path = os.path.join(tmp, "g.bin")
    nx, ny = stream.ground_grid(np.concatenate([floor, roof, wall]), np.array([0.0, 0.0]), np.array([384.0, 384.0]), path)
    data = open(path, "rb").read()
    x0, y0, cell, gx, gy, levels = struct.unpack_from("<fffIII", data, 4)
    grid = np.frombuffer(data, "<i2", offset=28).reshape(gy, gx, levels)
check("the ground grid's header", data[:4] == b"SGG1" and (gx, gy) == (nx, ny) == (4, 4) and cell == stream.GRID_CELL)
mid = grid[1, 1]
check("a cell under a roof holds both floors, highest first", list(mid[:2]) == [300, 50])
check("walls aren't floors", all(v in (50, 300, stream.GRID_NONE) for v in grid.reshape(-1)))

spot = stream.open_spawn(np.concatenate([floor * 4]), np.array([800.0, 800.0]))
check("a spawn on open, flat ground", spot is not None and abs(spot[2] - 416) < 1e-6)

with tempfile.TemporaryDirectory() as tmp:
    P = stream.PIECE
    quad = np.array([[[10, 10, 5], [P - 10, 10, 5], [10, P - 10, 5]]], float)
    wide = np.array([[[10, 10, 0], [2 * P + 10, 10, 0], [10, 20, 0]]], float)
    split = stream.ground_pieces(np.concatenate([quad, wide]), tmp)
    names = sorted(os.listdir(tmp))
    check("ground pieces: a triangle goes into every piece it reaches", names == ["g0_0.bin", "g1_0.bin", "g2_0.bin"] and split == {})
    data = open(os.path.join(tmp, "g0_0.bin"), "rb").read()
    nv, nf = struct.unpack_from("<II", data, 4)
    v = np.frombuffer(data, "<i4", nv * 3, 12).reshape(-1, 3)
    check("... indexed, positions at 1/32 from the piece's corner", data[:4] == b"SGC1" and nf == 2 and nv == 6 and v.min() >= 0)
    far = np.frombuffer(open(os.path.join(tmp, "g2_0.bin"), "rb").read(), "<i4", 9, 12).reshape(-1, 3)
    check("... a later piece's corner is its own", far[:, 0].min() == round((10 - 2 * P) * 32))
with tempfile.TemporaryDirectory() as tmp:
    rng = np.random.default_rng(1)
    c = rng.random((stream.PIECE_SPLIT + 50, 2)) * (stream.PIECE - 20) + 10
    dense = np.stack([np.c_[c, np.zeros(len(c))], np.c_[c + [3, 0], np.zeros(len(c))], np.c_[c + [0, 3], np.zeros(len(c))]], 1)
    split = stream.ground_pieces(dense, tmp)
    names = sorted(os.listdir(tmp))
    check("a dense piece is split in four", names == ["g0_0_0.bin", "g0_0_1.bin", "g0_0_2.bin", "g0_0_3.bin"] and split == {"0 0": ["0", "1", "2", "3"]})
    total = sum(struct.unpack_from("<II", open(os.path.join(tmp, n), "rb").read(), 4)[1] for n in names)
    check("... every triangle kept (some in two quarters)", total >= len(dense))
with tempfile.TemporaryDirectory() as tmp:
    rng = np.random.default_rng(2)
    c = rng.random((stream.PIECE_SPLIT * 5, 2)) * 60 + 10
    dense = np.stack([np.c_[c, np.zeros(len(c))], np.c_[c + [1, 0], np.zeros(len(c))], np.c_[c + [0, 1], np.zeros(len(c))]], 1)
    split = stream.ground_pieces(dense, tmp)
    counts = [struct.unpack_from("<II", open(os.path.join(tmp, n), "rb").read(), 4)[1] for n in os.listdir(tmp)]
    check("... and split again where a quarter is still dense", all(len(p) >= 2 for p in split["0 0"]) and max(counts) <= stream.PIECE_SPLIT * 2)
pages = {"a": np.zeros((512, 512, 3), np.uint8), "b": np.zeros((128, 128, 3), np.uint8), "c": np.zeros((256, 64, 3), np.uint8)}
stream.fit_budget(pages, 100000)
check("lightmaps over the texel budget: the biggest pages halved first", pages["a"].shape[:2] == (256, 256) and pages["b"].shape[:2] == (128, 128))
check("... until it fits", sum(p.shape[0] * p.shape[1] for p in pages.values()) <= 100000)
small = {"a": np.zeros((64, 64, 3), np.uint8)}
check("... and pages under it are left alone", stream.fit_budget(small, 1e6)["a"].shape[:2] == (64, 64))

from mapgen import environment
pos, uv, tri = environment.dome()
el = np.degrees(np.arcsin(pos[:, 1] / 1000.0))
check("sky dome: zenith at the top of the texture, below the horizon at the bottom", abs(uv[el.argmax(), 1]) < 1e-9 and abs(uv[el.argmin(), 1] - 1) < 1e-9)
check("... horizon where the sky rows end", np.allclose(uv[np.abs(el) < 1e-6, 1], 90.0 / (90.0 + environment.DOME_BELOW)))
grad = np.zeros((64, 512, 4), np.uint8)
grad[..., :3] = 100
grad[-8:, 300:310, :3] = 250
clouds = np.full((256, 2048, 4), 128, np.uint8)
clouds[200:210, 100:110, :3] = 255
img = environment.layered_sky(grad, clouds)
check("layered sky: grey cloud texels leave the gradient as it is", int(img[10, 0, 0]) == 100 and int(img[200, 1500, 0]) in (99, 100, 101))
check("... bright ones lighten it", int(img[:, 100:110, 0].max()) > 150)
sun = environment.sun_from(grad)
check("... the sun is where the gradient glows", 360 * 300 / 512 <= np.degrees(np.arctan2(sun[2], sun[0])) % 360 <= 360 * 310 / 512)


ground = np.array([[[-10, 0, -10], [10, 0, -10], [-10, 0, 10]], [[10, 0, -10], [10, 0, 10], [-10, 0, 10]]], float)
table = np.array([[[3, 0.8, 3], [5, 0.8, 3], [3, 0.8, 5]], [[5, 0.8, 3], [5, 0.8, 5], [3, 0.8, 5]]], float)
floors = stream.Floors(np.concatenate([ground, table]))
box = np.array([[-0.5, 2.0, -0.5], [0.5, 3.0, 0.5]])
check("a movable object hanging in the air settles onto the ground under it", abs(floors.drop(box) - 2.0) < 1e-9)
check("... onto the top of what's under it, not through it", abs(floors.drop(box + [4, 0, 4]) - 1.2) < 1e-9)
check("... one already standing (or a little sunk in) stays", floors.drop(box - [0, 2.1, 0]) == 0.0)
check("... and one over nothing is left alone", floors.drop(box + [50, 0, 0]) == 0.0)
m = np.eye(4)
m[3, :3] = [1, 5, 2]
check("settling moves the placement down only", np.allclose(stream.settled(m, 1.5)[3, :3], [1, 3.5, 2]))

layer = np.array([[200, 90]], np.uint8)
grey = np.array([[[85, 85, 85], [85, 85, 85]]], np.uint8)
check("Skate 2 light: chromaticity colours, the layer page alone sets how bright", np.all(stream.layered_light(layer, grey)[0, 0] == round(200 / 3)) and stream.layered_light(layer, grey)[0, 1, 0] == 30)
warm = np.array([[[128, 85, 42], [128, 85, 42]]], np.uint8)
lw = stream.layered_light(layer, warm)[0, 0].astype(int)
check("... a warm tint shifts the colour, not the brightness", lw[0] > lw[1] > lw[2] and abs(lw.sum() - 200) <= 2)
empty = np.array([[[2, 2, 6], [0, 0, 0]]], np.uint8)
check("... unwritten (near-black) tint texels are neutral, not black", np.all(stream.layered_light(layer, empty)[0, 0] == round(200 / 3)))

class _Tex:
    def __init__(self, a): self.a = a
    def rgba(self): return self.a
class _Sc:
    textures = {"ad": _Tex(np.zeros((16, 16, 4), np.uint8)), "wall": _Tex(np.full((256, 256, 4), 120, np.uint8)), "small": _Tex(np.full((8, 8, 4), 200, np.uint8))}
w = stream.Writer(_Sc(), None)
_Sc.textures["wire"] = _Tex(np.concatenate([np.zeros((8, 8, 3), np.uint8), np.full((8, 8, 1), 255, np.uint8)], 2))
check("ad slots (a tiny black placeholder texture, filled in at runtime by the game) are left out", w.placeholder("ad") and not w.placeholder("wall") and not w.placeholder("small"))
check("... but not tiny opaque black textures (cables, wiring)", not w.placeholder("wire"))

class _WMat:
    def __init__(self, shader, textures=None): self.shader, self.textures = shader, textures or {}
check("water materials are the game's ocean / water shaders", stream.is_water(_WMat("ocean.default")) and stream.is_water(_WMat("water.flowing")) and not stream.is_water(_WMat("environment.default")))
mats = stream.Materials("skategm/x")
tex = mats.solid((10, 20, 30))
m_id = mats.material(stream.WATER, tex)
shader, params = mats.vmts[mats.listing[m_id]["name"]]
check("... drawn see-through in a flat water colour, both sides", shader == "UnlitGeneric" and params["$translucent"] == 1 and params["$nocull"] == 1 and tex.endswith("w_0a141e"))
check("... the colour a small solid texture", np.all(mats.textures[tex][0].rgba((10, 20, 30))[..., :3] == (10, 20, 30)))
with tempfile.TemporaryDirectory() as tmp:
    sea = np.array([[[0, 0, 300], [0, 400, 300], [400, 0, 300]]], float)
    path = os.path.join(tmp, "w.bin")
    stream.ground_grid(sea, np.array([0.0, 0.0]), np.array([384.0, 384.0]), path, either_side=True)
    data = open(path, "rb").read()
    grid = np.frombuffer(data, "<i2", offset=28).reshape(4, 4, stream.GRID_LEVELS)
check("water surfaces facing either way make a water height grid", grid[0, 0, 0] == 150)
