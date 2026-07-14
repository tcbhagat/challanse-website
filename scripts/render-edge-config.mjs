import { readFile, writeFile } from 'node:fs/promises';

const source = new URL('../apps/edge/wrangler.toml', import.meta.url);
const target = new URL('../apps/edge/wrangler.generated.toml', import.meta.url);
const databaseId = process.env.CLOUDFLARE_D1_DATABASE_ID;
const accessTeamDomain = process.env.CLOUDFLARE_ACCESS_TEAM_DOMAIN;
const accessAudience = process.env.CLOUDFLARE_ACCESS_AUD;

if (!databaseId || !/^[0-9a-f-]{36}$/i.test(databaseId)) {
  throw new Error('CLOUDFLARE_D1_DATABASE_ID must be a D1 database UUID.');
}
if (!accessTeamDomain || !accessAudience) {
  throw new Error('Cloudflare Access team domain and audience are required.');
}

const config = (await readFile(source, 'utf8'))
  .replace('00000000-0000-0000-0000-000000000000', databaseId)
  .replace('ACCESS_TEAM_DOMAIN = ""', `ACCESS_TEAM_DOMAIN = ${JSON.stringify(accessTeamDomain)}`)
  .replace('ACCESS_AUD = ""', `ACCESS_AUD = ${JSON.stringify(accessAudience)}`);

await writeFile(target, config);
console.log('Generated apps/edge/wrangler.generated.toml');
