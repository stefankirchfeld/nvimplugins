# canvas.nvim

Editable text diagrams in Neovim: boxes, diamonds, connectors, multiline labels, persistent scenes and Markdown canvas fences. No SAP modules are required.

Use this directory as a standalone runtime root:

~~~lua
{ dir = vim.fn.expand('~/src/stefankirchfeld/nvimplugins/plugins/canvas.nvim'),
  name = 'canvas.nvim', lazy = false }
~~~

Run :Canvas inside a Markdown canvas fence or an ordinary buffer. The Lua namespace is canvas (formerly das.canvas). Existing sidecar JSON and document formats remain compatible.

[CLI reference](tools/canvas-cli/README.md), [architecture](docs/canvas-architecture.md), and [agent skill](skills/canvas-diagrams/SKILL.md).

Optional CLI/skill installation:

~~~sh
python3 tools/canvas-cli/install.py --dry-run
python3 tools/canvas-cli/install.py
~~~

Requires Neovim; the CLI additionally requires Python 3, without third-party packages.

~~~sh
python3 -B -m unittest discover -s tools/canvas-cli/tests -v
~~~
