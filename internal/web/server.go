// Package web serves the user interface on 127.0.0.1 and runs long operations as jobs.
package web

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fangdai/ClaudeSwitch/internal/core"
	"github.com/fangdai/ClaudeSwitch/internal/platform"
)

//go:embed assets
var assets embed.FS

// Step is one line of a job's progress.
type Step struct {
	ID      string `json:"id"`
	State   string `json:"state"`
	Message string `json:"message"`
}

// Job is a long operation shown in the progress panel.
type Job struct {
	ID      int64  `json:"id"`
	Kind    string `json:"kind"`
	Steps   []Step `json:"steps"`
	Done    bool   `json:"done"`
	OK      bool   `json:"ok"`
	Message string `json:"message"`
}

// Server is the UI backend.
type Server struct {
	env   *core.Env
	Token string
	URL   string

	mu          sync.Mutex
	job         *Job
	jobSeq      int64
	notice      string
	noticeSeq   int64
	usageBusy   bool
	lastPing    time.Time
	newLoginAt  map[string]time.Time
	cliSaved    bool
	finishTried string

	httpSrv *http.Server

	// OnRaise, when set, brings the existing window to the front (single instance).
	OnRaise func() bool
}

// New prepares a server bound to a random local port.
func New(env *core.Env) (*Server, net.Listener, error) {
	var b [24]byte
	if _, err := rand.Read(b[:]); err != nil {
		return nil, nil, err
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, nil, err
	}
	s := &Server{env: env, Token: hex.EncodeToString(b[:]), newLoginAt: map[string]time.Time{}, lastPing: time.Now()}
	s.URL = "http://" + ln.Addr().String() + "/"
	return s, ln, nil
}

// Serve runs until ctx is cancelled.
func (s *Server) Serve(ctx context.Context, ln net.Listener) error {
	mux := http.NewServeMux()
	static, _ := fs.Sub(assets, "assets")
	mux.Handle("/", http.FileServer(http.FS(static)))
	mux.HandleFunc("/api/ping", s.api(func(r *http.Request) (any, error) { return map[string]bool{"ok": true}, nil }))
	mux.HandleFunc("/api/raise", s.api(func(r *http.Request) (any, error) {
		ok := s.OnRaise != nil && s.OnRaise()
		return map[string]bool{"raised": ok}, nil
	}))
	mux.HandleFunc("/api/status", s.api(s.handleStatus))
	mux.HandleFunc("/api/action", s.api(s.handleAction))
	s.httpSrv = &http.Server{Handler: s.guard(mux), ReadHeaderTimeout: 5 * time.Second}
	go s.watch(ctx)
	go func() {
		<-ctx.Done()
		sh, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		s.httpSrv.Shutdown(sh)
	}()
	err := s.httpSrv.Serve(ln)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

// guard blocks other hosts (DNS rebinding) and requests without the session token.
func (s *Server) guard(next http.Handler) http.Handler {
	host := strings.TrimPrefix(strings.TrimSuffix(s.URL, "/"), "http://")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != host {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:")
		if strings.HasPrefix(r.URL.Path, "/api/") {
			if subtle.ConstantTimeCompare([]byte(r.Header.Get("X-CS-Token")), []byte(s.Token)) != 1 {
				http.Error(w, "forbidden", http.StatusForbidden)
				return
			}
			s.mu.Lock()
			s.lastPing = time.Now()
			s.mu.Unlock()
		}
		next.ServeHTTP(w, r)
	})
}

// LastSeen is the time of the last UI request.
func (s *Server) LastSeen() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastPing
}

type apiFunc func(r *http.Request) (any, error)

func (s *Server) api(f apiFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		v, err := f(r)
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		if err != nil {
			msg := "Đã có lỗi. Xem nhật ký để biết thêm."
			var ue *core.UserError
			if errors.As(err, &ue) {
				msg = ue.Msg
			} else {
				s.env.Logf("Lỗi: %v", err)
			}
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]string{"error": msg})
			return
		}
		json.NewEncoder(w).Encode(v)
	}
}

