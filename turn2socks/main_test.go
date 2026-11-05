package main

import (
	"context"
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha1"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// ───────────── 模拟 TURN 服务器 (RFC 5766/6062 子集，独立实现 MESSAGE-INTEGRITY 校验) ─────────────

type mock struct {
	ln       net.Listener
	user     string
	pass     string
	lifetime uint32 // Allocate/Refresh 返回的 LIFETIME(秒)

	allocs, refreshes, perms, connects int32
	cidSeq                             int32

	mu                   sync.Mutex
	permPeers, connPeers []string
	pend                 map[string]net.Conn
	ctrls                []net.Conn
	nonce                string

	failPerm  bool // CreatePermission 返回 403
	staleOnce int32
	fakeV6    bool // IPv6 目标不真实拨号 (沙箱可能没有 IPv6)
}

func verifyMI(raw, key []byte) bool {
	off := 20
	for off+4 <= len(raw) {
		t := binary.BigEndian.Uint16(raw[off:])
		l := int(binary.BigEndian.Uint16(raw[off+2:]))
		if t == atMessageIntegrity && l == 20 {
			b := append([]byte{}, raw[:off]...)
			binary.BigEndian.PutUint16(b[2:], uint16(off-20+24))
			m := hmac.New(sha1.New, key)
			m.Write(b)
			return hmac.Equal(m.Sum(nil), raw[off+4:off+24])
		}
		off += 4 + l + (4-l%4)%4
	}
	return false
}

func decodePeer(v []byte, tx [12]byte) string {
	port := binary.BigEndian.Uint16(v[2:4]) ^ 0x2112
	ck := make([]byte, 4)
	binary.BigEndian.PutUint32(ck, magicCookie)
	if v[1] == 1 {
		ip := make(net.IP, 4)
		for i := 0; i < 4; i++ {
			ip[i] = v[4+i] ^ ck[i]
		}
		return net.JoinHostPort(ip.String(), fmt.Sprint(port))
	}
	pad := append(append([]byte{}, ck...), tx[:]...)
	ip := make(net.IP, 16)
	for i := 0; i < 16; i++ {
		ip[i] = v[4+i] ^ pad[i]
	}
	return net.JoinHostPort(ip.String(), fmt.Sprint(port))
}

func newMock(t *testing.T) *mock {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	m := &mock{ln: ln, user: "u", pass: "p", lifetime: 600, pend: map[string]net.Conn{}, nonce: "n0nce"}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go m.handle(c)
		}
	}()
	return m
}

func errResp(code uint16, tx [12]byte, typ uint16, extra ...[]byte) []byte {
	ec := append([]byte{0, 0, byte(code / 100), byte(code % 100)}, []byte("reason")...)
	return buildStunMsg(typ, tx, append([][]byte{buildAttr(atErrorCode, ec)}, extra...)...)
}

func u32(v uint32) []byte { b := make([]byte, 4); binary.BigEndian.PutUint32(b, v); return b }

func (m *mock) curNonce() string { m.mu.Lock(); defer m.mu.Unlock(); return m.nonce }

func (m *mock) closeControlConns() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, c := range m.ctrls {
		c.Close()
	}
	m.ctrls = nil
}

// authed 校验 MI 与 nonce；不通过时返回应答报文
func (m *mock) authed(msg *stunMessage, typ uint16) []byte {
	key := md5.Sum([]byte(m.user + ":test:" + m.pass))
	if !verifyMI(msg.Raw, key[:]) {
		return errResp(401, msg.TxID, typ|0x0110, buildAttr(atRealm, []byte("test")), buildAttr(atNonce, []byte(m.curNonce())))
	}
	if string(msg.Attrs[atNonce]) != m.curNonce() {
		return errResp(438, msg.TxID, typ|0x0110, buildAttr(atRealm, []byte("test")), buildAttr(atNonce, []byte(m.curNonce())))
	}
	return nil
}

