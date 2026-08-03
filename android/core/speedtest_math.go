package core

import "sort"

// median returns the standard median; even counts average the middle pair.
// ok is false for empty input.
func median(values []float64) (float64, bool) {
	if len(values) == 0 {
		return 0, false
	}
	s := append([]float64(nil), values...)
	sort.Float64s(s)
	mid := len(s) / 2
	if len(s)%2 == 0 {
		return (s[mid-1] + s[mid]) / 2, true
	}
	return s[mid], true
}

// jitter is the mean absolute deviation from the median. ok is false for empty input.
func jitter(values []float64) (float64, bool) {
	m, ok := median(values)
	if !ok {
		return 0, false
	}
	var sum float64
	for _, v := range values {
		d := v - m
		if d < 0 {
			d = -d
		}
		sum += d
	}
	return sum / float64(len(values)), true
}

// throughputMbps is megabits per second from a byte count over a wall-clock window.
// Zero for a non-positive window.
func throughputMbps(bytes int64, seconds float64) float64 {
	if seconds <= 0 {
		return 0
	}
	return float64(bytes) * 8 / seconds / 1_000_000
}