func (s *Server) handleStatus(r *http.Request) (any, error) {
	st := s.env.Status()
	s.mu.Lock()
	defer s.mu.Unlock()
	return map[string]any{"status": st, "job": s.job, "notice": s.notice, "noticeId": s.noticeSeq, "usageBusy": s.usageBusy}, nil
}

func (s *Server) setNotice(msg string) {
	s.mu.Lock()
	s.notice = msg
	s.noticeSeq++
	s.mu.Unlock()
}

func (s *Server) busy() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.job != nil && !s.job.Done
}

// startJob runs fn in the background, recording its progress.
func (s *Server) startJob(kind string, fn func(p core.Progress) (string, error)) (any, error) {
	s.mu.Lock()
	if s.job != nil && !s.job.Done {
		s.mu.Unlock()
		return nil, &core.UserError{Msg: "Đang có thao tác khác chạy. Hãy đợi xong."}
	}
	s.jobSeq++
	job := &Job{ID: s.jobSeq, Kind: kind, Steps: []Step{}}
	s.job = job
	s.mu.Unlock()
	go func() {
		unlock := s.env.Lock()
		defer unlock()
		progress := func(step, state, msg string) {
			s.mu.Lock()
			defer s.mu.Unlock()
			for i := range job.Steps {
				if job.Steps[i].ID == step {
					job.Steps[i].State, job.Steps[i].Message = state, msg
					return
				}
			}
			job.Steps = append(job.Steps, Step{ID: step, State: state, Message: msg})
		}
		msg, err := fn(progress)
		s.mu.Lock()
		defer s.mu.Unlock()
		job.Done, job.OK, job.Message = true, err == nil, msg
		if err != nil {
			job.Message = err.Error()
			var ue *core.UserError
			if !errors.As(err, &ue) {
				s.env.Logf("Lỗi %s: %v", kind, err)
				job.Message = "Đã có lỗi: " + err.Error()
			}
		}
	}()
	return map[string]int64{"job": job.ID}, nil
}

type actionReq struct {
	Action string `json:"action"`
	UUID   string `json:"uuid"`
	Label  string `json:"label"`
	Key    string `json:"key"`
	Value  bool   `json:"value"`
	Force  bool   `json:"force"`
}

func (s *Server) handleAction(r *http.Request) (any, error) {
	if r.Method != http.MethodPost {
		return nil, &core.UserError{Msg: "Sai phương thức."}
	}
	var a actionReq
	if err := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<16)).Decode(&a); err != nil {
		return nil, &core.UserError{Msg: "Yêu cầu không hợp lệ."}
	}
	e := s.env
	ok := map[string]any{"ok": true}
	quick := func(f func() (string, error)) (any, error) {
		if s.busy() {
			return nil, &core.UserError{Msg: "Đang có thao tác khác chạy. Hãy đợi xong."}
		}
		unlock := e.Lock()
		defer unlock()
		msg, err := f()
		if err != nil {
			return nil, err
		}
		return map[string]any{"ok": true, "message": msg}, nil
	}
	switch a.Action {
	case "desktop.switch":
		return s.startJob("switch", func(p core.Progress) (string, error) {
			w, err := e.SwitchDesktop(a.UUID, p)
			if w != "" {
				return "Đã chuyển tài khoản. " + w, err
			}
			return "Đã chuyển tài khoản xong.", err
		})
	case "desktop.add":
		return s.startJob("add", func(p core.Progress) (string, error) {
			return "Claude đã mở ở màn hình đăng nhập. Hãy đăng nhập account còn lại.", e.PrepareAddDesktop(p)
		})
	case "desktop.cancelAdd":
		return s.startJob("cancelAdd", func(p core.Progress) (string, error) {
			return "Đã quay lại account cũ.", e.CancelAddDesktop(p)
		})
	case "desktop.sync":
		return s.startJob("sync", func(p core.Progress) (string, error) {
			r, err := e.SyncSessions()
			return r.String(), err
		})
	case "desktop.save":
		return quick(func() (string, error) { _, err := e.SaveDesktop(); return "Đã lưu đăng nhập hiện tại.", err })
	case "desktop.label":
		return quick(func() (string, error) { return "Đã đổi tên.", e.SetDesktopLabel(a.UUID, a.Label) })
	case "desktop.removeCopies":
		return quick(func() (string, error) {
			n, k, err := e.RemoveCopies()
			return "Đã gỡ " + itoa(n) + " session đã sao chép, giữ lại " + itoa(k) + " (đã bị sửa).", err
		})
	case "settings.set":
		return ok, e.SetSetting(a.Key, a.Value)
	case "cli.switch":
		return quick(func() (string, error) { return e.SwitchCli(a.UUID, false) })
	case "cli.login":
		return quick(e.StartCliLogin)
	case "cli.finishLogin":
		return quick(e.FinishCliLogin)
	case "cli.cancelLogin":
		return quick(func() (string, error) { e.CancelCliLogin(); return "Đã hủy đăng nhập CLI.", nil })
	case "cli.open":
		return quick(func() (string, error) { return "Đã mở Claude CLI.", e.OpenCli() })
	case "cli.label":
		return quick(func() (string, error) { return "Đã đổi tên.", e.SetCliLabel(a.UUID, a.Label) })
	case "usage.refresh":
		s.mu.Lock()
		if s.usageBusy {
			s.mu.Unlock()
			return ok, nil
		}
		s.usageBusy = true
		s.mu.Unlock()
		go func() {
			defer func() { s.mu.Lock(); s.usageBusy = false; s.mu.Unlock() }()
			if s.busy() {
				return
			}
			unlock := e.Lock()
			defer unlock()
			e.RefreshUsage(a.Force)
		}()
		return ok, nil
	case "open.backups":
		return ok, platform.OpenURL(filepath.Join(e.StoreDir, "backups"))
	case "open.logs":
		return ok, platform.OpenURL(filepath.Join(e.StoreDir, "logs"))
	}
	return nil, &core.UserError{Msg: "Thao tác không hợp lệ."}
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

