package webui

import "embed"

// assets contains the production Vite build. The placeholder is replaced by
// `npm run build` before release binaries are compiled.
//
//go:embed all:dist
var assets embed.FS
