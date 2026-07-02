package localbus

import (
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestAcquireDrainLockMutualExclusion(t *testing.T) {
	bus := t.TempDir()
	release1, err := AcquireDrainLock(bus, "ts1", time.Second)
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}

	// A contender for the SAME inbox lock must not also acquire it while
	// release1 is still held — a short timeout is enough to prove exclusion
	// without slowing the test down.
	if _, err := AcquireDrainLock(bus, "ts1", 50*time.Millisecond); err == nil {
		t.Fatal("second acquire succeeded while lock held — mutual exclusion broken")
	}

	release1()

	// Once released, a new acquire must succeed.
	release2, err := AcquireDrainLock(bus, "ts1", time.Second)
	if err != nil {
		t.Fatalf("acquire after release: %v", err)
	}
	release2()
}

// TestAcquireDrainLockConcurrentOnlyOneAtATime races N goroutines for the same
// inbox lock and asserts at most one ever holds it at once — the core
// guarantee the Go hook drain and the app's escalate path both depend on.
func TestAcquireDrainLockConcurrentOnlyOneAtATime(t *testing.T) {
	bus := t.TempDir()
	const n = 8
	var active int32
	var mu sync.Mutex
	var maxActive int32
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			release, err := AcquireDrainLock(bus, "ts1", 2*time.Second)
			if err != nil {
				t.Errorf("acquire: %v", err)
				return
			}
			cur := atomic.AddInt32(&active, 1)
			mu.Lock()
			if cur > maxActive {
				maxActive = cur
			}
			mu.Unlock()
			time.Sleep(5 * time.Millisecond) // hold briefly so any overlap shows up
			atomic.AddInt32(&active, -1)
			release()
		}()
	}
	wg.Wait()
	if maxActive > 1 {
		t.Fatalf("observed %d concurrent holders, want <= 1", maxActive)
	}
}

// TestAcquireDrainLockDifferentSessionsDontContend: locks are per-session
// (per-inbox), so two different sessions' locks must not block each other.
func TestAcquireDrainLockDifferentSessionsDontContend(t *testing.T) {
	bus := t.TempDir()
	release1, err := AcquireDrainLock(bus, "ts1", time.Second)
	if err != nil {
		t.Fatalf("ts1 acquire: %v", err)
	}
	defer release1()

	release2, err := AcquireDrainLock(bus, "ts2", 200*time.Millisecond)
	if err != nil {
		t.Fatalf("ts2 acquire should not contend with ts1's lock: %v", err)
	}
	release2()
}

// TestAcquireDrainLockStealsStaleLock: a lock file left behind by a holder
// that crashed mid critical section (never called release) must not wedge the
// inbox forever — a contender backdates-detects staleness and steals it.
func TestAcquireDrainLockStealsStaleLock(t *testing.T) {
	bus := t.TempDir()
	release, err := AcquireDrainLock(bus, "ts1", time.Second)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	_ = release // simulate a crash: deliberately never call it

	// Backdate the lock file's mtime past lockStaleAfter instead of sleeping in
	// the test for real.
	lockPath := filepath.Join(InboxDir(bus, "ts1"), ".lock")
	old := time.Now().Add(-2 * lockStaleAfter)
	if err := os.Chtimes(lockPath, old, old); err != nil {
		t.Fatalf("backdate lock mtime: %v", err)
	}

	release2, err := AcquireDrainLock(bus, "ts1", time.Second)
	if err != nil {
		t.Fatalf("expected steal of stale lock, got: %v", err)
	}
	release2()
}

// TestAcquireDrainLockFreshLockNotStolen: a lock held for less than
// lockStaleAfter must NOT be stolen out from under its legitimate holder —
// the staleness override is a crash backstop, not a way to jump the queue.
func TestAcquireDrainLockFreshLockNotStolen(t *testing.T) {
	bus := t.TempDir()
	release, err := AcquireDrainLock(bus, "ts1", time.Second)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	defer release()

	if _, err := AcquireDrainLock(bus, "ts1", 100*time.Millisecond); err == nil {
		t.Fatal("fresh lock was stolen — staleness override fired too early")
	}
}
