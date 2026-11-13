//go:build ios

package mobile

import (
	"core"
	"runtime/debug"
)

// The Go runtime reads GOMEMLIMIT and GOGC before any Swift code runs, so the
// tunnel extension has to set its budget through the runtime's API.
func SetMemoryBudget(limit int64, gcPercent int32) {
	debug.SetMemoryLimit(limit)
	debug.SetGCPercent(int(gcPercent))
}

func UsePrivateCache(dir string) error {
	return core.UsePrivateCache(dir)
}
