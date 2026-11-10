package core

import (
	"bytes"
	"encoding/json"
	"errors"
	"reflect"
	"unicode/utf8"
)

// jsonText is a JSON object file edited in place: only the bytes of the values we
// change are touched, every other byte (formatting, key order, big numbers) is kept.
type jsonText struct {
	bom  []byte
	text string
}

var errNotObject = errors.New("file không phải là một đối tượng JSON")

func parseJSONText(b []byte) (*jsonText, error) {
	var bom []byte
	if bytes.HasPrefix(b, []byte{0xEF, 0xBB, 0xBF}) {
		bom, b = b[:3], b[3:]
	} else if bytes.HasPrefix(b, []byte{0xFF, 0xFE}) || bytes.HasPrefix(b, []byte{0xFE, 0xFF}) {
		return nil, errors.New("file dùng mã hóa UTF-16, công cụ chưa hỗ trợ sửa")
	}
	if !utf8.Valid(b) {
		return nil, errors.New("file không phải UTF-8 hợp lệ")
	}
	t := &jsonText{bom: append([]byte{}, bom...), text: string(b)}
	if len(bytes.TrimSpace(b)) == 0 {
		t.text = "{}"
	}
	if _, err := t.object(); err != nil {
		return nil, err
	}
	return t, nil
}

func (t *jsonText) bytes() []byte { return append(append([]byte{}, t.bom...), t.text...) }

func (t *jsonText) object() (map[string]any, error) {
	v, err := decodeJSON([]byte(t.text))
	if err != nil {
		return nil, errors.New("file JSON bị lỗi định dạng")
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, errNotObject
	}
	return m, nil
}

type member struct {
	keyStart, valStart, valEnd int // byte offsets in text
	key                        string
}

func skipWS(s string, i int) int {
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
		i++
	}
	return i
}

func skipString(s string, i int) (int, error) { // s[i] == '"'
	for i++; i < len(s); i++ {
		switch s[i] {
		case '\\':
			i++
		case '"':
			return i + 1, nil
		}
	}
	return 0, errors.New("chuỗi JSON không đóng")
}

func skipValue(s string, i int) (int, error) {
	if i >= len(s) {
		return 0, errors.New("thiếu giá trị JSON")
	}
	switch s[i] {
	case '"':
		return skipString(s, i)
	case '{', '[':
		depth := 0
		for ; i < len(s); i++ {
			switch s[i] {
			case '"':
				end, err := skipString(s, i)
				if err != nil {
					return 0, err
				}
				i = end - 1
			case '{', '[':
				depth++
			case '}', ']':
				depth--
				if depth == 0 {
					return i + 1, nil
				}
			}
		}
		return 0, errors.New("đối tượng JSON không đóng")
	default:
		j := i
		for j < len(s) && s[j] != ',' && s[j] != '}' && s[j] != ']' && s[j] != ' ' && s[j] != '\t' && s[j] != '\n' && s[j] != '\r' {
			j++
		}
		if j == i {
			return 0, errors.New("giá trị JSON rỗng")
		}
		return j, nil
	}
}

// members lists the top-level members in order.
func (t *jsonText) members() ([]member, error) {
	s := t.text
	i := skipWS(s, 0)
	if i >= len(s) || s[i] != '{' {
		return nil, errNotObject
	}
	i = skipWS(s, i+1)
	var out []member
	if i < len(s) && s[i] == '}' {
		return out, nil
	}
	for i < len(s) {
		if s[i] != '"' {
			return nil, errors.New("khóa JSON không hợp lệ")
		}
		ks := i
		ke, err := skipString(s, i)
		if err != nil {
			return nil, err
		}
		var key string
		if err := json.Unmarshal([]byte(s[ks:ke]), &key); err != nil {
			return nil, err
		}
		i = skipWS(s, ke)
		if i >= len(s) || s[i] != ':' {
			return nil, errors.New("thiếu dấu ':' trong JSON")
		}
		i = skipWS(s, i+1)
		vs := i
		ve, err := skipValue(s, i)
		if err != nil {
			return nil, err
		}
		out = append(out, member{keyStart: ks, valStart: vs, valEnd: ve, key: key})
		i = skipWS(s, ve)
		if i < len(s) && s[i] == ',' {
			i = skipWS(s, i+1)
			continue
		}
		if i < len(s) && s[i] == '}' {
			return out, nil
		}
		return nil, errors.New("JSON thiếu dấu ',' hoặc '}'")
	}
	return nil, errors.New("JSON không đóng")
}

func (t *jsonText) find(key string) (*member, []member, error) {
	ms, err := t.members()
	if err != nil {
		return nil, nil, err
	}
	var found *member
	for i := range ms {
		if ms[i].key == key {
			if found != nil {
				return nil, nil, userErr("Khóa '%s' xuất hiện nhiều lần nên công cụ không dám sửa. Chưa có gì bị thay đổi.", key)
			}
			found = &ms[i]
		}
	}
	return found, ms, nil
}

// Count returns how many times key appears at the top level.
func (t *jsonText) Count(key string) int {
	ms, err := t.members()
	if err != nil {
		return 0
	}
	n := 0
	for _, m := range ms {
		if m.key == key {
			n++
		}
	}
	return n
}

// Set replaces (or inserts) a top-level value.
func (t *jsonText) Set(key string, value any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	m, _, err := t.find(key)
	if err != nil {
		return err
	}
	if m != nil {
		t.text = t.text[:m.valStart] + string(raw) + t.text[m.valEnd:]
		return nil
	}
	i := skipWS(t.text, 0)
	rest := t.text[i+1:]
	comma := ","
	if j := skipWS(rest, 0); j < len(rest) && rest[j] == '}' {
		comma = ""
	}
	kraw, _ := json.Marshal(key)
	t.text = t.text[:i+1] + string(kraw) + ": " + string(raw) + comma + rest
	return nil
}

// Remove deletes a top-level member together with its separating comma.
func (t *jsonText) Remove(key string) error {
	m, ms, err := t.find(key)
	if err != nil || m == nil {
		return err
	}
	idx := 0
	for i := range ms {
		if ms[i].keyStart == m.keyStart {
			idx = i
		}
	}
	s := t.text
	if idx < len(ms)-1 {
		// Remove "key": value, up to the next key (keeps its indentation).
		t.text = s[:m.keyStart] + s[ms[idx+1].keyStart:]
		return nil
	}
	if idx > 0 {
		// Last member: drop from the end of the previous value.
		t.text = s[:ms[idx-1].valEnd] + s[m.valEnd:]
		return nil
	}
	t.text = s[:m.keyStart] + s[m.valEnd:]
	return nil
}

// sameExcept checks that two objects are identical apart from the given keys.
func sameExcept(a, b map[string]any, keys ...string) bool {
	skip := map[string]bool{}
	for _, k := range keys {
		skip[k] = true
	}
	for k, v := range a {
		if skip[k] {
			continue
		}
		w, ok := b[k]
		if !ok || !reflect.DeepEqual(v, w) {
			return false
		}
	}
	for k := range b {
		if skip[k] {
			continue
		}
		if _, ok := a[k]; !ok {
			return false
		}
	}
	return true
}
