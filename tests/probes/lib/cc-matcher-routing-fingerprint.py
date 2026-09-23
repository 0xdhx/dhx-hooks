#!/usr/bin/env python3
"""Fingerprint Claude Code's hook-matcher routing cluster in a bun-embedded bundle.

Usage: cc-matcher-routing-fingerprint.py [--raw|--norm] <bundle-or-executable>

Prints `sha256 <hex>` and a `symbols ...` line (exit 0), the raw or normalized
cluster text (--raw / --norm), or `UNRESOLVED <what>` on stderr (exit 2) —
never a sha for a cluster it could not fully resolve.

WHAT IS FINGERPRINTED — the five functions CC routes a hook matcher through
(the routine the disjointness probe's BASH_MATCHER_FILTER mirrors):
  S splitter    the simple-path member splitter (its two regex literals)
  R router      matcher -> bool: simple path via S, else unanchored RegExp,
                widened by A's alias/family names
  C caller      per-hook entry: normalizes the matcher via N, calls R
  N normalizer  strips the [1m]/[2m] suffix for Pre/PostModelSwitch matchers
  A alias       tool-name family/alias helper (hookMatcherFamilyNames)

HOW, AND WHY NOT BY NAME. Minified names change every build and COLLIDE across
modules inside one bundle (measured: 2.1.278 has two unrelated `function H2e(`),
so a name is never searched for bare. Each function is located from a stable
literal or from a resolved neighbour, by OFFSET:
  S  enclosing function of the ternary of both splitter regex literals
  N  enclosing function of `!=="PreModelSwitch"&&`
  C  enclosing function of `N(e.hook_event_name,`
  R  the function C calls as `R(<id>,N(e.hook_event_name` — picked among its
     same-named definitions as the one whose body calls BOTH S and A
  A  enclosing function of the `...<id>.hookMatcherFamilyNames?.(` spread
     (the other occurrences are a method definition and string tables)
The R-calls-S-and-A check is the coherence gate: an anchor that drifts onto the
wrong function fails it and resolution stops (exit 2) instead of hashing a
neighbour. Anchors are taken from the FIRST bundle copy (2.1.270+ embeds the
bundle more than once; copies are byte-identical).

NORMALIZATION is the 2026-09-19 H4 seed's, verbatim
(reports/2026-09-19-h4-matcher-routing-fingerprint-cc-2.1.278/norm.py): rename
identifiers by first appearance, keep keywords and `.property` names. It also
renames words inside string literals — a seed quirk kept deliberately, because
changing it would change every recorded sha in config/cc-matcher-routing.tsv.
The concatenation order S,R,C,N,A reproduces the seed's output byte-for-byte.
"""
import hashlib
import re
import sys

KW = set("function return let const var if else for of in new try catch await async void true false null this typeof instanceof throw while do switch case break default".split())

SPLIT_ANCHOR = b'?/^[a-zA-Z0-9_|, -]+$/:/^[a-zA-Z0-9_|]+$/'
NORM_ANCHOR = b'!=="PreModelSwitch"&&'
ALIAS_RE = re.compile(rb'\.\.\.[\w$]+\.hookMatcherFamilyNames\?\.\(')
FUNC_HEAD = re.compile(rb'function ([\w$]+)\(')


class Unresolved(Exception):
    pass


def body_end(data, fstart):
    """Offset just past the brace-balanced body of the function starting at fstart."""
    b = data.find(b'{', fstart)
    if b < 0:
        return -1
    depth = 0
    e = b
    n = len(data)
    while e < n:
        c = data[e]
        if c == 0x7B:
            depth += 1
        elif c == 0x7D:
            depth -= 1
            if depth == 0:
                return e + 1
        e += 1
    return -1


def enclosing(data, off, what, window=40000):
    """(name, start, end) of the innermost `function NAME(` whose body spans off."""
    lo = max(0, off - window)
    starts = [m.start() for m in re.finditer(rb'function ', data[lo:off])]
    for s in reversed(starts):
        s += lo
        m = FUNC_HEAD.match(data, s)
        if not m:
            continue
        e = body_end(data, s)
        if e > off:
            return m.group(1).decode('latin-1'), s, e
    raise Unresolved(f'{what}: no enclosing function around offset {off}')


def definition_calling(data, name, must_call, what):
    """The `function name(` definition whose body calls every name in must_call."""
    head = b'function ' + name.encode('latin-1') + b'('
    i = 0
    seen = 0
    while True:
        i = data.find(head, i)
        if i < 0:
            break
        seen += 1
        e = body_end(data, i)
        body = data[i:e]
        if e > 0 and all(re.search(rb'(?<![\w$.])' + re.escape(c.encode('latin-1')) + rb'\(', body) for c in must_call):
            return i, e
        i += 1
    raise Unresolved(f'{what}: none of {seen} `function {name}(` definition(s) calls {"+".join(must_call)}')


def resolve(data):
    a = data.find(SPLIT_ANCHOR)
    if a < 0:
        raise Unresolved('splitter anchor (both simple-path regex literals) absent')
    S = enclosing(data, a, 'splitter')

    a = data.find(NORM_ANCHOR)
    if a < 0:
        raise Unresolved('normalizer anchor !=="PreModelSwitch"&& absent')
    N = enclosing(data, a, 'normalizer')

    call = re.compile(rb'([\w$]+)\([\w$]+,' + re.escape(N[0].encode('latin-1')) + rb'\(e\.hook_event_name,')
    m = call.search(data)
    if not m:
        raise Unresolved(f'caller: no `R(<id>,{N[0]}(e.hook_event_name,` call site')
    C = enclosing(data, m.start(), 'caller')
    r_name = m.group(1).decode('latin-1')

    m = ALIAS_RE.search(data)
    if not m:
        raise Unresolved('alias anchor ...<id>.hookMatcherFamilyNames?.( absent')
    A = enclosing(data, m.start(), 'alias')

    rs, re_ = definition_calling(data, r_name, [S[0], A[0]], 'router')
    R = (r_name, rs, re_)
    return S, R, C, N, A


def normalize(s):
    ids = {}

    def rep(m):
        w = m.group(0)
        if w in KW:
            return w
        return ids.setdefault(w, f"ID{len(ids)}")
    return re.sub(r'(?<![A-Za-z0-9_$.])[A-Za-z_$][A-Za-z0-9_$]*', rep, s)


def main(argv):
    mode = 'sha'
    args = list(argv)
    if args and args[0] in ('--raw', '--norm'):
        mode = args.pop(0)[2:]
    if len(args) != 1:
        print('usage: cc-matcher-routing-fingerprint.py [--raw|--norm] <bundle>', file=sys.stderr)
        return 64
    try:
        data = open(args[0], 'rb').read()
    except OSError as e:
        print(f'UNRESOLVED unreadable input: {e}', file=sys.stderr)
        return 2
    try:
        parts = resolve(data)
    except Unresolved as e:
        print(f'UNRESOLVED {e}', file=sys.stderr)
        return 2
    raw = '\n'.join(data[s:e].decode('latin-1') for _, s, e in parts)
    if mode == 'raw':
        sys.stdout.write(raw)
        return 0
    norm = normalize(raw)
    if mode == 'norm':
        sys.stdout.write(norm)
        return 0
    print('sha256 ' + hashlib.sha256(norm.encode('latin-1')).hexdigest())
    print('symbols ' + ' '.join(f'{k}={p[0]}' for k, p in zip('SRCNA', parts)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
