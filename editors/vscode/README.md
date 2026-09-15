# TTQL Language Extension for VS Code & Antigravity IDE

Provides official **syntax highlighting**, **inline diagnostics**, and **Language Server Protocol (LSP)** support for **TableTalk Query Language (TTQL)** scripts (`.ttql`).

---

## 🌟 Key Features

- 🎨 **TextMate Syntax Highlighting**: Colorizes keywords (`select`, `declare asyncRun`, `where`, `orderBy`, `limit`, `is`), database engine constructors (`PostgreSql`, `MySql`, `Mongo`, `Redis`, `Sqlite`, `ClickHouse`), connection variables, operators, and multi-line comments.
- ⚡ **Real-Time LSP Diagnostics**: Live red squiggly error underlines powered by the `ttql lsp` background service communicating over JSON-RPC 2.0 `stdio`.
- 🛡️ **Read-Only Safety Invariant Enforcement**: Flags forbidden mutation keywords (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`) in real time before network execution.

---

## 🛠️ Building & Compiling from Source

The extension client is written in TypeScript and uses `vscode-languageclient` to communicate with the `ttql lsp` engine:

```bash
# From editors/vscode directory:
npm install
npm run compile
```

This generates `out/extension.js` and `out/extension.js.map`.

---

## 🚀 Local Installation (Antigravity IDE & VS Code)

To deploy the compiled extension directly into your local IDE extensions folder:

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

After deploying, reload your editor window:
Press `Ctrl+Shift+P` (or `Cmd+Shift+P` on macOS) $\rightarrow$ select **`Developer: Reload Window`**.

---

## ⚙️ Workspace Configuration

To ensure `.ttql` files automatically bind to the TTQL language mode, ensure your `.vscode/settings.json` contains:

```json
{
  "files.associations": {
    "*.ttql": "ttql"
  }
}
```
