//go:build !unix

package main

import (
	"fmt"
	"os"
	"time"
)

// acquireCommitLock is the non-unix (e.g. Windows) fallback: an exclusive
// lockfile created with O_CREATE|O_EXCL, retried until acquired or timeout.
// Best-effort — unlike flock it is NOT auto-released if the process crashes
// without calling the returned release func (a stale lockfile would then need
// manual removal). The primary multi-session workflow runs on unix (flock).
func acquireCommitLock(lockPath string, timeout time.Duration) (func(), error) {
	deadline := time.Now().Add(timeout)
	for {
		f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
		if err == nil {
			_ = f.Close()
			return func() { _ = os.Remove(lockPath) }, nil
		}
		if !time.Now().Before(deadline) {
			return nil, fmt.Errorf("commit lock busy (waited %s); another cc-handoff commit is in progress (or a stale %s remains)", timeout, lockPath)
		}
		time.Sleep(150 * time.Millisecond)
	}
}
