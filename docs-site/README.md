# KRF documentation site

The site has two primary sections:

- `docs/reference/` contains system guides and API contracts.
- `docs/tutorial/` contains the cultivation game tutorial.

`sidebarsReference.ts` explicitly orders the Reference by system, with each guide
beside its API. `sidebarsTutorial.ts` orders the tutorial chapters. Add new
pages to the appropriate sidebar rather than relying on filename sorting.

The homepage in `src/pages/index.tsx` links to both sections.

## Local development

Use Node.js 20 or newer and npm. Run from `docs-site/`:

```powershell
npm ci
npm start
```

Open `http://localhost:3000/`. Most content edits update without restarting.

## Preview a production build

```powershell
npm run typecheck
npm run build
npm run serve
```

The build writes ignored `build/` output and reports broken internal links.
Check Reference's folder ordering and Tutorial's chapter navigation after
changing `docusaurus.config.ts` or either sidebar.

From the repository root, prefix commands with `npm --prefix docs-site`.

## Editing content

Use the package entrypoint and current source contracts as the API authority.
Explain ownership and lifecycle in guides; keep signatures, data shapes, events
and failure behavior in API pages. Cross-link systems where an interaction matters.
Planned capabilities belong in the charter, not in examples of shipped APIs.

## Deployment

`.github/workflows/docs-deploy.yml` deploys the site when documentation changes
reach `main`. It reads the origin and mount path from GitHub Pages before the
build. GitHub hosts the KRF project site at `https://kevmp.github.io/KRF/`. A
custom domain configured on this project can serve it from `/`.

For a different host, set `KRF_DOCS_ORIGIN` to the public origin before the build.
Set `KRF_DOCS_BASE_PATH` only when the host serves the site from a subdirectory.
