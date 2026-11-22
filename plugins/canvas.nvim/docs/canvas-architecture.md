# Canvas architecture

The Vim buffer is the canvas: the view, the keyboard working space, and the final text document. The outer return arrow carries rendered text back into that same buffer. The canvas occupies either the full buffer or a canvas fence inside a Markdown document.

When canvas mode ends, its keymaps and overlays are removed and the rendered text stays in the buffer. Writing with :w exits canvas mode and saves that text as part of the document. The JSON sidecar preserves the structured, editable scene.

- **Vim UI adapters:** init.lua, commands.lua, form.lua, and indicator.lua handle input, property-edit buffers, and mode feedback.
- **Agent CLI and headless bridge:** Python handles arguments and file I/O; engine.lua invokes the shared Lua API. CLI output is text on stdout or a generated Markdown document.
- **Shared scene API:** scene.lua owns creation, editing, validation, dimensions, modifiers, IDs, deletion, and serialization.
- **State and models:** state.lua holds buffer state; Shape and Conn represent the diagram elements.
- **Rendering and persistence:** Grid builds the scene, Router finds connector paths, and Renderer draws glyphs. Grid.flush writes the Vim canvas region. The shared codec encodes and decodes the models; persist.lua and the CLI perform JSON file reads and writes.

Arrows show data flow rather than a strict function-call graph. To edit this diagram, place the cursor inside the canvas block and run :Canvas.

The return connection is pinned to the buffer's left side (to_side: left in Vim, forceConnectToSide in JSON), keeping it distinct from the outgoing keyboard connection.

```canvas file=canvas-architecture.canvas.json

   ╭─────────────────────────────╮              ╭───────────────────────────╮
   │                             │              │                           │
  ┌→  Vim buffer (edit + view)   │              │         Agent CLI         │
  ││                             │              │                           │
  │╰──────────────┬──────────────╯              ╰─────────────┬─────────────╯
  │               │                                           │
  │               │                                           │
  │             keys                                      requests
  │               │                                           │
  │               │                                           │
  │╭──────────────↓──────────────╮              ╭─────────────↓─────────────╮
  ││       Vim UI adapters       ├────┐┌────────┤    Headless Lua bridge    │
  │╰─────────────────────────────╯    ││        ╰───────────────────────────╯
  │                                   ││
  │                                   ││
  │                                   ││
  │                                   ││
  │                                   ││
  │                                   ││
  │                                   ││
  │                     ╭─────────────↓┴────────────╮
  │                     │ Scene API (shared rules)  │
  │                     ╰─────────────┬─────────────╯
  │                                   │
  │                                   │
  │                                   │
  │                                 apply
  │                                   │
  │                                   │
  │                                   │
  │                     ╭─────────────↓─────────────╮         ╔══════════════╗
  │                     │ State + Shape/Conn models ←──codec──→ JSON sidecar ║
  │                     ╰─────────────┬─────────────╯         ╚══════════════╝
  └─────────────────────────────────┐ │
                                    │ │
                                    │ │
                                    │ │
                                    │ │
                                    │ │
                                    │ │
                        ╭───────────┴─↓─────────────╮         ╭──────────────╮
                        │ Grid + Router + Renderer  ├──text───→  CLI output  │
                        ╰───────────────────────────╯         ╰──────────────╯
```
