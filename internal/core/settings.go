package core

import "path/filepath"

func (e *Env) settingsPath() string { return filepath.Join(e.StoreDir, "settings.json") }

// Settings returns the stored settings with defaults filled in.
func (e *Env) Settings() map[string]any {
	s := map[string]any{"syncSessions": true, "skipConfirm": false}
	for k, v := range readJSONMap(e.settingsPath()) {
		s[k] = v
	}
	return s
}

// PublicSettings is what the UI may see and change.
func (e *Env) PublicSettings() map[string]any {
	s := e.Settings()
	out := map[string]any{}
	for _, k := range []string{"syncSessions", "skipConfirm"} {
		out[k], _ = s[k].(bool)
	}
	return out
}

func (e *Env) updateSettings(changes map[string]any) {
	s := readJSONMap(e.settingsPath())
	if s == nil {
		s = map[string]any{}
	}
	for k, v := range changes {
		s[k] = v
	}
	if err := writeJSON(e.settingsPath(), s); err != nil {
		e.Logf("Không ghi được settings.json: %v", err)
	}
}

// SetSetting changes one user-facing boolean setting.
func (e *Env) SetSetting(key string, value bool) error {
	if key != "syncSessions" && key != "skipConfirm" {
		return userErr("Cài đặt không hợp lệ.")
	}
	e.updateSettings(map[string]any{key: value})
	return nil
}
