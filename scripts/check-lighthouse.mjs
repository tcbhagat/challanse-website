import { readFile } from "node:fs/promises";

const reportPaths = process.argv.slice(2);
const paths = reportPaths.length > 0 ? reportPaths : [".lighthouse.json"];
const reports = await Promise.all(paths.map(async (path) => JSON.parse(await readFile(path, "utf8"))));

function median(values) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.floor(sorted.length / 2)];
}

const metric = (read) => median(reports.map(read));

const checks = [
  ["Performance score", metric((report) => report.categories.performance.score), 0.9, ">="],
  ["Accessibility score", metric((report) => report.categories.accessibility.score), 0.95, ">="],
  ["Best practices score", metric((report) => report.categories["best-practices"].score), 0.95, ">="],
  ["SEO score", metric((report) => report.categories.seo.score), 0.95, ">="],
  ["Largest Contentful Paint", metric((report) => report.audits["largest-contentful-paint"].numericValue), 2500, "<="],
  ["Cumulative Layout Shift", metric((report) => report.audits["cumulative-layout-shift"].numericValue), 0.1, "<="],
  ["Total Blocking Time", metric((report) => report.audits["total-blocking-time"].numericValue), 200, "<="],
  ["Transferred bytes", metric((report) => report.audits["total-byte-weight"].numericValue), 512000, "<="]
];

const failed = checks.filter(([, actual, limit, operator]) =>
  operator === ">=" ? actual < limit : actual > limit
);

for (const [label, actual, limit, operator] of checks) {
  console.log(`${label}: ${actual} (${operator} ${limit})`);
}

if (failed.length > 0) {
  process.exitCode = 1;
}
