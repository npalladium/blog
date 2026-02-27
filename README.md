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
- Atom feed output format added alongside the built-in RSS
