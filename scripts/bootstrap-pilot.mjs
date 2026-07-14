function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required.`);
  return value;
}

function sql(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

const siteId = required('SITE_ID');
const siteName = required('SITE_NAME');
const reviewerEmail = required('REVIEWER_EMAIL').toLowerCase();
const wifiSsids = JSON.parse(required('WIFI_SSIDS_JSON'));
const vendors = JSON.parse(required('VENDORS_JSON'));
if (!Array.isArray(wifiSsids) || !wifiSsids.every((ssid) => typeof ssid === 'string' && ssid.trim())) throw new Error('WIFI_SSIDS_JSON must be a JSON string array.');
if (!Array.isArray(vendors) || vendors.length < 1 || vendors.length > 4) throw new Error('VENDORS_JSON must contain one to four vendors.');

const lines = [
  'BEGIN TRANSACTION;',
  `INSERT INTO sites (id, name, allowed_wifi_ssids_json) VALUES (${sql(siteId)}, ${sql(siteName)}, ${sql(JSON.stringify(wifiSsids))});`,
  `INSERT INTO reviewers (email, site_id, role) VALUES (${sql(reviewerEmail)}, ${sql(siteId)}, 'ADMIN');`,
];
vendors.forEach((vendor, index) => {
  if (!vendor.id || !vendor.name || !vendor.initials || !/^#[0-9a-fA-F]{6}$/.test(vendor.color || '')) throw new Error(`Vendor ${index + 1} is invalid.`);
  lines.push(`INSERT INTO vendors (id, site_id, name, initials, color, display_order) VALUES (${sql(vendor.id)}, ${sql(siteId)}, ${sql(vendor.name)}, ${sql(vendor.initials)}, ${sql(vendor.color)}, ${index});`);
});
lines.push('COMMIT;');

process.stdout.write(`${lines.join('\n')}\n`);
