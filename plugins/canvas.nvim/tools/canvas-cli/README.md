# Canvas CLI

Create editable canvas diagrams from a shell or coding agent. The CLI writes the
same JSON sidecars as the Vim plugin. Rendering runs the existing Shape, Conn,
Grid, and router modules in headless Neovim and prints the resulting diagram.

Requires Python 3.8+ and Neovim 0.9+ for all operational commands.
No Python packages are required. Run `tools/canvas-cli/bin/canvas` from the repo,
or add `tools/canvas-cli/bin` to PATH to use `canvas`. Set `CANVAS_NVIM` to a
Neovim executable path if `nvim` is not on PATH.

## Install the CLI and agent skill

From this checkout:

~~~sh
python3 tools/canvas-cli/install.py --dry-run
python3 tools/canvas-cli/install.py
~~~

The installer links `~/.local/bin/canvas` to the CLI and installs the same
[canvas-diagrams skill](../../skills/canvas-diagrams/SKILL.md) for both harnesses:

| Harness | Default skill location | Explicit invocation |
| --- | --- | --- |
| Codex | `~/.agents/skills/canvas-diagrams` | `$canvas-diagrams` |
| Claude Code | `~/.claude/skills/canvas-diagrams` | `/canvas-diagrams` |

Both skill folders link to the one source in this repository. Updates here apply
to both installations; the checkout must remain in place. The shared `SKILL.md`
uses standard name/description frontmatter, so no separate skill body is needed.
`agents/openai.yaml` supplies optional Codex UI metadata and is ignored by Claude.
Implicit selection is enabled by default in both clients.

Use `--targets codex` or `--targets claude` to install just one. `--prefix`,
`--codex-skills-dir`, and `--claude-skills-dir` override the destinations. Older
Codex setups using `~/.codex/skills` can pass
`--codex-skills-dir ~/.codex/skills`. The installer does not replace existing
unrelated files or skills, and it makes no shell profile changes. Ensure the
prefix's `bin` directory is on PATH.

The skill is available in Codex on the next turn; if a client does not refresh,
start a new session. Ask either agent to create an editable architecture diagram,
or invoke the skill explicitly. For public distribution, ship the CLI/Lua engine
and the skill together; harness-specific plugin packaging can be added later.

