// Stands in for the GitHub release API in Test-WaxRelease.ps1. Usage: node serve.mjs <zip> <port file> <current version>
import http from 'node:http';
import fs from 'node:fs';

const [zipPath, portFile, current] = process.argv.slice(2);

const server = http.createServer((req, res) => {
  const base = `http://127.0.0.1:${server.address().port}`;
  const json = (code, body) => {
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(JSON.stringify(body));
  };
  const zipAsset = (url) => [
    { name: 'wax-icarus-9.9.9.vsix', browser_download_url: `${base}/other` },
    { name: 'Wax-9.9.9.zip', browser_download_url: url },
  ];
  switch (req.url) {
    case '/none':
      return json(404, { message: 'Not Found', status: '404' });
    case '/limit':
      return json(403, { message: 'API rate limit exceeded' });
    case '/same':
      return json(200, { tag_name: `v${current}`, assets: zipAsset(`${base}/Wax-9.9.9.zip`) });
    case '/new':
      return json(200, { tag_name: 'v9.9.9', assets: zipAsset(`${base}/Wax-9.9.9.zip`) });
    case '/noasset':
      return json(200, { tag_name: 'v9.9.9', assets: [] });
    case '/broken':
      return json(200, { tag_name: 'v9.9.9', assets: zipAsset(`${base}/gone.zip`) });
    case '/notwax':
      return json(200, { tag_name: 'v9.9.9', assets: zipAsset(`${base}/text.zip`) });
    case '/text.zip':
      res.writeHead(200, { 'content-type': 'application/zip' });
      return res.end('this is not a zip');
    case '/Wax-9.9.9.zip':
      res.writeHead(200, { 'content-type': 'application/zip' });
      return fs.createReadStream(zipPath).pipe(res);
    default:
      res.writeHead(404);
      return res.end();
  }
});

server.listen(0, '127.0.0.1', () => fs.writeFileSync(portFile, String(server.address().port)));
