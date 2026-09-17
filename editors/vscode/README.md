# TTQL Language Extension for VS Code & Antigravity IDE

Provides syntax highlighting, inline diagnostics, and Language Server Protocol (LSP) support for TableTalk Query Language scripts (`.ttql`).

---

## Features

- **Syntax Highlighting**: TextMate grammar covering pipeline methods (`from`, `select`, `where`, `innerJoin`, `leftJoin`, `groupBy`, `having`, `orderBy`, `limit`, `offset`), aggregate builtins (`count`, `sum`, `avg`, `min`, `max`), constants, operators, and comments.
- **LSP Diagnostics**: Inline syntax validation and error reporting powered by the `ttql lsp` JSON-RPC server.
- **Read-Only Safety Warnings**: Highlights forbidden mutation keywords (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`).

---

## Building from Source

The extension client is written in TypeScript and communicates with `ttql lsp` via `vscode-languageclient`:

```bash
cd editors/vscode
npm install
npm run compile
```

This compiles TypeScript source into `out/extension.js`.

---

## Local Installation

To install the extension manually into your local editor extensions folder:

### Windows (PowerShell)

```powershell
$target = "C:\Users\$env:USERNAME\.antigravity\extensions\tabletalk-io.vscode-ttql-1.0.0"
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -Path package.json, language-configuration.json -Destination $target
Copy-Item -Path syntaxes, out, node_modules -Destination $target -Recurse -Force
```

*(For standard VS Code, replace `.antigravity` with `.vscode`)*

### Linux / macOS (Bash)

```bash
TARGET="$HOME/.antigravity/extensions/tabletalk-io.vscode-ttql-1.0.0"
mkdir -p "$TARGET"
cp package.json language-configuration.json "$TARGET"
cp -r syntaxes out node_modules "$TARGET"
```

After copying, reload the editor window (`Developer: Reload Window` from the Command Palette).

---

## File Association

To associate `.ttql` files with the TTQL language mode, add the following to `.vscode/settings.json`:

```json
{
  "files.associations": {
    "*.ttql": "ttql"
  }
}
```
