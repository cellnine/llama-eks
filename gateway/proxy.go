package main

import (
	"net/http"
	"net/http/httputil"
	"net/url"
	"time"
)

// NewUpstreamProxy builds the reverse proxy to llama-server.
// FlushInterval -=1 means a flush after every received chunk (SSE passthrough).
func NewUpstreamProxy(target string) (*httputil.ReverseProxy, error) {
	u, err := url.ParseRequestURI(target)
	if err != nil {
		return nil, err
	}
	// SingleConnection doesn't matter here; upstream is on the same network and can
	// hit us concurrently per llama.cpp server (HTTP/1.1 keep-alive pools by caller).
	hc := &http.Client{
		Timeout: 0, // no overall timeout: generation can be long for streaming
		Transport: &http.Transport{
			MaxIdleConnsPerHost: 8,
			IdleConnTimeout:     30 * time.Second,
			// streaming: prevent reply-header buffer flush truncation
			ResponseHeaderTimeout: 120 * time.Second,
		},
	}

	rp := &httputil.ReverseProxy{
		FlushInterval: -1, // immediate flush per chunk for SSE
		Director: func(req *http.Request) {
			req.URL.Scheme = u.Scheme
			req.URL.Host = u.Host
			req.Host = u.Host
			// strip auth material before it flows downstream? llama-server is internal-only,
			// but never forward client identity headers it doesn't need.
			req.Header.Del("Authorization")
			req.Header.Del("X-API-Key")
			if _, ok := req.Header["User-Agent"]; !ok {
				req.Header.Set("User-Agent", "llama-eks-gateway")
			}
		},
		Transport: hc.Transport,
	}
	return rp, nil
}
