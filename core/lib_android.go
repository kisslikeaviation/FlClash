//go:build android

package core

import (
	"core/platform"
	"net"

	"github.com/metacubex/mihomo/dns"
)

func queryProcFsUid(source, target net.Addr) int {
	return platform.QuerySocketUidFromProcFs(source, target)
}

func applySystemDNS(addr []string) {
	dns.UpdateSystemDNS(addr)
	dns.FlushCacheWithDefaultResolver()
}
