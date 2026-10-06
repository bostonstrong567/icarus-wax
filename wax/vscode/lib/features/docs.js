'use strict';
// Open Documentation, and a link to the matching docs page when a Wax name is hovered in a mod
const docs = require('../docs');

function register(app) {
  const { vscode } = app;
  const base = () => vscode.workspace.getConfiguration('wax').get('docsUrl', '');
  const markdown = ({ title, url }) => `Wax docs: [${title}](${url})`;

  // A link into the docs for "page" or "page#heading": { title, url, markdown }.
  app.docs = (place) => {
    const link = docs.link(place, base());
    return { ...link, markdown: markdown(link) };
  };

  app.command('wax.openDocs', async () => {
    await vscode.env.openExternal(vscode.Uri.parse(docs.site(base())));
  });

  const hover = {
    provideHover(document, position) {
      if (document.uri.scheme !== 'file' || !app.modOf(document.uri.fsPath)) return undefined;
      const topic = docs.topicAt(document.lineAt(position.line).text, position.character, base());
      return topic ? new vscode.Hover(new vscode.MarkdownString(markdown(topic))) : undefined;
    },
  };

  app.context.subscriptions.push(vscode.languages.registerHoverProvider({ language: 'lua', scheme: 'file' }, hover));
}

module.exports = { register };
