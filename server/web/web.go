// Package web serves the dashboard that ships inside the Melay binary.
package web

import (
	"embed"
	"net/http"
)

//go:embed index.html
var files embed.FS

// Handler serves the dashboard. Any unmatched path falls through to the single page,
// so the binary needs no separate static file deployment.
func Handler() http.Handler {
	page, err := files.ReadFile("index.html")
	if err != nil {
		return http.NotFoundHandler()
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(page)
	})
}
