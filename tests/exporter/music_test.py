import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "exporter"))
from tools.asset_pipeline import skate3_music as m


def check(label, ok):
    print("%-74s %s" % (label, "OK" if ok else "<-- WRONG"))


def mpf(nodes):
    head = bytearray(b"PFDx" + bytes([5, 3]) + bytes(0x42))
    table_at = len(head)
    body = b"".join(struct.pack(">" + "I" * len(w), *w) for w in nodes)
    nodes_at = table_at + 2 * len(nodes)
    nodes_at += -nodes_at % 4
    offsets, at = [], nodes_at
    for w in nodes:
        offsets.append(at // 4)
        at += 4 * len(w)
    struct.pack_into(">III", head, 0x14, table_at, nodes_at, at)
    data = bytes(head) + b"".join(struct.pack(">H", o) for o in offsets)
    return data + bytes(nodes_at - len(data)) + body


def node(sample, kind, nxt, low=0x20):
    return [(sample << 16) | low, kind, 0x40, 0, 0x7F0000 | nxt]


def end():
    return [0xFFFF0020, 0x0101, 0x10000, 0]


nodes = [
    node(0, 0x8101, 2), end(), node(1, 0x8401, 3), node(2, 0x8401, 1),
    node(0, 0x8101, 6), end(), node(3, 0x8401, 7), node(4, 0x8401, 5),
    node(0, 0x8101, 9, low=0x40), end(), node(4, 0x8401, 8, low=0x40),
]
check("the full songs' chains, in order; the short cuts (0x40) left out", m.chains(mpf(nodes)) == [[1, 2], [3, 4]])
check("a chain that loops back on itself ends", m.chains(mpf([node(0, 0x8101, 1), node(1, 0x8401, 2), node(2, 0x8401, 1)])) == [[1, 2]])
check("the string tables' hash (an IPOD_ label's stem = the song's id)", m.label_hash("IPOD_AGENTORANGE_BLOODSTAINS") == 0x440DA036)
check("the hash of a label in the tables", m.label_hash("ID_CAC_SUBCATEGORY_BOARD_RANDOM") == 0x00029D00)
strings = [(0x10, b"IPOD_X_Y_TITLE"), (0x20, b"IPOD_X_Y_ARTIST")]
blob = b""
offsets = []
for _, s in strings:
    offsets.append(len(blob))
    blob += s + b"\0"
data = struct.pack("<III", 0x39000, 0, len(strings)) + bytes(0x24 - 12)
data += b"".join(struct.pack("<II", h, o) for (h, _), o in zip(strings, offsets)) + blob
check("a string table: hash -> text", m.string_table(data) == {0x10: "IPOD_X_Y_TITLE", 0x20: "IPOD_X_Y_ARTIST"})
check("names cleaned: control codes out, odd spaces collapsed", m.clean("\x84Lover's Leap  \xa0") == "Lover's Leap")
check("ids from stems: lower case, safe for a file name", m.song_id("IPOD_THEDEMONICS_750-FOUR") == "thedemonics_750_four")
