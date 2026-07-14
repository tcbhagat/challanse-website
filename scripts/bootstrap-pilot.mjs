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
const reviewerEmails = JSON.parse(required('REVIEWER_EMAILS_JSON'));
const wifiSsids = JSON.parse(required('WIFI_SSIDS_JSON'));
const vendors = JSON.parse(required('VENDORS_JSON'));
if (!Array.isArray(wifiSsids) || !wifiSsids.every((ssid) => typeof ssid === 'string' && ssid.trim())) throw new Error('WIFI_SSIDS_JSON must be a JSON string array.');
if (!Array.isArray(vendors) || vendors.length < 1 || vendors.length > 4) throw new Error('VENDORS_JSON must contain one to four vendors.');
if (!Array.isArray(reviewerEmails) || reviewerEmails.length !== 2 || !reviewerEmails.every((email) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email))) throw new Error('REVIEWER_EMAILS_JSON must contain exactly two email addresses.');

const lines = [
  'BEGIN TRANSACTION;',
  `INSERT INTO sites (id, name, allowed_wifi_ssids_json) VALUES (${sql(siteId)}, ${sql(siteName)}, ${sql(JSON.stringify(wifiSsids))}) ON CONFLICT(id) DO UPDATE SET name = excluded.name, allowed_wifi_ssids_json = excluded.allowed_wifi_ssids_json, configuration_version = sites.configuration_version + 1, updated_at = CURRENT_TIMESTAMP;`,
];
reviewerEmails.forEach((email, index) => lines.push(
  `INSERT INTO reviewers (email, site_id, role, active) VALUES (${sql(email.toLowerCase())}, ${sql(siteId)}, ${sql(index === 0 ? 'ADMIN' : 'CONTROLLER')}, 1) ON CONFLICT(email) DO UPDATE SET site_id = excluded.site_id, role = excluded.role, active = 1;`,
));
vendors.forEach((vendor, index) => {
  if (!vendor.id || !vendor.name || !vendor.initials || !/^#[0-9a-fA-F]{6}$/.test(vendor.color || '')) throw new Error(`Vendor ${index + 1} is invalid.`);
  lines.push(`INSERT INTO vendors (id, site_id, name, initials, color, display_order, active) VALUES (${sql(vendor.id)}, ${sql(siteId)}, ${sql(vendor.name)}, ${sql(vendor.initials)}, ${sql(vendor.color)}, ${index}, 1) ON CONFLICT(id) DO UPDATE SET site_id = excluded.site_id, name = excluded.name, initials = excluded.initials, color = excluded.color, display_order = excluded.display_order, active = 1;`);
});
lines.push('COMMIT;');

process.stdout.write(`${lines.join('\n')}\n`);
