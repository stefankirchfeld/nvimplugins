---
name: canvas-diagrams
description: "Create and edit structured text diagrams and editable Markdown canvases with the canvas CLI, including architecture, component relationships, and data flow."
---

# Canvas Diagrams

Use the installed `canvas` CLI to express components and relationships as objects,
then render them with the same Lua engine used by the Neovim canvas plugin.
Deliver an editable JSON sidecar and, when useful, a Markdown document referencing it.

## Workflow

- For architecture requests, inspect the relevant source and choose the components
  and relationships the diagram should explain.
- Use `canvas --help` and subcommand `--help` for the available flags. If `canvas`
  is missing, report that the CLI must be installed; do not invent a substitute CLI.
- Create a sidecar such as `docs/architecture.canvas.json`. For an existing diagram,
  inspect its state first and preserve the elements outside the requested changes.
- Add boxes or free text, then connect shape IDs. Commands return JSON containing
  allocated IDs; `--id` can make IDs explicit. Shapes and connectors share the ID space.
- Run `canvas render FILE` and read stdout. Adjust placement and connections based
  on the result. Use `--format json` when you need dimensions or routed path coordinates.
- Run `canvas validate FILE` before delivering. Fix text crossing box borders
  by moving text, enlarging the containing box, or shortening connector labels.
- Generate the requested document and return links to the document and sidecar.

## Compact architecture example

Boxes represent service boundaries; multiline labels keep responsibilities
attached to their service. Label arrows with the data or action they carry.

~~~sh
canvas create architecture.canvas.json
canvas box architecture.canvas.json --id 1 --label 'Client' --kind client --role node --shape br --row 4 --col 1 --width 10 --height 3
canvas box architecture.canvas.json --id 2 --label $'API service\nValidate\nPublish events' --shape br --row 2 --col 23 --width 22 --height 7 --kind service --role container
canvas box architecture.canvas.json --id 3 --label $'Worker service\nHandle events\nStore results' --shape br --row 2 --col 64 --width 22 --height 7 --kind service --role container
canvas connect architecture.canvas.json --from 1 --to 2 --shape ca --label 'requests'
canvas connect architecture.canvas.json --from 2 --to 3 --shape ca --label 'events'
canvas render architecture.canvas.json
canvas validate architecture.canvas.json
canvas document architecture.canvas.json --output architecture.md --title 'Architecture'
~~~

## Diamonds and semantic metadata

Use `bx` for a diamond in the native command/editor syntax, or
`box FILE --outline diamond` in the CLI. Diamonds support multiline labels,
centered as a block and attached during moves. Size uses a compact 13-column by 7-row base and half-step scales: `bx(1, Label)`,
`bx(1.5, Label)`, `bx(2, Label)`, or `bx 2 Label`. A label without a scale
uses size 1. The CLI accepts `--size` and the editor shows `size:`. Scales
resize tip distances: 1 → 13×7, 1.5 → 19×10, 2 → 25×13. Other fractions
are rejected. Labels never change these dimensions. Label overflow is intentional; resize
or change line breaks for readability. Text outside the canvas's top or left
edge is clipped. Existing custom dimensions remain unchanged until a scale
is supplied; their editor shows a blank size and a custom-dimensions hint.
Legacy width/height arguments still work for compatibility. Rounded and double modifiers cannot combine with `bx`.
Connections attach to the four tips; `--force-connect-to-side` works there too.

`--kind` supplies an optional semantic identifier such as `decision`, `service`,
`database`, or `queue`. It does not select an outline. Use `--role node`,
`container`, or `annotation` to state the element's role. `--parent-id ID`
explicitly identifies a containing boundary; the parent must already exist
with `role: container`, and cycles are rejected. Geometry does not infer or
change these relationships. A container move still carries only geometrically
enclosed elements; deleting it keeps children and clears their `parent_id`.
These fields support agent interpretation and future export; no exporter is
implemented yet.

The box editor exposes `kind:`, `role:`, and `parent_id:`. Empty fields clear
metadata. Free-text metadata is set through CLI creation; its pure text editor
preserves it. `inspect FILE --id ID` reports `element_type` separately from
semantic `kind`, and adds `capabilities` with `multiline_labels` and
`fit_to_labels`. Capabilities live in outline definitions, not repeated JSON
properties. Rectangles fit labels; diamonds do not. Validation allows a
diamond's own label overflow but still reports text crossing other outlines.

