import * as path from 'path';
import { workspace, ExtensionContext } from 'vscode';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  Executable
} from 'vscode-languageclient/node';

let client: LanguageClient;

export function activate(context: ExtensionContext) {
  // Executable options to spawn `ttql lsp`
  const serverExecutable: Executable = {
    command: 'ttql',
    args: ['lsp'],
    options: {
      cwd: workspace.workspaceFolders?.[0]?.uri.fsPath
    }
  };

  const serverOptions: ServerOptions = {
    run: serverExecutable,
    debug: serverExecutable
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'ttql' }],
    synchronize: {
      fileEvents: workspace.createFileSystemWatcher('**/*.ttql')
    }
  };

  client = new LanguageClient(
    'ttqlLsp',
    'TTQL Language Server',
    serverOptions,
    clientOptions
  );

  client.start();
}

export function deactivate(): Thenable<void> | undefined {
  if (!client) {
    return undefined;
  }
  return client.stop();
}
