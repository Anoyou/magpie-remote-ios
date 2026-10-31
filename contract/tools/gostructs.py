#!/usr/bin/env python3
"""Expand Go structs into their encoding/json wire shape, straight from source.

Usage: gostructs.py <magpie-root> <pkg.Type> [<pkg.Type> ...]   (prints JSON)

Parses the non-test .go files of the packages it needs (internal/<pkg>),
indexes every `type X struct {...}` and `type X <basic>` declaration, and
expands a root type the way encoding/json does:
  * unexported fields are dropped; `json:"-"` is dropped
  * an embedded struct without a json name promotes its fields
  * Go's field-precedence rule: the shallowest depth wins, a tie between
    tagged/untagged is won by the tagged one, any other tie drops the name
  * nil slices / maps / pointers without omitempty encode as null
It records the file:line of each field so the spec can cite it.
"""
import json, os, re, sys

ROOT = sys.argv[1]
BASIC = {"string": "string", "bool": "boolean", "int": "integer", "int8": "integer", "int16": "integer",
         "int32": "integer", "int64": "integer", "uint": "integer", "uint8": "integer", "uint16": "integer",
         "uint32": "integer", "uint64": "integer", "float32": "number", "float64": "number", "byte": "integer",
         "rune": "integer", "any": "any", "interface{}": "any"}
SPECIAL = {"time.Time": "string(RFC3339 date-time)", "time.Duration": "integer(nanoseconds)",
           "json.RawMessage": "any(raw JSON)", "*time.Location": "any"}

pkgs = {}  # pkg -> {"structs": {name: (fields, file, line)}, "aliases": {name: underlying}}


def strip_comment(line):
    out, in_bt, in_q, i = [], False, False, 0
    while i < len(line):
        c = line[i]
        if c == '`' and not in_q:
            in_bt = not in_bt
        elif c == '"' and not in_bt and (i == 0 or line[i - 1] != '\\'):
            in_q = not in_q
        elif c == '/' and not in_bt and not in_q and line[i:i + 2] == '//':
            break
        out.append(c)
        i += 1
    return ''.join(out).strip()


def load(pkg):
    if pkg in pkgs:
        return pkgs[pkg]
    d = os.path.join(ROOT, "internal", pkg)
    info = {"structs": {}, "aliases": {}}
    pkgs[pkg] = info
    if not os.path.isdir(d):
        return info
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".go") or fn.endswith("_test.go"):
            continue
        path = os.path.join(d, fn)
        lines = open(path, encoding="utf-8").read().split("\n")
        i = 0
        while i < len(lines):
            m = re.match(r'^type\s+([A-Za-z_]\w*)(\[[^\]]*\])?\s+struct\s*\{\s*(\}?)\s*$', lines[i])
            if m:
                name, start = m.group(1), i + 1
                if m.group(3):
                    info["structs"][name] = ([], f"internal/{pkg}/{fn}", start)
                    i += 1
                    continue
                fields, depth, j = [], 1, i + 1
                while j < len(lines) and depth > 0:
                    raw = strip_comment(lines[j])
                    if raw == '}' and depth == 1:
                        break
                    im = re.match(r'^([A-Z]\w*)\s+(\[\]|\*)?struct\s*\{$', raw)
                    if im:  # an inline struct: register it as Outer_Field
                        inner, k = [], j + 1
                        while k < len(lines) and not strip_comment(lines[k]).startswith('}'):
                            r2 = strip_comment(lines[k])
                            if r2:
                                inner.append((r2, k + 1))
                            k += 1
                        close = strip_comment(lines[k])
                        syn = f"{name}_{im.group(1)}"
                        info["structs"][syn] = (inner, f"internal/{pkg}/{fn}", j + 1)
                        fields.append((f"{im.group(1)} {im.group(2) or ''}{syn} {close[1:].strip()}", j + 1))
                        j = k + 1
                        continue
                    if raw:
                        fields.append((raw, j + 1))
                    j += 1
                info["structs"][name] = (fields, f"internal/{pkg}/{fn}", start)
                i = j + 1
                continue
            m = re.match(r'^type\s+([A-Za-z_]\w*)\s+(=\s*)?([\w.\[\]*]+)\s*$', lines[i])
            if m:
                info["aliases"][m.group(1)] = (m.group(3), f"internal/{pkg}/{fn}", i + 1)
            i += 1
    return info


def parse_field(raw):
    tag = None
    m = re.search(r'`([^`]*)`', raw)
    if m:
        tag = m.group(1)
        raw = raw[:m.start()].strip()
    jname, opts = None, []
    if tag:
        t = re.search(r'json:"([^"]*)"', tag)
        if t:
            parts = t.group(1).split(',')
            jname, opts = parts[0], parts[1:]
    m = re.match(r'^([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s+(.+)$', raw)
    if m and not re.match(r'^[\w.]+$', raw):
        names = [n.strip() for n in m.group(1).split(',')]
        return names, m.group(2).strip(), jname, opts, False
    # embedded
    typ = raw.strip()
    base = typ.lstrip('*').split('.')[-1]
    return [base], typ, jname, opts, True


