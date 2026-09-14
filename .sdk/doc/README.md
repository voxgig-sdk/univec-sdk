# Univec documentation

The model settings live in `.sdk/model/project.aon` under `main.kit.doc`.
All three editions are installed: `summary`, `github-pages`, and `presentation`.

From `.sdk`, run:

```sh
npm ci
npm run generate:docs
```

This compiles the existing API and SDK model and generates `SUMMARY.md`,
`docs/`, and the Slidev source in `docs/slidev/`. The normal
`npm run generate` command also generates documentation after the SDKs.

Build the presentation with:

```sh
cd ../docs/slidev
npm ci
npm run build
```

With Vale 3.14.0 installed, check every edition from the repository root:

```sh
vale --config=.sdk/doc/qa/vale.ini sync
cd .sdk
npm run text-qa
```

The generated `.github/workflows/docgen.yml` runs the checks and builds
the presentation before deploying `docs/` to GitHub Pages on `main`.
The nested presentation is built and served at `slidev/` in the website.
Run `npm run dev` from `docs/slidev/` for the local presentation server.
Set `main.kit.doc.edition.presentation.site.active: false` to keep it local.

Edit installed templates under `.sdk/tm/edition/`; add authored Markdown
under `.sdk/doc/content/`. Generated documentation files are overwritten.
The toolchain uses published npm releases recorded in `.sdk/package-lock.json`.

The website and presentation use the palette and typography from
[univec.ai](https://univec.ai/), configured in `main.kit.doc.style`. The provider
link and unofficial-project notices use `main.kit.doc.brand`. The presentation
has a consistent frame, header, footer, and slide numbers; it has no logo.

Manrope, IBM Plex Sans, and JetBrains Mono are bundled under `.sdk/doc/assets/`
with their SIL Open Font License files. Generation copies fonts and licenses
into each visual edition; neither output loads fonts from a remote service.
