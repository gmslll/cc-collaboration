package setup

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"text/template"
)

// Platform names a supported supervisor for the receiver-side watch daemon.
type Platform string

const (
	PlatformLaunchd     Platform = "launchd"
	PlatformSystemd     Platform = "systemd"
	PlatformWindowsTask Platform = "windows-task"
)

// UnitParams populates the launchd plist / systemd unit templates that the
// receiver-side `cc-handoff watch` daemon runs from.
type UnitParams struct {
	// BinPath is the absolute path to the cc-handoff binary that the daemon
	// will exec (i.e. `<BinPath> watch`).
	BinPath string
	// WorkDir is the absolute path of the receiving repo. The daemon's working
	// directory; required because cc-handoff resolves repo config from cwd.
	WorkDir string
}

// RenderUnit writes a rendered unit/plist for the given platform to out.
func RenderUnit(platform Platform, p UnitParams, out io.Writer) error {
	if p.BinPath == "" {
		return errors.New("UnitParams.BinPath is required")
	}
	if p.WorkDir == "" {
		return errors.New("UnitParams.WorkDir is required")
	}

	var name string
	switch platform {
	case PlatformLaunchd:
		name = "templates/units/launchd.plist.tmpl"
	case PlatformSystemd:
		name = "templates/units/systemd-user.service.tmpl"
	case PlatformWindowsTask:
		name = "templates/units/windows-task.xml.tmpl"
	default:
		return fmt.Errorf("unknown platform %q (want launchd, systemd, or windows-task)", platform)
	}

	raw, err := unitsFS.ReadFile(name)
	if err != nil {
		return fmt.Errorf("read embedded %s: %w", name, err)
	}
	tmpl, err := template.New(string(platform)).Parse(string(raw))
	if err != nil {
		return fmt.Errorf("parse %s: %w", name, err)
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, p); err != nil {
		return fmt.Errorf("execute %s: %w", name, err)
	}
	_, err = out.Write(buf.Bytes())
	return err
}