func (m *mock) handle(c net.Conn) {
	for {
		msg, err := readStun(c)
		if err != nil {
			c.Close()
			return
		}
		switch msg.MsgType {
		case mtAllocateRequest:
			if _, has := msg.Attrs[atMessageIntegrity]; !has {
				c.Write(errResp(401, msg.TxID, mtAllocateError, buildAttr(atRealm, []byte("test")), buildAttr(atNonce, []byte(m.curNonce()))))
				continue
			}
			if bad := m.authed(msg, mtAllocateRequest); bad != nil {
				c.Write(bad)
				continue
			}
			atomic.AddInt32(&m.allocs, 1)
			m.mu.Lock()
			m.ctrls = append(m.ctrls, c)
			m.mu.Unlock()
			c.Write(buildStunMsg(mtAllocateSuccess, msg.TxID, buildAttr(atLifetime, u32(m.lifetime))))
		case mtRefreshRequest:
			if bad := m.authed(msg, mtRefreshRequest); bad != nil {
				c.Write(bad)
				continue
			}
			atomic.AddInt32(&m.refreshes, 1)
			c.Write(buildStunMsg(mtRefreshSuccess, msg.TxID, buildAttr(atLifetime, u32(m.lifetime))))
		case mtCreatePermRequest:
			atomic.AddInt32(&m.perms, 1)
			if atomic.CompareAndSwapInt32(&m.staleOnce, 1, 0) { // 模拟 nonce 过期
				m.mu.Lock()
				m.nonce = "n1-rotated"
				m.mu.Unlock()
				c.Write(errResp(438, msg.TxID, 0x0118, buildAttr(atRealm, []byte("test")), buildAttr(atNonce, []byte(m.curNonce()))))
				continue
			}
			if bad := m.authed(msg, mtCreatePermRequest); bad != nil {
				c.Write(bad)
				continue
			}
			m.mu.Lock()
			m.permPeers = append(m.permPeers, decodePeer(msg.Attrs[atXorPeerAddress], msg.TxID))
			m.mu.Unlock()
			if m.failPerm {
				c.Write(errResp(403, msg.TxID, 0x0118))
				continue
			}
			c.Write(buildStunMsg(mtCreatePermSuccess, msg.TxID))
		case mtConnectRequest:
			if bad := m.authed(msg, mtConnectRequest); bad != nil {
				c.Write(bad)
				continue
			}
			atomic.AddInt32(&m.connects, 1)
			peer := decodePeer(msg.Attrs[atXorPeerAddress], msg.TxID)
			m.mu.Lock()
			m.connPeers = append(m.connPeers, peer)
			m.mu.Unlock()
			var pc net.Conn
			if !(m.fakeV6 && strings.HasPrefix(peer, "[")) {
				var err error
				pc, err = net.DialTimeout("tcp", peer, 2*time.Second)
				if err != nil {
					c.Write(errResp(447, msg.TxID, 0x011A))
					continue
				}
			}
			cid := u32(uint32(atomic.AddInt32(&m.cidSeq, 1)))
			m.mu.Lock()
			if pc != nil {
				m.pend[hex.EncodeToString(cid)] = pc
			}
			m.mu.Unlock()
			c.Write(buildStunMsg(mtConnectSuccess, msg.TxID, buildAttr(atConnectionID, cid)))
		case mtConnectionBindRequest:
			if bad := m.authed(msg, mtConnectionBindRequest); bad != nil {
				c.Write(bad)
				continue
			}
			m.mu.Lock()
			pc := m.pend[hex.EncodeToString(msg.Attrs[atConnectionID])]
			m.mu.Unlock()
			if pc == nil {
				c.Write(errResp(437, msg.TxID, 0x011B))
				continue
			}
			c.Write(buildStunMsg(mtConnectionBindSuccess, msg.TxID))
			go io.Copy(pc, c)
			io.Copy(c, pc)
			return
		}
	}
}

