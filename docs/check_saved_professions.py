#!/usr/bin/env python3
"""从 Cuberite 保存的区块 NBT 里读出村民的 Profession，用于交叉验证 villager_profession.lua。

用法：
  check_saved_professions.py                          # 默认本机 r.0.0.mca，chunk (3,3)
  check_saved_professions.py <region文件> <chunkX> <chunkZ>
  check_saved_professions.py <region文件> all         # 扫描该 region 内全部区块

注意：Cuberite 的区块 NBT 根是 Level 复合标签，实体在其 Entities 列表里。
"""
import struct
import sys
import zlib


def read_region(path):
    with open(path, "rb") as f:
        return f.read()


def chunk_bytes(data, cx, cz):
    idx = (cx % 32) + (cz % 32) * 32
    b = data[idx * 4:idx * 4 + 4]
    off = (b[0] << 16) | (b[1] << 8) | b[2]
    if off == 0:
        return None
    base = off * 4096
    length = struct.unpack(">I", data[base:base + 4])[0]
    comp = data[base + 4]
    raw = data[base + 5:base + 5 + length]
    return zlib.decompress(raw) if comp in (1, 2) else raw


class Reader:
    def __init__(self, buf):
        self.buf = buf
        self.pos = 0

    def unpack(self, fmt):
        v = struct.unpack_from(">" + fmt, self.buf, self.pos)
        self.pos += struct.calcsize(">" + fmt)
        return v[0] if len(v) == 1 else v

    def payload(self, t):
        if t == 0:
            return None
        if t == 1:
            return self.unpack("b")
        if t == 2:
            return self.unpack("h")
        if t == 3:
            return self.unpack("i")
        if t == 4:
            return self.unpack("q")
        if t == 5:
            return self.unpack("f")
        if t == 6:
            return self.unpack("d")
        if t == 7:
            n = self.unpack("i")
            v = self.buf[self.pos:self.pos + n]
            self.pos += n
            return v
        if t == 8:
            n = self.unpack("H")
            s = self.buf[self.pos:self.pos + n].decode("utf8", "replace")
            self.pos += n
            return s
        if t == 9:
            et = self.unpack("b")
            n = self.unpack("i")
            return [self.payload(et) for _ in range(n)]
        if t == 10:
            d = {}
            while True:
                t2 = self.unpack("b")
                if t2 == 0:
                    break
                n = self.unpack("H")
                name = self.buf[self.pos:self.pos + n].decode("utf8", "replace")
                self.pos += n
                d[name] = self.payload(t2)
            return d
        if t == 11:
            n = self.unpack("i")
            return [self.unpack("i") for _ in range(n)]
        if t == 12:
            n = self.unpack("i")
            return [self.unpack("q") for _ in range(n)]
        raise ValueError("unknown tag %d" % t)

    def root(self):
        t = self.unpack("b")
        n = self.unpack("H")
        self.pos += n
        return self.payload(t)


def villagers_in(nbt):
    root = Reader(nbt).root()
    level = root.get("Level", root)
    out = []
    for e in (level.get("entities") or level.get("Entities") or []):
        if not isinstance(e, dict):
            continue
        eid = str(e.get("id", ""))
        if "illager" not in eid or "Zombie" in eid:
            continue
        pos = e.get("Pos") or []
        out.append({
            "id": eid,
            "profession": e.get("Profession"),
            "pos": [round(v, 1) for v in pos],
            "customname": e.get("CustomName"),
        })
    return out


def scan(path, cx, cz):
    data = read_region(path)
    raw = chunk_bytes(data, cx, cz)
    if raw is None:
        return []
    return villagers_in(raw)


def main():
    args = sys.argv[1:]
    if not args:
        path, cx, cz = "/home/david/Cuberite/world/region/r.0.0.mca", 3, 3
        for v in scan(path, cx, cz):
            print("VILLAGER NBT prof=%s pos=%s name=%r" % (v["profession"], v["pos"], v["customname"]))
        return
    path = args[0]
    if len(args) >= 2 and args[1] == "all":
        found = 0
        for cx in range(32):
            for cz in range(32):
                for v in scan(path, cx, cz):
                    found += 1
                    print("VILLAGER NBT chunk=(%d,%d) prof=%s pos=%s name=%r" % (
                        cx, cz, v["profession"], v["pos"], v["customname"]))
        print("total villagers:", found)
        return
    cx = int(args[1]) if len(args) > 1 else 0
    cz = int(args[2]) if len(args) > 2 else 0
    for v in scan(path, cx, cz):
        print("VILLAGER NBT prof=%s pos=%s name=%r" % (v["profession"], v["pos"], v["customname"]))

if __name__ == "__main__":
    main()
