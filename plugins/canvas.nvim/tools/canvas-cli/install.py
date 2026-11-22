#!/usr/bin/env python3
"""Link the local CLI and one shared skill into user-level harness locations."""

import argparse
import json
import os
from pathlib import Path
import shutil
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, default=Path.home() / '.local', help='CLI install prefix (default: ~/.local)')
    parser.add_argument('--targets', nargs='+', choices=('codex', 'claude'), default=['codex', 'claude'])
    parser.add_argument('--codex-skills-dir', type=Path, default=Path.home() / '.agents' / 'skills')
    parser.add_argument('--claude-skills-dir', type=Path, default=Path.home() / '.claude' / 'skills')
    parser.add_argument('--dry-run', action='store_true', help='Print the install plan without writing files')
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    cli = root / 'tools' / 'canvas-cli' / 'bin' / 'canvas'
    skill = root / 'skills' / 'canvas-diagrams'
    required = (cli, skill / 'SKILL.md', root / 'tools/canvas-cli/engine.lua', root / 'lua/canvas/scene.lua')
    if not all(path.is_file() for path in required):
        parser.error('the checkout must contain the CLI, Lua engine, and canvas-diagrams skill')
    if shutil.which(os.environ.get('CANVAS_NVIM', 'nvim')) is None:
        parser.error('Neovim is required; install nvim or set CANVAS_NVIM')

    links = [(args.prefix.expanduser().absolute() / 'bin' / 'canvas', cli)]
    directories = {'codex': args.codex_skills_dir, 'claude': args.claude_skills_dir}
    for target in dict.fromkeys(args.targets):
        links.append((directories[target].expanduser().absolute() / 'canvas-diagrams', skill))

    # Check every destination before creating any directories or links.
    plan = []
    for destination, source in links:
        exists = os.path.lexists(destination)
        same = destination.is_symlink() and destination.resolve() == source.resolve()
        if exists and not same:
            parser.error(f'refusing to replace existing path: {destination}')
        plan.append({'destination': str(destination), 'source': str(source), 'action': 'unchanged' if same else 'link'})

    if not args.dry_run:
        for entry in plan:
            if entry['action'] == 'link':
                destination = Path(entry['destination'])
                if destination.is_symlink() and destination.resolve() == Path(entry['source']).resolve():
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.symlink_to(entry['source'], target_is_directory=Path(entry['source']).is_dir())
    print(json.dumps({'dry_run': args.dry_run, 'links': plan}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except OSError as error:
        print(f'install: {error}', file=sys.stderr)
        sys.exit(1)
