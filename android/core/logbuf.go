package core

import (
	"fmt"
	"strings"
	"sync"
	"time"
)

// logCapacity is the number of entries the diagnostic buffer retains. A connect
// attempt produces on the order of a dozen lines, so this holds many attempts while
// staying small enough to render in a scrollable view and to hand to the clipboard.
const logCapacity = 500

// logBuf is a fixed-size ring of diagnostic lines.
//
// It is deliberately package-level rather than per-Session state: the log exists to
// explain a connect that FAILED, and a failed connect tears the session down. State
// owned by the session would be gone exactly when the user taps "Show logs". The
// process outlives the session, so this does not.
var logBuf = &ringLog{now: time.Now}

type ringLog struct {
	mu      sync.Mutex
	entries []string
	// next is the write cursor; once len(entries) == logCapacity it wraps and
	// overwrites the oldest line.
	next int
	// now is injectable so tests can assert on stable timestamps.
	now func() time.Time
}

// Logf appends a timestamped line to the diagnostic buffer. Safe for concurrent use
// and never blocks on a reader, so it is safe to call from the packet path.
func Logf(format string, args ...any) { logBuf.logf(format, args...) }

// Log appends a line verbatim. Use this for text that is not a format string (Android
// lifecycle events, server messages) so stray %-verbs are not interpreted.
func Log(msg string) { logBuf.logf("%s", msg) }

// LogText returns the retained lines oldest-first, newline-separated.
func LogText() string { return logBuf.text() }

// ClearLog drops all retained lines.
func ClearLog() { logBuf.clear() }

func (r *ringLog) logf(format string, args ...any) {
	line := r.now().UTC().Format("15:04:05.000") + "  " + fmt.Sprintf(format, args...)
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.entries) < logCapacity {
		r.entries = append(r.entries, line)
		r.next = len(r.entries) % logCapacity
		return
	}
	r.entries[r.next] = line
	r.next = (r.next + 1) % logCapacity
}

func (r *ringLog) text() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var b strings.Builder
	// Before the ring wraps, entries are already in order and next == len(entries),
	// so the same rotation walk covers both cases.
	n := len(r.entries)
	for i := 0; i < n; i++ {
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(r.entries[(r.next+i)%n])
	}
	return b.String()
}

func (r *ringLog) clear() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.entries = nil
	r.next = 0
}
