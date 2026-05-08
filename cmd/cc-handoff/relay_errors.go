package main

import (
	"errors"
	"fmt"

	"github.com/cc-collaboration/internal/transport"
)

// relayCompatError translates transport errors into actionable CLI output:
//
//   - ErrNotImplemented: the relay binary doesn't expose this endpoint
//     (typically pre-multi-agent relay versions). Surface the upgrade path.
//   - ErrConflict: surface the server message verbatim — for retract that
//     means "cannot retract handoff in state picked — coordinate via comment
//     instead", which already tells the user what to do next.
//   - anything else: pass through unchanged.
//
// All commands that touch endpoints added after 0.1.1 should funnel their
// transport error returns through this helper so the messaging stays consistent.
func relayCompatError(err error, feature string) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, transport.ErrNotImplemented) {
		return fmt.Errorf("%s is not supported by your relay; upgrade the relay (`make deploy`) and try again", feature)
	}
	if errors.Is(err, transport.ErrConflict) {
		return err
	}
	return err
}
