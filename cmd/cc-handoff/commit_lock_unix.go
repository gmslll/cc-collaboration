//go:build unix

package main

import (
	"fmt"
	"os"
	"syscall"
	"time"
)

// acquireCommitLock takes an exclusive advisory lock (flock) on lockPath,
// retrying until acquired or the timeout elapses. The returned func releases it.
// flock is tied to the open fd, so the OS drops the lock automatically if the
// process exits — a crash can't wedge it (unlike a bare lockfile).
func acquireCommitLock(lockPath string, timeout time.Duration) (func(), error) {
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open lock %s: %w", lockPath, err)
	}
	deadline := time.Now().Add(timeout)
	for {
		if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
			return func() {
				_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
				_ = f.Close()
			}, nil
		}
		if !time.Now().Before(deadline) {
			_ = f.Close()
			return nil, fmt.Errorf("commit lock busy (waited %s); another cc-handoff commit is in progress", timeout)
		}
		time.Sleep(150 * time.Millisecond)
	}
}
