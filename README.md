# ChallanSe Website

Standalone static landing page for ChallanSe, a Constrovet field-receipt workflow.

## Local preview

```bash
npm ci
python3 -m http.server 4173
```

Open `http://127.0.0.1:4173/`.

## Validation

```bash
npm run check
python3 -m http.server 4173 > /tmp/challanse-http.log 2>&1 &
npm run audit
```

The Lighthouse gate requires:

- Performance at least 90
- Accessibility, best practices, and SEO at least 95
- LCP no more than 2.5 seconds
- CLS no more than 0.1
- TBT no more than 200 milliseconds
- Transferred page weight no more than 500 KiB

## Deployment

Pushes to `main` run validation and deploy to GitHub Pages through `.github/workflows/ci-pages.yml`.

Initial URL: `https://tcbhagat.github.io/challanse-website/`

The current `www.constrovet.com/pages/challanse.html` route remains unchanged during migration. A future custom subdomain requires DNS configuration and a separate approved cutover.
