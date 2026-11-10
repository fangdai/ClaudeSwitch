package core

import (
	"bytes"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"strconv"
	"time"
)

// HTTPReply is the decoded answer of an API call. Status 0 means no connection.
type HTTPReply struct {
	Status       int
	Body         map[string]any
	RetrySeconds float64
}

// HTTPFunc performs one request. body == nil means GET.
type HTTPFunc func(method, url, token string, body any) HTTPReply

var httpClient = &http.Client{
	Timeout:       10 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

func defaultHTTP(method, url, token string, body any) HTTPReply {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, url, rd)
	if err != nil {
		return HTTPReply{RetrySeconds: 60}
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	}
	req.Header.Set("User-Agent", "claude-switch")
	resp, err := httpClient.Do(req)
	if err != nil {
		return HTTPReply{RetrySeconds: 60}
	}
	defer resp.Body.Close()
	out := HTTPReply{Status: resp.StatusCode, RetrySeconds: 300}
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		if v, err := decodeJSON(b); err == nil {
			out.Body, _ = v.(map[string]any)
		}
	}
	if ra := resp.Header.Get("Retry-After"); ra != "" {
		if s, err := strconv.ParseFloat(ra, 64); err == nil {
			out.RetrySeconds = math.Max(300, s)
		} else if t, err := http.ParseTime(ra); err == nil {
			out.RetrySeconds = math.Max(300, time.Until(t).Seconds())
		}
	}
	out.RetrySeconds = math.Min(86400, out.RetrySeconds)
	return out
}

func (e *Env) http(method, url, token string, body any) HTTPReply {
	if e.HTTP == nil {
		return HTTPReply{RetrySeconds: 60}
	}
	return e.HTTP(method, url, token, body)
}
