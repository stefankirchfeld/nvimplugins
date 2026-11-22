# Canvas architecture

The Vim UI edits in-memory shapes and connectors. The CLI writes their JSON sidecar and can load the same models into the headless rendering engine. Persistence connects state to the sidecar; Grid builds and routes the scene into diagram text.

```canvas file=architecture.canvas.json

  ╭────────────────────────────╮                 ╭────────────────────────────╮
  │                            │                 │                            │
  │       Vim canvas UI        │render───────────┤         Agent CLI          │
  │                            ││                │                            │
  ╰──────────────┬─────────────╯│                ╰──────────────┬─────────────╯
                 │              │                               │
                 │              │                               │
               edit             │                             write
                 │              │                               │
                 │              │                               │
  ╭──────────────↓─────────────╮│                ╔══════════════↓═════════════╗
  │                            ├┘                ║                            ║
  │ State + Shape/Conn models  ←────load/save────→        JSON sidecar        ║
  │                            │                 ║                            ║
  ╰──────────────┬─────────────╯                 ╚════════════════════════════╝
                 │
                 │
               build
                 │
                 │
  ╭──────────────↓─────────────╮                 ╭────────────────────────────╮
  │                            │                 │                            │
  │  Grid + Router + Renderer  ├─────output──────→        Diagram text        │
  │                            │                 │                            │
  ╰────────────────────────────╯                 ╰────────────────────────────╯
```