// watch handles what the old GUI did with timers: saving a new login automatically,
// noticing the second account during "add", and finishing a CLI login.
func (s *Server) watch(ctx context.Context) {
	t := time.NewTicker(2 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if s.busy() {
			continue
		}
		s.tick()
	}
}

func (s *Server) tick() {
	e := s.env
	unlock := e.Lock()
	defer unlock()
	d := e.DesktopState()
	if d.Installed && d.PendingAdd != nil && d.LoggedIn {
		// Give Claude a few seconds to write cookies before saving the new login.
		first, seen := s.newLoginAt[d.ActiveUUID]
		if !seen {
			s.newLoginAt[d.ActiveUUID] = time.Now()
		} else if time.Since(first) >= 4*time.Second {
			if id, msg := e.CheckAddedLogin(); id != "" {
				s.setNotice("Đã thêm account mới. Từ giờ bạn chuyển qua lại chỉ với một cú nhấp.")
			} else if msg != "" {
				s.setNotice(msg)
			}
			delete(s.newLoginAt, d.ActiveUUID)
		}
	} else if d.Installed && d.PendingAdd == nil && d.UnsavedCurrent {
		if _, err := e.SaveDesktop(); err == nil {
			s.setNotice("Đã lưu account Claude Desktop đang đăng nhập.")
		}
	}
	if e.FindCliPath() == "" {
		return
	}
	live := e.CliLiveState()
	if !s.cliSaved && live.Verified && len(e.CliOverrides()) == 0 &&
		!fileExists(filepath.Join(e.StoreDir, "cli", "profiles", live.UUID, "auth.bin")) {
		s.cliSaved = true
		if err := e.SaveCli(); err == nil {
			s.setNotice("Đã lưu account Claude CLI đang đăng nhập.")
		}
	}
	// Finish a completed CLI login once automatically; the button retries after a failure.
	if st := e.CliStatus(); st.PendingLogin != nil && st.PendingLogin.State == "ready" && s.finishTried != st.PendingLogin.ID {
		s.finishTried = st.PendingLogin.ID
		msg, err := e.FinishCliLogin()
		if err != nil {
			msg = err.Error()
		}
		s.setNotice(msg)
	}
}

func fileExists(p string) bool { return platform.Exists(p) }
