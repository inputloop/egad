#!/usr/bin/env python3
# egad-decl.py -- the declarative layer: Org headlines with property drawers <-> JSON, both ways.
#
# Copyright (C) 2026 Corwin Brust <corwin@bru.st>.  Authored with Claude (Cowork).
# SPDX-License-Identifier: GPL-3.0-or-later.  WITHOUT ANY WARRANTY; see <https://www.gnu.org/licenses/>.
#
# THE SUBSET (what makes "both ways" exact; anything else is refused, never guessed):
#   - a node is an Org headline: stars, a space, a title.  Its level is its number of stars.
#   - its keys are in a property drawer right under it: ":PROPERTIES:" ... ":END:".
#   - a key is [a-z][a-z0-9-]* .  ":key: value" sets a scalar; ":key+: value" lines (one or more) make a list.
#   - a scalar value is an integer (-?(0|[1-9][0-9]*)), t / nil (true / false), or a string.  A string that would
#     read as anything else, is empty, has a leading/trailing space, or starts with a double quote is written as a
#     JSON string literal ("..."), and read back by JSON's rules.
#   - nesting is a sub-headline (level + 1), never a nested value.  Body text under a headline is ignored on
#     reading and not written: the layer carries keys, not prose.
# JSON SHAPE: a list of nodes, each {"title": str, "props": {key: value}, "children": [node, ...]}.
#
# usage: egad-decl.py to-json FILE.org        print JSON
#        egad-decl.py to-org FILE.json        print Org
#        egad-decl.py roundtrip FILE.org      exit 0 iff org -> json -> org -> json is the identity on the JSON
# exit:  0 ok · 1 refused (the reason on stderr) · 2 usage
import json, re, sys

KEY = re.compile(r'^[a-z][a-z0-9-]*$')
INT = re.compile(r'^-?(0|[1-9][0-9]*)$')
HEAD = re.compile(r'^(\*+) (.*)$')
PROP = re.compile(r'^\s*:([^:\s]+?)(\+?):(?:\s(.*))?$')

class Refused(Exception):
    pass

def read_value(raw):
    if raw.startswith('"'):
        try:
            v = json.loads(raw)
        except ValueError:
            raise Refused(f'not a JSON string literal: {raw!r}')
        if not isinstance(v, str):
            raise Refused(f'quoted value is not a string: {raw!r}')
        return v
    if INT.match(raw):
        return int(raw)
    if raw == 't':
        return True
    if raw == 'nil':
        return False
    return raw

def write_value(v):
    if isinstance(v, bool):
        return 't' if v else 'nil'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        if '\n' in v or '\r' in v:
            raise Refused('a value is one line; put multi-line text in a sub-headline title or the body')
        if (v == '' or INT.match(v) or v in ('t', 'nil') or v != v.strip() or v.startswith('"')):
            return json.dumps(v, ensure_ascii=False)
        return v
    raise Refused(f'value outside the subset: {v!r} ({type(v).__name__})')

def to_json(text):
    roots, stack = [], []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = HEAD.match(lines[i])
        if not m:
            i += 1
            continue
        level, title = len(m.group(1)), m.group(2).rstrip()
        node = {'title': title, 'props': {}, 'children': []}
        i += 1
        if i < len(lines) and lines[i].strip() == ':PROPERTIES:':
            i += 1
            lists = {}
            while i < len(lines) and lines[i].strip() != ':END:':
                pm = PROP.match(lines[i])
                if not pm:
                    raise Refused(f'line {i+1}: not a property line: {lines[i]!r}')
                key, plus, raw = pm.group(1), pm.group(2), (pm.group(3) or '').rstrip('\r')
                if not KEY.match(key):
                    raise Refused(f'line {i+1}: key outside the subset: {key!r}')
                if plus:
                    if key in node['props'] and key not in lists:
                        raise Refused(f'line {i+1}: {key} is both a scalar and a list')
                    lists.setdefault(key, []).append(read_value(raw))
                    node['props'][key] = lists[key]
                else:
                    if key in node['props']:
                        raise Refused(f'line {i+1}: {key} set twice')
                    node['props'][key] = read_value(raw)
                i += 1
            if i >= len(lines):
                raise Refused('a property drawer has no :END:')
            i += 1
        while stack and stack[-1][0] >= level:
            stack.pop()
        if stack:
            if level != stack[-1][0] + 1:
                raise Refused(f'headline {title!r} skips a level')
            stack[-1][1]['children'].append(node)
        else:
            if level != 1:
                raise Refused(f'the first headline {title!r} is not level 1')
            roots.append(node)
        stack.append((level, node))
    return roots

def to_org(nodes, level=1, out=None):
    out = [] if out is None else out
    if not isinstance(nodes, list):
        raise Refused('the top of the JSON is a list of nodes')
    for n in nodes:
        if set(n) - {'title', 'props', 'children'} or not isinstance(n.get('title'), str):
            raise Refused(f'not a node: {n!r}')
        title = n['title']
        if '\n' in title or title != title.strip() or not title:
            raise Refused(f'a title is one non-empty line without edge spaces: {title!r}')
        out.append('*' * level + ' ' + title)
        props = n.get('props', {})
        if props:
            out.append(':PROPERTIES:')
            for k, v in props.items():
                if not KEY.match(k):
                    raise Refused(f'key outside the subset: {k!r}')
                if isinstance(v, list):
                    if not v:
                        raise Refused(f'{k}: an empty list has no Org form in this subset')
                    out.extend(f':{k}+: {write_value(x)}' for x in v)
                else:
                    out.append(f':{k}: {write_value(v)}')
            out.append(':END:')
        to_org(n.get('children', []), level + 1, out)
    return out

def main(argv):
    if len(argv) != 3 or argv[1] not in ('to-json', 'to-org', 'roundtrip'):
        print(__doc__ or 'usage: egad-decl.py to-json|to-org|roundtrip FILE', file=sys.stderr)
        return 2
    with open(argv[2], encoding='utf-8') as f:
        text = f.read()
    try:
        if argv[1] == 'to-json':
            print(json.dumps(to_json(text), ensure_ascii=False, indent=1))
        elif argv[1] == 'to-org':
            print('\n'.join(to_org(json.loads(text))))
        else:
            a = to_json(text)
            b = to_json('\n'.join(to_org(a)))
            if a != b:
                print('NOT IDENTITY: org -> json -> org -> json changed the data', file=sys.stderr)
                return 1
            print(f'identity: {sum(1 for _ in walk(a))} node(s)')
    except Refused as e:
        print(f'REFUSED: {e}', file=sys.stderr)
        return 1
    return 0

def walk(nodes):
    for n in nodes:
        yield n
        yield from walk(n['children'])

if __name__ == '__main__':
    sys.exit(main(sys.argv))
