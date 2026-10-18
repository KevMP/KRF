# KRF documentation site

The [KRF guides and API reference](https://kevmp.github.io/KRF/) use Docusaurus.
Guides live in `docs/documentation`; the manual API reference lives in `docs/api`.
Their routes, navigation, and sidebars are configured in `docusaurus.config.ts`,
`sidebars.ts`, and `sidebarsApi.ts`.

## Local development

Use Node.js 20 or newer and npm. Run from `docs-site/`:

```powershell
npm ci
npm start
```

Open `http://localhost:3000/KRF/`. Most content changes update without restarting.

## Validate and preview

```powershell
npm run typecheck
npm run build
npm run serve
```

The production build writes `build/` and fails on broken internal links. The
preview serves that output at `http://localhost:3000/KRF/`. Check both the Docs
and API navigation when changing routes or sidebars.

From the repository root, use `npm --prefix docs-site run build` or the equivalent
`npm --prefix docs-site <command>`. Generated output and dependencies stay ignored.

## Deployment

`.github/workflows/docs-deploy.yml` builds and deploys to GitHub Pages when
documentation changes reach `main`; it also supports manual dispatch. The site
uses `https://kevmp.github.io` with the `/KRF/` base path.
