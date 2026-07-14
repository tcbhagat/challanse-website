import { readFile } from "node:fs/promises";

const reportPath = process.argv[2] || ".lighthouse.json";
const report = JSON.parse(await readFile(reportPath, "utf8"));

const checks = [
  ["Performance score", report.categories.performance.score, 0.9, ">="],
  ["Accessibility score", report.categories.accessibility.score, 0.95, ">="],
  ["Best practices score", report.categories["best-practices"].score, 0.95, ">="],
  ["SEO score", report.categories.seo.score, 0.95, ">="],
  ["Largest Contentful Paint", report.audits["largest-contentful-paint"].numericValue, 2500, "<="],
  ["Cumulative Layout Shift", report.audits["cumulative-layout-shift"].numericValue, 0.1, "<="],
  ["Total Blocking Time", report.audits["total-blocking-time"].numericValue, 200, "<="],
  ["Transferred bytes", report.audits["total-byte-weight"].numericValue, 512000, "<="]
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