def resolve_type(pkg, typ):
    """-> (kind, detail) where kind in basic/special/struct/slice/map/ptr."""
    if typ in SPECIAL:
        return ("special", SPECIAL[typ])
    if typ.startswith('*'):
        return ("ptr", typ[1:])
    if typ.startswith('[]'):
        return ("slice", typ[2:])
    if typ.startswith('map['):
        depth, k = 0, 3
        for k in range(3, len(typ)):
            if typ[k] == '[':
                depth += 1
            elif typ[k] == ']':
                if depth == 0:
                    break
                depth -= 1
        return ("map", (typ[4:k], typ[k + 1:]))
    if typ in BASIC:
        return ("basic", BASIC[typ])
    if typ.startswith('struct{') or typ.startswith('func') or typ.startswith('chan') or typ.startswith('atomic.'):
        return ("other", typ)
    if '.' in typ:
        p, n = typ.split('.', 1)
        if p in ("time", "json", "sync", "http", "atomic"):
            return ("other", typ)
        return resolve_type(p, n) if False else _named(p, n)
    return _named(pkg, typ)


def _named(pkg, name):
    info = load(pkg)
    if name in info["structs"]:
        return ("struct", (pkg, name))
    if name in info["aliases"]:
        under = info["aliases"][name][0]
        k = resolve_type(pkg, under)
        if k[0] == "basic":
            return ("basic", f"{k[1]}({pkg}.{name})")
        return k
    return ("unknown", f"{pkg}.{name}")


def fields_of(pkg, name, depth=0, seen=()):
    """encoding/json visible fields of struct pkg.name: list of dicts."""
    if (pkg, name) in seen:
        return []
    info = load(pkg)
    flist, fpath, fline = info["structs"][name]
    cands = []
    for raw, line in flist:
        names, typ, jname, opts, embedded = parse_field(raw)
        if jname == '-' and not opts:
            continue
        for n in names:
            if embedded and jname is None:
                k = resolve_type(pkg, typ.lstrip('*'))
                if k[0] == "struct":
                    sp, sn = k[1]
                    for f in fields_of(sp, sn, depth + 1, seen + ((pkg, name),)):
                        cands.append(f)
                    continue
            if not n[0].isupper():
                continue
            cands.append({"json": jname or n, "go": f"{pkg}.{name}.{n}", "goType": typ, "pkg": pkg,
                          "omitempty": "omitempty" in opts, "omitzero": "omitzero" in opts,
                          "string": "string" in opts, "tagged": jname is not None and jname != "",
                          "depth": depth, "src": f"{fpath}:{line}"})
    # Go precedence
    by = {}
    for c in cands:
        by.setdefault(c["json"], []).append(c)
    out = []
    for j, cs in by.items():
        md = min(c["depth"] for c in cs)
        top = [c for c in cs if c["depth"] == md]
        if len(top) > 1:
            tagged = [c for c in top if c["tagged"]]
            if len(tagged) == 1:
                top = tagged
            else:
                continue  # ambiguous: dropped by encoding/json
        out.append(top[0])
    order = {id(c): i for i, c in enumerate(cands)}
    out.sort(key=lambda c: order[id(c)])
    if depth == 0:
        for c in out:
            c = c
    return out


def describe(pkg, typ, stack=()):
    k = resolve_type(pkg, typ)
    kind, d = k
    if kind == "basic":
        return {"type": d}
    if kind == "special":
        return {"type": d}
    if kind == "ptr":
        inner = describe(pkg, d, stack)
        inner = dict(inner)
        inner["nullable"] = True
        return inner
    if kind == "slice":
        if d == "byte":
            return {"type": "string(base64)"}
        return {"type": "array", "items": describe(pkg, d, stack), "nullable": True}
    if kind == "map":
        return {"type": "object(map)", "keys": d[0], "values": describe(pkg, d[1], stack), "nullable": True}
    if kind == "struct":
        sp, sn = d
        if (sp, sn) in stack:
            return {"type": "object", "ref": f"{sp}.{sn}", "recursive": True}
        flds = fields_of(sp, sn)
        props = {}
        for f in flds:
            desc = describe(f["pkg"], f["goType"], stack + ((sp, sn),))
            entry = {"go": f["go"], "goType": f["goType"], "src": f["src"], **desc}
            if f["omitempty"]:
                entry["omitempty"] = True
            if f["omitzero"]:
                entry["omitzero"] = True
            props[f["json"]] = entry
        return {"type": "object", "ref": f"{sp}.{sn}", "src": "%s:%d" % load(sp)["structs"][sn][1:], "properties": props}
    return {"type": kind, "detail": d}


if __name__ == "__main__":
    out = {}
    for spec in sys.argv[2:]:
        p, n = spec.split('.', 1)
        out[spec] = describe(p, n)
    json.dump(out, sys.stdout, indent=1, ensure_ascii=False)
