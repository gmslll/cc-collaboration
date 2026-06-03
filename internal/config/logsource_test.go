package config

import (
	"bytes"
	"testing"

	"github.com/BurntSushi/toml"
)

// TestLogSourceRoundTrip pins that a project's [log] block survives a
// TOML encode→decode without losing fields. Uses an in-memory buffer rather
// than SaveUser/LoadUser so the test never touches the real user config.
func TestLogSourceRoundTrip(t *testing.T) {
	in := User{
		Workspaces: []Workspace{{
			Name: "kunlun",
			Projects: []Project{{
				Name: "backend",
				Path: "api",
				Log: &LogSource{
					Host:    "deploy@10.0.0.5",
					Command: "tail -n 2000 /var/log/app.log",
					Grep:    "(?i)panic",
					Context: 30,
				},
			}},
		}},
	}

	var buf bytes.Buffer
	if err := toml.NewEncoder(&buf).Encode(in); err != nil {
		t.Fatalf("encode: %v", err)
	}

	var out User
	if _, err := toml.Decode(buf.String(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}

	got := out.Workspaces[0].Projects[0].Log
	if got == nil {
		t.Fatal("Log is nil after round-trip")
	}
	if got.Host != in.Workspaces[0].Projects[0].Log.Host ||
		got.Command != in.Workspaces[0].Projects[0].Log.Command ||
		got.Grep != in.Workspaces[0].Projects[0].Log.Grep ||
		got.Context != in.Workspaces[0].Projects[0].Log.Context {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
}

// TestProjectWithoutLogDecodesNil pins backward compatibility: a project
// config that predates the log source leaves Log nil (no empty struct), so old
// configs stay byte-identical and `logs` can detect "not configured".
func TestProjectWithoutLogDecodesNil(t *testing.T) {
	const oldConfig = `
[[workspace]]
name = "kunlun"
  [[workspace.project]]
  name = "backend"
  path = "api"
`
	var u User
	if _, err := toml.Decode(oldConfig, &u); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if u.Workspaces[0].Projects[0].Log != nil {
		t.Fatal("expected Log nil for a config without [log]")
	}
}
