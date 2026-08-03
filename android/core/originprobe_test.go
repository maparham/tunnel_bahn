package core

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestProbeOriginHappyPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ip":"1.2.3.4","city":"Tehran","country":"IR"}`))
	}))
	defer srv.Close()

	ip, city, country, err := probeOriginAt(context.Background(), srv.URL, srv.Client())
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if ip != "1.2.3.4" || city != "Tehran" || country != "IR" {
		t.Fatalf("got %q/%q/%q", ip, city, country)
	}
}

func TestProbeOriginNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	if _, _, _, err := probeOriginAt(context.Background(), srv.URL, srv.Client()); err == nil {
		t.Fatal("expected error on 500")
	}
}

func TestProbeOriginBadBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`not json`))
	}))
	defer srv.Close()
	if _, _, _, err := probeOriginAt(context.Background(), srv.URL, srv.Client()); err == nil {
		t.Fatal("expected error on malformed body")
	}
}

func TestProbeOriginTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
		_, _ = w.Write([]byte(`{"ip":"1.2.3.4"}`))
	}))
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, _, _, err := probeOriginAt(ctx, srv.URL, srv.Client()); err == nil {
		t.Fatal("expected timeout error")
	}
}
