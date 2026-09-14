# Changelog

All notable changes to the generated Univec SDK are documented here.
This project follows [Keep a Changelog](https://keepachangelog.com) and
[Semantic Versioning](https://semver.org).

## [Unreleased]

## [release/v0.1.0] - 2026-09-14

Repository release only. SDK package versions remain unchanged; this release
has no registry publication.

- Add an API and SDK orientation summary, a static documentation website,
  and a Slidev presentation, generated from the existing `.sdk` model.
- Configure the website and presentation with UniVec colours, local fonts,
  provider links, and the unofficial SDK notice.
- Check every documentation edition with Vale in CI and deploy the website
  to GitHub Pages when the release reaches `main`.
- Add repository status and GitHub Pages setup scripts in `.sdk/admin/`.
- Use published apidef 8.6.0, sdkgen 4.17.0, and docgen 0.10.1 releases.
- Serve the presentation at `docs/slidev` with styled, auto-hiding controls
  and add configurable gradients and shaded panels to the website.
- Include generated TypeScript live API coverage with opt-in Boru secrets.


## [0.0.1]

- Initial generated release of the Univec SDK (TypeScript, Python, PHP, Go,
  Ruby, and Lua, plus CLI and MCP surfaces), generated from the upstream
  OpenAPI specification by @voxgig/sdkgen.
