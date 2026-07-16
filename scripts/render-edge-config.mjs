import { readFile, writeFile } from 'node:fs/promises';

const source = new URL('../apps/edge/wrangler.toml', import.meta.url);
const target = new URL('../apps/edge/wrangler.generated.toml', import.meta.url);
const accessTeamDomain = process.env.CLOUDFLARE_ACCESS_TEAM_DOMAIN;
const accessAudience = process.env.CLOUDFLARE_ACCESS_AUD;
const enrichmentUrl = process.env.ENRICHMENT_URL || '';
const edgeToEnrichmentKeyId = process.env.EDGE_TO_ENRICHMENT_HMAC_KEY_ID || '';
const edgeToEnrichmentNextKeyId = process.env.EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID || '';

if (!accessTeamDomain || !accessAudience) {
  throw new Error('Cloudflare Access team domain and audience are required.');
}

const config = (await readFile(source, 'utf8'))
  .replace('ACCESS_TEAM_DOMAIN = ""', `ACCESS_TEAM_DOMAIN = ${JSON.stringify(accessTeamDomain)}`)
  .replace('ACCESS_AUD = ""', `ACCESS_AUD = ${JSON.stringify(accessAudience)}`);
const rendered = config
  .replace('ENRICHMENT_URL = ""', `ENRICHMENT_URL = ${JSON.stringify(enrichmentUrl)}`)
  .replace('EDGE_TO_ENRICHMENT_HMAC_KEY_ID = ""', `EDGE_TO_ENRICHMENT_HMAC_KEY_ID = ${JSON.stringify(edgeToEnrichmentKeyId)}`)
  .replace('EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID = ""', `EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID = ${JSON.stringify(edgeToEnrichmentNextKeyId)}`);

await writeFile(target, rendered);
console.log('Generated apps/edge/wrangler.generated.toml');
