"""Move Markdown canvas states between explicit sidecars and home storage."""
import json
import os
from pathlib import Path
import re


def default_path(document, index):
    # Match lua/canvas/persist.lua, including byte-based slug truncation.
    slug = re.sub(r'[/\\:%]', '_', str(document)).encode('utf-8')[-180:]
    suffix = '' if index == 1 else f'_{index}'
    name = os.fsdecode(slug) + suffix + '.canvas.json'
    return Path.home() / '.canvas-nvim/canvases' / name


def canvas_fences(lines):
    opened = None
    for row, line in enumerate(lines):
        match = re.match(r'^( {0,3})(`{3,}|~{3,})(.*)$', line.rstrip('\r\n'))
        if not match:
            continue
        indent, marker, info = match.groups()
        info = info.strip()
        if opened:
            if marker[0] == opened[2][0] and len(marker) >= len(opened[2]) and not info:
                if re.match(r'^canvas(?:\s|$)', opened[3]):
                    yield opened
                opened = None
        else:
            opened = (row, indent, marker, info)


def change_persistence(document, mode, force, keep_source, write, error):
    with document.open(encoding='utf-8', newline='') as stream:
        original = stream.read()
    lines = original.splitlines(keepends=True)
    moves = []
    for index, (row, indent, marker, info) in enumerate(canvas_fences(lines), 1):
        attr = re.match(r'^canvas\s+file=(.*)$', info)
        if info != 'canvas' and not attr:
            raise error(f'unsupported canvas attributes on line {row + 1}')
        if attr:
            value = attr[1].strip()
            if value.startswith(chr(34)):
                value = json.loads(value)
            elif any(ch.isspace() for ch in value):
                raise error(f'quote the sidecar path on line {row + 1}')
            if not isinstance(value, str) or not value:
                raise error(f'invalid sidecar path on line {row + 1}')
            source = Path(value).expanduser()
            if not source.is_absolute():
                source = document.parent / source
            source = source.resolve()
        else:
            source = default_path(document, index)
        source = source.resolve()
        destination = (default_path(document, index) if mode == 'default' else
                       document.with_name(document.stem + ('' if index == 1 else f'_{index}') + '.canvas.json'))
        destination = destination.resolve()
        if source == document or destination == document:
            raise error('canvas state must differ from the Markdown document')
        contents = source.read_text(encoding='utf-8')
        state = json.loads(contents)
        if not isinstance(state, dict) or not isinstance(state.get('shapes'), dict) or not isinstance(state.get('conns'), dict):
            raise error(f'invalid canvas state: {source}')
        if destination != source and destination.exists() and not force:
            if json.loads(destination.read_text(encoding='utf-8')) != state:
                raise error(f'{destination} contains a different state; use --force to replace it')
        ending = '\r\n' if lines[row].endswith('\r\n') else '\n' if lines[row].endswith('\n') else ''
        tag = 'canvas'
        if mode == 'colocated':
            relative = os.path.relpath(destination, document.parent)
            attribute = json.dumps(relative, ensure_ascii=False) if any(ch.isspace() or ch == chr(34) for ch in relative) else relative
            tag += ' file=' + attribute
        lines[row] = indent + marker + tag + ending
        moves.append((source, destination, contents))
    if not moves:
        raise error('document has no complete canvas fences')
    destinations = {dst for _, dst, _ in moves}
    # Preflight all inputs/conflicts before writing anything. Keep source states
    # until the document points to the successfully written destinations.
    for source, destination, contents in moves:
        if source != destination:
            write(destination, contents)
    updated = ''.join(lines)
    if updated != original:
        write(document, updated)
    if not keep_source:
        for source in {src for src, _, _ in moves} - destinations:
            source.unlink()
    return {'file': str(document), 'mode': mode, 'canvases': [
        {'source': str(src), 'destination': str(dst)} for src, dst, _ in moves]}
