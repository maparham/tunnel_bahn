package core

import (
	"math"
	"testing"
)

func approx(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func TestMedian(t *testing.T) {
	if _, ok := median(nil); ok {
		t.Fatal("empty should return ok=false")
	}
	if m, _ := median([]float64{3, 1, 2}); m != 2 {
		t.Fatalf("odd median = %v, want 2", m)
	}
	if m, _ := median([]float64{4, 1, 2, 3}); m != 2.5 {
		t.Fatalf("even median = %v, want 2.5", m)
	}
}

func TestJitter(t *testing.T) {
	// median = 2; deviations = {1,0,1}; mean = 2/3
	j, ok := jitter([]float64{1, 2, 3})
	if !ok || !approx(j, 2.0/3.0) {
		t.Fatalf("jitter = %v ok=%v, want 0.666...", j, ok)
	}
}

func TestThroughputMbps(t *testing.T) {
	if throughputMbps(1_000_000, 0) != 0 {
		t.Fatal("non-positive window must be 0")
	}
	// 1_000_000 bytes * 8 / 1s / 1e6 = 8 Mbps
	if got := throughputMbps(1_000_000, 1); !approx(got, 8) {
		t.Fatalf("mbps = %v, want 8", got)
	}
}
