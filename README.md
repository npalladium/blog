# blog

Personal blog built with [Hugo](https://gohugo.io/).

## Theme

`themes/hugo-xmin` is a hard fork of [hugo-xmin](https://github.com/yihui/hugo-xmin)
by [Yihui Xie](https://yihui.org/), used under the
[MIT License](themes/hugo-xmin/LICENSE.md).

Local modifications:

- Date format changed to ISO 8601 (`YYYY-MM-DD`)
- Author resolved from frontmatter first, then git commit metadata
- KaTeX auto-render injected via `head_custom.html`
- RSS and Atom feeds ordered by publication date
- Reading typography, article headers, and footnote layout/navigation styled in `static/css/custom.css`
- Inline Org footnote markers are excluded from text selection; footnote bodies and their labels remain selectable. Clipboard behavior depends on the browser.

## Post metadata

Published Org posts keep writing, publication, and substantive-update dates separate:

```org
#+DATE: 2026-11-13
#+PUBLISHDATE: 2026-11-16T19:08:54+05:30
#+LASTMOD: 2026-11-16T20:10:32+05:30
#+TAGS[]: software-design data-modeling reliability
```

- `DATE` records the writing date.
- `PUBLISHDATE` records the first public deployment, including its timezone. Listings, article publication labels, and feeds use this value; later deployments do not change it.
- `LASTMOD` records the latest substantive update. Set it deliberately when revising a published post; preserve it during metadata-only or styling changes.
- Tags use consistent lowercase names, with hyphens between words. Keep existing tag names stable so their public URLs continue to work.

Build deployments from a clean worktree of committed `main`, using the canonical `baseURL` in `hugo.toml` so feed links and Atom IDs are absolute. Do not include uncommitted drafts or generated source artifacts.
