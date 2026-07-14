import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';

const root = process.cwd();
const output = path.join(root, 'dist', 'landing');
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const file of ['index.html', 'robots.txt', 'sitemap.xml', '.nojekyll']) {
  await cp(path.join(root, file), path.join(output, file));
}
await cp(path.join(root, 'assets'), path.join(output, 'assets'), { recursive: true });

const apiBaseUrl = process.env.CHALLANSE_API_BASE_URL || '__API_BASE_URL__';
const turnstileSiteKey = process.env.TURNSTILE_SITE_KEY || '__TURNSTILE_SITE_KEY__';
const runtimePath = path.join(output, 'assets', 'js', 'runtime-config.js');
const runtime = (await readFile(runtimePath, 'utf8'))
  .replace('__API_BASE_URL__', apiBaseUrl)
  .replace('__TURNSTILE_SITE_KEY__', turnstileSiteKey);
await writeFile(runtimePath, runtime);

if (process.env.CHALLANSE_CUSTOM_DOMAIN) {
  await writeFile(path.join(output, 'CNAME'), `${process.env.CHALLANSE_CUSTOM_DOMAIN}\n`);
}