func echoServer(t *testing.T) int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go io.Copy(c, c)
		}
	}()
	return l.Addr().(*net.TCPAddr).Port
}

func newClient(m *mock, pass string) *TurnClient {
	c := &TurnClient{Server: m.ln.Addr().String(), Username: "u", Password: pass, Timeout: 5 * time.Second}
	return c
}

// startSocks 启动本地 SOCKS5，返回监听地址
func startSocks(t *testing.T, tc *TurnClient) string {
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := l.Addr().String()
	l.Close()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	s := &SocksServer{ListenAddr: addr, Turn: tc}
	go s.Run(ctx)
	for i := 0; i < 50; i++ {
		if c, err := net.Dial("tcp", addr); err == nil {
			c.Close()
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	return addr
}

func socksEcho(addr string, req []byte) error {
	c, err := net.Dial("tcp", addr)
	if err != nil {
		return err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(8 * time.Second))
	c.Write([]byte{5, 1, 0})
	b := make([]byte, 2)
	if _, err := io.ReadFull(c, b); err != nil {
		return err
	}
	c.Write(req)
	rep := make([]byte, 10)
	if _, err := io.ReadFull(c, rep); err != nil {
		return err
	}
	if rep[1] != 0 {
		return fmt.Errorf("socks reply code %d", rep[1])
	}
	c.Write([]byte("hello"))
	got := make([]byte, 5)
	if _, err := io.ReadFull(c, got); err != nil {
		return err
	}
	if string(got) != "hello" {
		return fmt.Errorf("echo mismatch %q", got)
	}
	return nil
}

func reqV4(port int) []byte {
	return []byte{5, 1, 0, 1, 127, 0, 0, 1, byte(port >> 8), byte(port)}
}

// ───────────── 测试 ─────────────

func TestSharedAllocationAcrossConnections(t *testing.T) {
	m := newMock(t)
	port := echoServer(t)
	addr := startSocks(t, newClient(m, "p"))

	for i := 0; i < 5; i++ { // 顺序 5 个连接
		if err := socksEcho(addr, reqV4(port)); err != nil {
			t.Fatalf("顺序连接 %d 失败: %v", i+1, err)
		}
	}
	var wg sync.WaitGroup // 并发 20 个连接
	errs := make(chan error, 20)
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); errs <- socksEcho(addr, reqV4(port)) }()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("并发连接失败: %v", err)
		}
	}
	if a := atomic.LoadInt32(&m.allocs); a != 1 {
		t.Fatalf("25 个 SOCKS 连接应只产生 1 次 Allocate，实际 %d", a)
	}
	t.Logf("25 个 SOCKS 连接 => Allocate=%d, Connect=%d", m.allocs, m.connects)
}

func TestRefreshKeepsAllocationAlive(t *testing.T) {
	m := newMock(t)
	m.lifetime = 2 // 2 秒生命周期 => 每 1 秒 Refresh
	port := echoServer(t)
	addr := startSocks(t, newClient(m, "p"))
	if err := socksEcho(addr, reqV4(port)); err != nil {
		t.Fatal(err)
	}
	time.Sleep(3500 * time.Millisecond)
	if r := atomic.LoadInt32(&m.refreshes); r < 2 {
		t.Fatalf("期望至少 2 次 Refresh，实际 %d", r)
	}
	if err := socksEcho(addr, reqV4(port)); err != nil {
		t.Fatalf("Refresh 之后新连接失败: %v", err)
	}
	if a := atomic.LoadInt32(&m.allocs); a != 1 {
		t.Fatalf("期间不应重新 Allocate，实际 %d", a)
	}
	t.Logf("3.5 秒内 Refresh=%d 次，Allocation 保持不变", m.refreshes)
}

