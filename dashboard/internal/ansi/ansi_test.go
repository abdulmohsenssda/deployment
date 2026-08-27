package ansi

import "testing"

func TestStrip(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "color",
			in:   "\x1b[31mred\x1b[0m normal",
			want: "red normal",
		},
		{
			name: "cursor and control",
			in:   "\x1b[2K\x1b[1;1Hready\r\b\a",
			want: "ready",
		},
		{
			name: "osc and string control",
			in:   "\x1b]0;title\x07shown\x1bP1;2+qpayload\x1b\\after",
			want: "shownafter",
		},
		{
			name: "multiline",
			in:   "\x1b[32mgreen\nplain\x1b[0m\nlast",
			want: "green\nplain\nlast",
		},
		{
			name: "malformed preserves following text",
			in:   "before\x1b[31\nafter\x1b",
			want: "before[31\nafter",
		},
		{
			name: "ordinary bracket text",
			in:   "[31m [reset] 100%",
			want: "[31m [reset] 100%",
		},
		{
			name: "unicode and tab",
			in:   "日本語\tok",
			want: "日本語\tok",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Strip(tt.in); got != tt.want {
				t.Fatalf("Strip(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}

func TestStripC1CSI(t *testing.T) {
	for _, input := range []string{"\x9b31mred\x9b0m", "\u009b31mred\u009b0m"} {
		if got, want := Strip(input), "red"; got != want {
			t.Fatalf("Strip(%q) = %q, want %q", input, got, want)
		}
	}
}
