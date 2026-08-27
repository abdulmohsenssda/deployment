// Package ansi removes terminal control sequences from text shown as logs.
package ansi

import (
	"strings"
	"unicode/utf8"
)

// Strip removes ANSI terminal controls while leaving ordinary text intact.
//
// Newlines and tabs are retained so multiline log output keeps its layout.
// Incomplete escape sequences only lose their ESC introducer; the remaining
// bytes are treated as ordinary text rather than being discarded.
func Strip(s string) string {
	if s == "" {
		return ""
	}

	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); {
		switch s[i] {
		case 0x1b:
			if end, ok := escapeEnd(s, i); ok {
				i = end
				continue
			}
			// A malformed or incomplete escape must not hide following text.
			i++
		case '\n', '\t':
			b.WriteByte(s[i])
			i++
		case '\r':
			// Carriage returns are terminal cursor controls. Removing them
			// also normalizes progress-style output for a text view.
			i++
		default:
			if s[i] >= utf8.RuneSelf {
				r, size := utf8.DecodeRuneInString(s[i:])
				if size > 1 && r >= 0x80 && r <= 0x9f {
					if end, ok := c1RuneEnd(s, i, r, size); ok {
						i = end
					} else {
						i += size
					}
					continue
				}
				if size > 1 || r != utf8.RuneError {
					b.WriteString(s[i : i+size])
					i += size
					continue
				}
			}
			if end, ok := c1End(s, i); ok {
				i = end
				continue
			}
			if isControl(s[i]) {
				i++
				continue
			}
			b.WriteByte(s[i])
			i++
		}
	}
	return b.String()
}

func isControl(c byte) bool {
	return c < 0x20 || c == 0x7f || (c >= 0x80 && c <= 0x9f)
}

// escapeEnd returns the byte after a complete ESC or C1 sequence.
func escapeEnd(s string, start int) (int, bool) {
	if start >= len(s) || s[start] != 0x1b {
		return start, false
	}
	if start+1 >= len(s) {
		return start, false
	}

	switch s[start+1] {
	case '[':
		return csiEnd(s, start+2)
	case ']':
		return stringEnd(s, start+2, true)
	case 'P', '^', '_', 'X':
		return stringEnd(s, start+2, false)
	case '\\':
		// String terminator (ST), harmless when encountered on its own.
		return start + 2, true
	}

	// A two-byte ESC sequence is complete when its final byte is in the
	// ESC sequence final range.
	if isEscFinal(s[start+1]) {
		return start + 2, true
	}

	// Intermediate bytes are followed by exactly one final byte.
	if s[start+1] >= 0x20 && s[start+1] <= 0x2f {
		i := start + 2
		for i < len(s) && s[i] >= 0x20 && s[i] <= 0x2f {
			i++
		}
		if i < len(s) && isEscFinal(s[i]) {
			return i + 1, true
		}
	}
	return start, false
}

func isEscFinal(c byte) bool {
	return c >= 0x30 && c <= 0x7e
}

func c1End(s string, start int) (int, bool) {
	if start >= len(s) {
		return start, false
	}
	switch s[start] {
	case 0x9b:
		return csiEnd(s, start+1)
	case 0x9d:
		return stringEnd(s, start+1, true)
	case 0x90, 0x98, 0x9e, 0x9f:
		return stringEnd(s, start+1, false)
	case 0x9c:
		return start + 1, true
	default:
		return start, false
	}
}

func c1RuneEnd(s string, start int, r rune, size int) (int, bool) {
	switch r {
	case 0x9b:
		return csiEnd(s, start+size)
	case 0x9d:
		return stringEnd(s, start+size, true)
	case 0x90, 0x98, 0x9e, 0x9f:
		return stringEnd(s, start+size, false)
	case 0x9c:
		return start + size, true
	default:
		return start, false
	}
}

func csiEnd(s string, start int) (int, bool) {
	for i := start; i < len(s); i++ {
		switch {
		case s[i] >= 0x30 && s[i] <= 0x3f:
			// Parameter bytes.
		case s[i] >= 0x20 && s[i] <= 0x2f:
			// Intermediate bytes.
		case s[i] >= 0x40 && s[i] <= 0x7e:
			return i + 1, true
		default:
			return start - 2, false
		}
	}
	return start - 2, false
}

func stringEnd(s string, start int, osc bool) (int, bool) {
	for i := start; i < len(s); i++ {
		switch s[i] {
		case 0x07:
			if osc {
				return i + 1, true
			}
		case 0x9c:
			return i + 1, true
		case 0x1b:
			if i+1 < len(s) && s[i+1] == '\\' {
				return i + 2, true
			}
		}
	}
	return start - 2, false
}