Discovery documentation: [Codex](https://developers.openai.com/codex/skills),
[Claude Code](https://code.claude.com/docs/en/skills).

## Shared implementation

The [Lua scene API](../../lua/canvas/scene.lua) owns shape creation and updates,
validation, dimensions, modifiers, IDs, deletion, and state serialization. Both
Vim's drawing commands and property editor call it directly. The Python CLI only
parses arguments, sends structured requests to the headless Lua bridge, and handles
file I/O and document formatting. Drawing and routing also use the existing Lua
engine. New canvas rules belong in Lua; interface controls and flags remain local
to each interface.

## Agent workflow

Inspect the source first, choose a few architectural components, place boxes,
connect their returned IDs, then render and adjust the layout. Labels are literal
strings, so punctuation does not become part of the command syntax.

~~~sh
canvas create architecture.canvas.json
canvas box architecture.canvas.json --id 1 --label 'API' --shape br --row 1 --col 1
canvas box architecture.canvas.json --id 2 --label 'Database' --shape br --row 1 --col 35
canvas connect architecture.canvas.json --from 1 --to 2 --label 'queries'
canvas render architecture.canvas.json
canvas document architecture.canvas.json --output architecture.md --title 'Architecture'
~~~

`box` and `connect` return JSON with an `id`. Omit `--id` to allocate one
automatically. IDs are shared across shapes and connectors and remain stable
when shapes move. State-changing commands print JSON to stdout; errors go to
stderr and return a nonzero exit status. Failed validation leaves the file intact.
Each write replaces the sidecar atomically.

`render` prints only the diagram to stdout. For programmatic inspection:

~~~sh
canvas inspect architecture.canvas.json
canvas inspect architecture.canvas.json --id 1
canvas render architecture.canvas.json --format json
~~~

JSON rendering returns `lines`, `rows`, `columns`, and routed connector `paths`,
keyed by ID. It reports an error if a connector cannot be routed. Rendering is a
read-only snapshot of the file and uses no running Vim session or user config.
Plain text has box-drawing characters; colors stay in the sidecar for Vim.

## Commands

| Command | Purpose |
| --- | --- |
| `create FILE` | Create an empty sidecar; `--force` replaces an existing file. |
| `box FILE` | Add a box: `--label`, `--row`, `--col`, optional `--width`, `--height`, `--shape`, `--id`, colors. |
| `text FILE` | Add free text: `--label`, `--row`, `--col`, optional `--id` and colors. Newlines create multiple text rows. |
| `connect FILE` | `--from ID` and either `--to ID` or `--at ROW COL`; optional `--label`, `--shape`, `--route`, `--id`. |
| `move FILE ID` | Set `--row` and `--col`; boxes carry fully enclosed elements. Returns `moved_shapes`. |
| `delete FILE ID` | Remove a shape or connector. Removing a shape also removes its attached connectors. |
| `inspect FILE` | Print state JSON, or one element with `--id ID`. |
| `render FILE` | Print the diagram; `--format json` returns lines, dimensions, paths, and overflow `issues`. |
| `validate FILE` | Read-only routing and text-border checks. Prints `{valid, issues}` JSON; exits 1 for overflow. |
| `document FILE` | Write a new Markdown document: `--output PATH`, optional `--title`, `--description`, `--force`. |

Every command accepts `--help`. Coordinates are 1-based, zone-relative rows and
columns. `--row` and `--col` always locate the top-left corner. Rectangle width and height
are minimums: a rectangle grows to fit its label; diamond dimensions are fixed. The default box is 20 columns by 10
rows, shared with Vim drawing commands. Boxes and free text support multiline
labels; connector labels remain single-line. Rectangles grow to fit the longest line
and all label rows. The label is centered as a block, preserving indentation
and blank lines. Formatting is plain text.

In the box editor, enter the label on the lines below `label:`. `:w` applies
the label and adjusts rectangle size while keeping the editor open. Diamonds keep their dimensions. `:wq` applies
and closes; `:q` discards unapplied changes. Save the main canvas buffer to
persist the result.

While the edit split is open, moving the cursor over a shape or connector in
the active diagram updates the same editor without taking focus. Empty space
keeps the last target. Unapplied edits pin the draft to its current target;
apply with `:w` to resume following, or close with `:q` to discard the draft.
Following works with horizontal and vertical editors, including diamonds and
the pure free-text editor. Editors remain scoped to their original canvas.

Use `canvas change-persistence architecture.md` to move every canvas in an
existing Markdown document to the default home storage. Use
`canvas change-persistence architecture.md --mode colocated` for the reverse.

Default mode uses `~/.canvas-nvim/canvases/` and Vim's document-path slug and
canvas-order suffixes, and removes `file=` from the fences. Colocated mode
writes `architecture.canvas.json`, `architecture_2.canvas.json`, etc. beside
the document and adds relative references. Rendered diagrams and prose are
preserved, including fence style and line endings.

Every source and destination is checked before writing. Different existing
destination states require `--force`; identical states are accepted. Old source
files are removed after writing the states and updating the document. Use
`--keep-source` when other documents share those states. Save or discard
pending Vim canvas edits before running the command, then reload the document.

A Markdown document can contain multiple canvas fences with separate `file=`
sidecars. Backtick and tilde fences are supported, including longer delimiters
and up to three leading spaces. Put the cursor inside a block or on its fence tag and run `:Canvas`
to edit that block. Running `:Canvas` on another block switches to it and keeps
pending edits in the previous block. Running it on the active block exits mode.
Saving the main document commits all visited canvases; `:edit!` restores their
saved scenes together. Fences without a `file=` attribute receive distinct
home-storage paths based on the document path and canvas order: base filename,
then `_2`, `_3`, and so on. Keep that order stable for local-state diagrams;
no path attribute is inserted.

In Bash or Zsh, pass literal newlines using ANSI-C quoting:

```sh
canvas box architecture.canvas.json --label $'Service\n\n  • Validate\n  • Store' --row 1 --col 1 --width 3 --height 1
```

Box tokens use the existing syntax (plus `bx` for diamonds): `b` (single), `br` (rounded), `bd` (double),
`brd` (rounded double). The `c` or `i` box modifiers store a centered anchor
for subsequent Vim editing; placement still uses top-left CLI coordinates.
Connector tokens include `c` (line), `ca` (arrow), `cb` (both arrows), `cad`
(dashed arrow). Connectors default to `ca`. Routing choices are `default`,
`direct`, `lazy`, and `avoid`.

Shape colors use `--fg '#89b4fa'`, `--bg '#1e1e2e'`, and
`--text-color '#cdd6f4'`. Colors use the same validation as Vim: six-digit hex colors and Neovim color names
are supported.

## Diamond outlines and semantic metadata

Use `--outline diamond` or `--shape bx` to draw a diamond. In Vim's draw prompt,
enter `bx(1.5, Approved?)`; the box editor uses `shape: bx`. Diamonds support
multiline labels and preserve relative indentation, but never grow to fit them.
Diamonds use a fixed ratio with half-step scales: `--size 1` gives 13×7,
`--size 1.5` gives 19×10, and `--size 2` gives 25×13. Size 1 is the default;
scales below 1 and other fractions such as 1.3 are rejected. Scaling multiplies
the tip-to-tip distances and adds one cell. The editor shows `size:` instead
of independent width/height fields. Labels remain
centered and move with the shape; overflow is allowed. Text extending past the
top or left canvas edge is clipped. Rounded/double diamond modifiers are rejected.
Existing custom diamonds retain their dimensions when reopened, edited, or
moved. Their editor shows a blank `size:` and a dimensions hint; enter a scale
to adopt the fixed ratio, or leave it blank to preserve the custom size. Legacy
width/height flags and two-number native commands remain accepted for compatibility.
Do not combine `--size` with `--width` or `--height`.
Connectors attach to the four visible tips, including forced-side connections.
Hit tests and geometric containment follow the diamond outline rather than its
empty bounding-box corners.

Shapes accept optional `--kind`, `--role`, and `--parent-id` metadata. `kind` is
an extensible identifier (for example `decision`, `service`, `database`, `queue`)
independent of `outline`. `role` is `node`, `container`, or `annotation`.
`parent_id` references an existing shape with `role: container`; cycles are
rejected. Semantic relationships need not match geometric enclosure and do not
change drawing or movement. Deleting a parent preserves children and clears
their parent IDs. Metadata is intended for agent understanding and future
export; this CLI does not export Mermaid or PlantUML yet.

The box editor has `kind:`, `role:`, and `parent_id:` fields; leave them empty to
clear them. Free-text editing retains metadata set through CLI creation.
`inspect FILE --id ID` returns `element_type` (`box`, `text`, `connector`), the
stored semantic `kind` when supplied, and shape `capabilities`:
`multiline_labels` and `fit_to_labels`. Capabilities belong to Lua outline
definitions and are not persisted redundantly in each JSON element.

~~~sh
canvas box architecture.canvas.json --outline diamond --kind decision --role node --label $'Approved?\nCheck policy' --row 8 --col 28 --size 1.5
~~~

## Move a container box

Moving a box carries every box and free-text shape whose complete bounds are
inside its bounds before the move, including shapes touching the border. Each
enclosed shape moves once by the same offset, including nested contents.
Partially overlapping shapes stay put. Containment is detected on each move;
no group IDs or membership are stored. Moving free text only moves that text.
The JSON result lists the IDs in `moved_shapes`.

Automatic connectors reroute on render. Fully enclosed manual waypoints move
by the same offset. Free endpoints move if they are inside the moved box and
their source shape moves; external endpoints stay fixed.

These rules also apply to Vim's `m` move mode in full-buffer and inline Markdown
canvases. Select the container on its border or empty interior; enclosed shapes
can still be moved individually.

## Validate text placement

Run `canvas validate FILE` to check routing and text crossing box borders.
It checks box labels, free text, and connector labels using display-column
widths. Attached rectangle labels automatically grow their own box, but can still
collide with another box. Validation reports collisions without altering state.

A diamond's own label may cross its outline without an overflow issue. Text
crossing another diamond or rectangle is still reported.

The report is JSON with `valid` and `issues`. Each overflow issue has
`code: text_crosses_border`, element `id` and `kind`, `box_id`, label `line`,
and canvas `row`, `col`, and inclusive `end_col`. A clean report exits 0;
overflow exits 1. Invalid state or unroutable connectors also exit 1 with an
error on stderr. `render --format json` includes the same overflow issues while
still producing the diagram. Plain rendering continues to print diagram text.

Move overflowing free text, increase the container's size, or shorten connector
labels and leave more room between boxes. Validation checks border collisions;
it does not detect every overlap between labels or shapes.

## Choose a target side

The optional JSON property `forceConnectToSide` selects `left`, `right`, `top`,
or `bottom`. The connector attaches to that side's midpoint and approaches it
from outside the box. If it cannot reach that side, rendering reports no route;
it does not choose another side.

~~~sh
canvas connect architecture.canvas.json --from 2 --to 1 --force-connect-to-side left
~~~

In Vim's connector editor, set `to_side: left`. A blank `to_side:` restores
automatic attachment. An override requires a target shape and an automatic
routing style; it applies to `default`, `direct`, `lazy`, and `avoid` routes.
It is preserved when saving from either interface.

## Open the document in Vim

`document` writes the rendered diagram inside a `canvas` code fence with a
relative `file=` attribute pointing to the sidecar. Paths containing spaces or
quotes are JSON-quoted. Open the Markdown file, place the cursor inside the
fence, and run `:Canvas`. The plugin loads that sidecar and edits the diagram
normally; edits saved by Vim are readable by the CLI.

## Saving and discarding in Vim

Canvas keeps its working scene and one snapshot of the last saved scene.
Exiting canvas mode with `q` keeps the changes in the modified buffer and does
not write the sidecar. A successful `:w` of the main document saves the sidecar
and advances the snapshot. Writing a property editor only applies edits to the
main buffer; save the main document to commit them.

`:edit!` discards pending buffer and scene changes together. A full buffer
revert to the saved text also restores the snapshot. This MVP does not keep
intermediate scene versions for partial undo or redo. Save or discard the
current canvas before switching to another canvas in the same document.
Exiting canvas mode preserves the diagram's placement and whitespace.

CLI writes do not refresh an already active canvas in a separate Vim session.
Save or discard pending edits, then reopen canvas mode to load external state changes. Regenerate a Markdown
snapshot with `document --force`, or let Vim load and render the changed state.

The [example](examples/architecture.md) diagrams this plugin's canvas components
and has an accompanying editable sidecar.

## Verification

~~~sh
python3 -B -m unittest discover -s tools/canvas-cli/tests -v
~~~

Tests exercise the real CLI and rendering engine, invalid writes, routed paths,
literal and multiline labels, Vim/CLI parity, repeated editor saves and move
controls, legacy loading, and a CLI → Markdown → Vim → CLI round trip.
