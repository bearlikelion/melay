package api

import (
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// PlayPrefix is where a hosted Godot web export is served from.
const PlayPrefix = "/play/"

// playFS serves a Godot web export.
type playFS struct {
	root  http.FileSystem
	files http.Handler
}

// playHandler serves a Godot web export with the headers a browser needs before it
// will hand the page a SharedArrayBuffer. Threaded exports fail to boot without them,
// and single-threaded exports are unaffected, so they are always sent.
func playHandler(dir string) http.Handler {
	root := http.Dir(dir)
	return &playFS{root: root, files: http.FileServer(root)}
}

func (p *playFS) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Cross-Origin-Opener-Policy", "same-origin")
	h.Set("Cross-Origin-Embedder-Policy", "require-corp")
	h.Set("Cross-Origin-Resource-Policy", "cross-origin")

	upath := strings.TrimPrefix(r.URL.Path, strings.TrimSuffix(PlayPrefix, "/"))
	if upath == "" || strings.HasSuffix(upath, "/") {
		upath = path.Join(upath, "index.html")
	}

	if ctype := contentTypeFor(upath); ctype != "" {
		h.Set("Content-Type", ctype)
	}
	// The build is replaced on every deploy, so a cached document would keep players
	// on the previous version.
	if strings.HasSuffix(upath, ".html") {
		h.Set("Cache-Control", "no-store")
	}

	if p.servePrecompressed(w, r, upath) {
		return
	}
	http.StripPrefix(PlayPrefix, p.files).ServeHTTP(w, r)
}

// servePrecompressed sends foo.wasm.gz in place of foo.wasm when the client accepts
// it. Godot's wasm is around 38MB raw and a quarter of that compressed, which matters
// twice over: it is a smaller download, and it stays under the 32MB ceiling that
// Cloud Run puts on a response it cannot stream.
func (p *playFS) servePrecompressed(w http.ResponseWriter, r *http.Request, upath string) bool {
	if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		return false
	}

	// http.FileSystem.Open rejects paths that try to escape the root.
	f, err := p.root.Open(upath + ".gz")
	if err != nil {
		return false
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil || info.IsDir() {
		return false
	}

	w.Header().Set("Content-Encoding", "gzip")
	w.Header().Set("Vary", "Accept-Encoding")
	// An empty name stops ServeContent guessing a type from ".gz"; the real type is
	// already on the header.
	http.ServeContent(w, r, "", info.ModTime(), f)
	return true
}

// contentTypeFor covers the types a minimal image may not have in its mime table. A
// wrong type on the wasm stops streaming compilation.
func contentTypeFor(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".wasm":
		return "application/wasm"
	case ".pck":
		return "application/octet-stream"
	case ".js":
		return "text/javascript"
	case ".html":
		return "text/html; charset=utf-8"
	case ".json":
		return "application/json"
	}
	return ""
}

// hasWebExport reports whether dir looks like a Godot web export.
func hasWebExport(dir string) bool {
	if dir == "" {
		return false
	}
	info, err := os.Stat(filepath.Join(dir, "index.html"))
	return err == nil && !info.IsDir()
}
