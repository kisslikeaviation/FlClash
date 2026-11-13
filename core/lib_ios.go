//go:build ios

package core

import (
	"net"
	"os"

	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/constant"
)

// mihomo holds cache.db locked and resolves its path once, so the app's Core pins
// it outside the App Group: a lock held there gets the suspended app killed (0xdead10cc).
func UsePrivateCache(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	constant.SetHomeDir(dir)
	cachefile.Cache()
	return nil
}

func queryProcFsUid(_, _ net.Addr) int {
	return -1
}

func applySystemDNS(_ []string) {}
