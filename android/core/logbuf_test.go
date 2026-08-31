package core

import (
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
)

func newTestLog() *ringLog {
	t0 := time.Date(2026, 8, 30, 12, 0, 0, 0, time.UTC)
	return &ringLog{now: func() time.Time { return t0 }}
}

func TestRingLogKeepsOrderAndTimestamps(t *testing.T) {
	r := newTestLog()
	r.logf("first")
	r.logf("n=%d", 2)

	got := r.text()
	want := "12:00:00.000  first\n12:00:00.000  n=2"
	if got != want {
		t.Fatalf("text() =\n%q\nwant\n%q", got, want)
	}
}

func TestRingLogEmpty(t *testing.T) {
	if got := newTestLog().text(); got != "" {
		t.Fatalf("empty log text = %q, want empty", got)
	}
}

// The buffer is bounded, so a long-running session cannot grow it without limit. The
// lines that survive must be the most recent ones: the tail explains the failure the
// user is looking at, the head is ancient history.
func TestRingLogDropsOldestWhenFull(t *testing.T) {
	r := newTestLog()
	for i := 0; i < logCapacity+10; i++ {
		r.logf("line-%d", i)
	}

	lines := strings.Split(r.text(), "\n")
	if len(lines) != logCapacity {
		t.Fatalf("retained %d lines, want %d", len(lines), logCapacity)
	}
	if !strings.HasSuffix(lines[0], fmt.Sprintf("line-%d", 10)) {
		t.Errorf("oldest retained line = %q, want line-10", lines[0])
	}
	last := lines[len(lines)-1]
	if !strings.HasSuffix(last, fmt.Sprintf("line-%d", logCapacity+9)) {
		t.Errorf("newest retained line = %q, want line-%d", last, logCapacity+9)
	}
}

func TestRingLogClear(t *testing.T) {
	r := newTestLog()
	r.logf("something")
	r.clear()
	if got := r.text(); got != "" {
		t.Fatalf("after clear text = %q, want empty", got)
	}
	// The cursor must reset too, or the next writes land at a stale offset.
	r.logf("after")
	if got := r.text(); !strings.HasSuffix(got, "after") {
		t.Fatalf("after clear+write text = %q, want it to end with %q", got, "after")
	}
}

// Logf is called from the packet and carrier paths, so concurrent writes must not race
// or lose the bound. Run with -race to make this meaningful.
func TestRingLogConcurrentWrites(t *testing.T) {
	r := newTestLog()
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			for j := 0; j < 200; j++ {
				r.logf("w%d-%d", n, j)
			}
			_ = r.text()
		}(i)
	}
	wg.Wait()

	if got := len(strings.Split(r.text(), "\n")); got != logCapacity {
		t.Fatalf("retained %d lines, want %d", got, logCapacity)
	}
}