~~~sh
canvas create decision.canvas.json
canvas box decision.canvas.json --id 1 --shape bx --kind decision --label $'Approved?\nCheck policy' --row 8 --col 28 --size 2
canvas box decision.canvas.json --id 2 --kind service --label 'Continue' --row 12 --col 65 --width 16 --height 5
canvas box decision.canvas.json --id 3 --kind service --label 'Retry' --row 26 --col 31 --width 19 --height 3
canvas connect decision.canvas.json --from 1 --to 2 --label 'yes' --force-connect-to-side left
canvas connect decision.canvas.json --from 1 --to 3 --label 'no' --force-connect-to-side top
canvas render decision.canvas.json
canvas validate decision.canvas.json
~~~

## Editing and layout

Coordinates are 1-based rows and columns relative to the canvas. `--row` and
`--col` place the top-left corner. Rectangle dimensions are minimums and grow to fit
the label. Use explicit height and width when a compact layout matters. Labels
are literal strings; boxes and `text` support newlines, while connector labels
are single-line. Rectangles fit the longest line and all label rows, preserving
indentation and blank lines. Use Bash/Zsh ANSI-C quoting such as
`--label $'Service\n  Validate\n  Store'` for multiline content. Formatting is
plain text. Colors accept Neovim color names or `#RRGGBB`.

In Vim's box editor, enter multiple lines below `label:`. `:w` applies and
resizes while keeping the editor open; `:wq` applies and closes; `:q` discards
unapplied edits. Saving the main buffer commits the scene.
An open editor follows shapes and connectors under the diagram cursor while
its draft is clean. Unapplied edits pin the current target until applied or
discarded; following does not move focus away from the diagram.

`move FILE ID --row ROW --col COL` moves a shape. Moving a box also moves every
box and free-text element whose complete rectangular bounds are inside its
bounds before the move (including elements touching the border). Nested elements
move once by the same offset; partial overlaps stay put. Containment is detected
on every move, without stored groups. Free text does not act as a container.
Use a larger empty box with a free-text heading inside for a service containing
separate component boxes; move the outer box to carry the contents. In Vim,
select the outer box on its border or empty interior and use `m` and movement keys.

Connections reroute on render. Enclosed manual routes translate with the box.
A free endpoint translates when it is inside the moved box and its source
shape moves too; external endpoints stay fixed. The move result lists
`moved_shapes`. These rules apply in the CLI and both Vim buffer modes.

`validate FILE` checks routing and text spans crossing any box border, including
free text, box labels, and connector labels. It prints `{valid, issues}` JSON
and exits 1 for border overflow. Issues include element ID, box ID, and text
position. Validation is read-only; it does not resize boxes, move text, or write
the sidecar. `render FILE --format json` includes the same `issues` array.
Attached rectangle labels grow their own box automatically; diamonds allow overflow. This check detects border
collisions, not all visual overlaps; still read the rendered diagram.

`inspect FILE` prints the scene, and `inspect FILE --id ID` prints one
element. `delete FILE ID` removes an element; deleting a shape also removes its
attached connectors. Inspect those connectors before replacing a shape so you
can re-create the affected relationships. The current CLI has no `update` command.

Routing style changes path costs. For a specific target side, use
`--force-connect-to-side left` (or `right`, `top`, `bottom`). The router must reach
that side from outside the target; `--route direct` alone does not select a side.

## Document integration

`document` writes an entire Markdown file. To add a canvas to an existing document,
preserve its prose and insert or update a `canvas` fence with a relative `file=`
reference to the sidecar, using `render` for the contents. Use `document --force`
only when replacing the whole output document is intended; `create --force`
replaces the whole scene.

The Vim buffer is the view and editing surface, and keeps rendered text when
canvas mode ends. Users open the fence with `:Canvas`. Vim commits the sidecar
when the main document is saved. CLI operations write the sidecar immediately
and do not refresh an already active Vim canvas; pending Vim changes need saving
or discarding before reloading external edits.

Multiple canvas fences in one Markdown document can use separate sidecars.
Both backtick and tilde fences are supported, with three or more delimiters.
Users place the cursor inside a fence or on its tag and run `:Canvas`; invoking
it on another block switches scenes while retaining pending edits. A main-buffer
save commits all visited canvases, and `:edit!` restores all their saved scenes.

For rendered-only documents, omit the `file=` attribute and keep states in
`~/.canvas-nvim/canvases/`. Implicit paths derive from the document path and
canvas order (base, `_2`, `_3`, ...); keep that order stable. The rendered text
can be committed without local JSON or home-path references.
