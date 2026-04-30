//go:build windows

package notify

import "testing"

func TestXMLEscape(t *testing.T) {
	cases := map[string]string{
		"":                    "",
		"plain":               "plain",
		"a&b":                 "a&amp;b",
		"<tag>":               "&lt;tag&gt;",
		`"q"`:                 "&quot;q&quot;",
		"it's":                "it&apos;s",
		`<a href="x">y&z</a>`: "&lt;a href=&quot;x&quot;&gt;y&amp;z&lt;/a&gt;",
	}
	for in, want := range cases {
		if got := xmlEscape(in); got != want {
			t.Errorf("xmlEscape(%q) = %q, want %q", in, got, want)
		}
	}
}
