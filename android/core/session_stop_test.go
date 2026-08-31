package core

import (
	"testing"
	"time"
)

// Stop used to clear stopCh and return. If it ran before Start had published one there
// was nothing to close, so the cancel was dropped and the session went on to connect
// anyway — the UI showed "Connecting" for an attempt the user had already cancelled.
func TestStopBeforeStartIsLatched(t *testing.T) {
	s := NewSession()
	s.Stop()

	if _, err := s.publishStop(); err == nil {
		t.Fatal("publishStop succeeded after Stop; the cancel was lost")
	}
}

// The ordinary path: Start publishes, Stop closes, and the waiter wakes.
func TestStopUnblocksPublishedChannel(t *testing.T) {
	s := NewSession()
	ch, err := s.publishStop()
	if err != nil {
		t.Fatalf("publishStop: %v", err)
	}
	go s.Stop()

	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal("Stop did not close the published channel")
	}
}

// Stop and the Start teardown both reach the channel; closing it twice would panic and
// take the process down with it.
func TestStopIsIdempotentWithRetire(t *testing.T) {
	s := NewSession()
	ch, err := s.publishStop()
	if err != nil {
		t.Fatalf("publishStop: %v", err)
	}
	s.Stop()
	s.Stop()
	s.retireStop()
	s.retireStop()

	select {
	case <-ch:
	default:
		t.Fatal("channel not closed")
	}
}

// A failed connect retires the channel without anyone having called Stop; that must
// still wake the watcher goroutine that cancels the session context, or it leaks.
func TestRetireStopClosesChannelWhenStopNeverRan(t *testing.T) {
	s := NewSession()
	ch, err := s.publishStop()
	if err != nil {
		t.Fatalf("publishStop: %v", err)
	}
	s.retireStop()

	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal("retireStop left the channel open")
	}
}
