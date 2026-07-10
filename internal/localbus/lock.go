package localbus

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// lockStaleAfter is how long a held drain lock is allowed to sit before a
// contender treats it as abandoned (the holder crashed or was killed mid
// critical section) and steals it. The critical sections this lock guards —
// the Go hook's ListMsgs+ClearMsgs (runBusHookDrain) and the desktop app's
// escalate-timeout check+paste+delete (terminal_deck.dart) — both run in
// low-single-digit milliseconds, so this is a generous multiple with no risk
// of stealing a lock that's still legitimately held.
const lockStaleAfter = 10 * time.Second

const lockRetryInterval = 20 * time.Millisecond

// AcquireDrainLock takes an exclusive claim on sessionID's inbox directory so
// the receiver's own hook drain (ListMsgs + ClearMsgs in runBusHookDrain) and
// the desktop app's timeout-escalation path (which force-delivers a parked
// message the hook hasn't drained in time instead of leaving it parked
// forever — see deliverLocalMessage / _enqueueBusInbox in terminal_deck.dart)
// never act on the same marker file at once. Without this lock the failure
// mode is a double delivery: the hook includes a message in a Stop continuation
// at the exact moment the app independently pastes the same text into the PTY.
//
// Implemented as an atomic exclusive-create claim file (O_CREATE|O_EXCL)
// rather than flock: the desktop app is Dart, and Dart's file-locking API
// (RandomAccessFile.lock, backed by fcntl byte-range locks) is not guaranteed
// to observe the same lock table as Go's syscall.Flock (BSD flock) on every
// platform, so the two runtimes could both believe they hold "the lock" at
// once. "Create excl to acquire, delete to release" is the one mutual-
// exclusion contract both sides can rely on identically — see
// acquireInboxDrainLock in local_bus.dart for the Dart side of this same
// protocol (same lock path: <inbox>/.lock). Mirrors the claim-by-rename
// pattern local_bus.dart already uses for outbox delivery, and
// cmd/cc-handoff/commit_lock_other.go's non-unix O_EXCL fallback.
//
// Returns a release func on success (call it exactly once), or an error if
// [timeout] elapses while the lock is held by someone else.
func AcquireDrainLock(busDir, sessionID string, timeout time.Duration) (func(), error) {
	dir := InboxDir(busDir, sessionID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create inbox dir: %w", err)
	}
	lockPath := filepath.Join(dir, ".lock")
	deadline := time.Now().Add(timeout)
	for {
		f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err == nil {
			_ = f.Close()
			return func() { _ = os.Remove(lockPath) }, nil
		}
		if !os.IsExist(err) {
			return nil, fmt.Errorf("create lock %s: %w", lockPath, err)
		}
		if info, statErr := os.Stat(lockPath); statErr == nil &&
			time.Since(info.ModTime()) > lockStaleAfter {
			_ = os.Remove(lockPath) // holder crashed mid-critical-section; steal it
			continue
		}
		if !time.Now().Before(deadline) {
			return nil, fmt.Errorf("inbox drain lock busy (waited %s)", timeout)
		}
		time.Sleep(lockRetryInterval)
	}
}