func TestSessionRecoversAfterControlConnClosed(t *testing.T) {
	m := newMock(t)
	port := echoServer(t)
	addr := startSocks(t, newClient(m, "p"))
	if err := socksEcho(addr, reqV4(port)); err != nil {
		t.Fatal(err)
	}
	m.closeControlConns() // 服务器端断开控制连接
	time.Sleep(100 * time.Millisecond)
	if err := socksEcho(addr, reqV4(port)); err != nil {
		t.Fatalf("控制连接断开后应自动重建会话: %v", err)
	}
	if a := atomic.LoadInt32(&m.allocs); a != 2 {
		t.Fatalf("期望重新 Allocate 一次 (共 2)，实际 %d", a)
	}
}

func TestStaleNonceRetry(t *testing.T) {
	m := newMock(t)
	port := echoServer(t)
	addr := startSocks(t, newClient(m, "p"))
	atomic.StoreInt32(&m.staleOnce, 1)
	if err := socksEcho(addr, reqV4(port)); err != nil {
		t.Fatalf("438 Stale Nonce 后应自动重试: %v", err)
	}
	if p := atomic.LoadInt32(&m.perms); p != 2 {
		t.Fatalf("CreatePermission 应发送 2 次 (含重试)，实际 %d", p)
	}
}

func TestIPv6PeerEncodedPerRequest(t *testing.T) {
	m := newMock(t)
	m.fakeV6 = true
	tc := newClient(m, "p")
	want := "[2001:db8::1234]:443"
	_, _ = tc.DialRelay(context.Background(), net.ParseIP("2001:db8::1234"), 443) // 后续 bind 会因无真实对端而失败，这里只关心请求编码
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.permPeers) != 1 || len(m.connPeers) != 1 {
		t.Fatalf("未记录到请求: perm=%v conn=%v", m.permPeers, m.connPeers)
	}
	if m.permPeers[0] != want || m.connPeers[0] != want {
		t.Fatalf("IPv6 对端解码不一致: CreatePermission=%s Connect=%s 期望=%s", m.permPeers[0], m.connPeers[0], want)
	}
}

func TestDomainTarget(t *testing.T) {
	m := newMock(t)
	port := echoServer(t)
	addr := startSocks(t, newClient(m, "p"))
	d := "localhost"
	req := append([]byte{5, 1, 0, 3, byte(len(d))}, []byte(d)...)
	req = append(req, byte(port>>8), byte(port))
	if err := socksEcho(addr, req); err != nil {
		t.Fatalf("域名目标失败: %v", err)
	}
}

func TestErrorDiagnostics(t *testing.T) {
	m := newMock(t)
	m.failPerm = true
	_, err := newClient(m, "p").DialRelay(context.Background(), net.ParseIP("127.0.0.1"), 80)
	if err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("应包含服务器返回的 403，实际: %v", err)
	}
	t.Logf("CreatePermission 被拒: %v", err)

	m2 := newMock(t)
	_, err = newClient(m2, "wrong").DialRelay(context.Background(), net.ParseIP("127.0.0.1"), 80)
	if err == nil || !strings.Contains(err.Error(), "401") {
		t.Fatalf("密码错误应报 401，实际: %v", err)
	}
	t.Logf("密码错误: %v", err)
}

func TestNoAuthServer(t *testing.T) {
	// 无需认证的服务器：客户端不带用户名也能完成 Allocate (服务端对无 MI 请求直接放行)
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		msg, _ := readStun(c)
		c.Write(buildStunMsg(mtAllocateSuccess, msg.TxID))
		msg, _ = readStun(c)
		c.Write(errResp(403, msg.TxID, 0x0118))
	}()
	tc := &TurnClient{Server: ln.Addr().String(), Timeout: 3 * time.Second}
	_, err := tc.DialRelay(context.Background(), net.ParseIP("127.0.0.1"), 1)
	if err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("期望到达 CreatePermission 阶段并返回 403，实际: %v", err)
	}
}
