using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.ServiceProcess;
using System.Text;
using System.Threading;

namespace DnsonlienDns
{
    public class Program
    {
        internal static string LogDir = AppDomain.CurrentDomain.BaseDirectory;

        public static void Main(string[] args)
        {
            bool asService = false;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--run" || args[i] == "--service") asService = true;
                else if (args[i] == "--logdir" && i + 1 < args.Length) LogDir = args[++i];
            }
            if (LogDir != null && !Directory.Exists(LogDir))
            {
                try { Directory.CreateDirectory(LogDir); } catch { }
            }

            if (asService)
            {
                ServiceBase.Run(new DnsService());
                return;
            }
            // foreground mode (used by the installer for a quick pre-test)
            Proxy.Start();
            Console.WriteLine("dnsonlien-dns running in foreground on 127.0.0.1:53");
            Thread.Sleep(Timeout.Infinite);
        }

        internal static void Log(string msg)
        {
            try
            {
                lock (LogLock)
                {
                    string dir = LogDir ?? AppDomain.CurrentDomain.BaseDirectory;
                    File.AppendAllText(Path.Combine(dir, "dnsonlien-dns.log"),
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + "\r\n");
                }
            }
            catch { }
        }

        internal static readonly object LogLock = new object();
    }

    class DnsService : ServiceBase
    {
        public DnsService()
        {
            ServiceName = "dnsonlien-dns";
            CanStop = true;
            CanShutdown = true;
            AutoLog = false;
        }

        protected override void OnStart(string[] args) { Proxy.Start(); }
        protected override void OnStop() { Proxy.Stop(); }
        protected override void OnShutdown() { Proxy.Stop(); }
    }

    static class Proxy
    {
        const int LISTEN_PORT = 53;
        static readonly string[] DOH_HOSTS = { "cloudflare-dns.com", "dns.google" };
        static readonly string[] BOOTSTRAP_DNS = { "8.8.8.8", "1.1.1.1" };
        static readonly Dictionary<string, string[]> FALLBACK_IPS = new Dictionary<string, string[]>
        {
            { "cloudflare-dns.com", new[] { "104.16.248.249", "104.16.249.249" } },
            { "dns.google", new[] { "8.8.8.8", "8.8.4.4" } }
        };

        static readonly DohClient Doh = new DohClient(DOH_HOSTS, BOOTSTRAP_DNS, FALLBACK_IPS);
        static readonly ConcurrentDictionary<string, CacheEntry> Cache = new ConcurrentDictionary<string, CacheEntry>();
        static readonly object UdpLock = new object();
        static readonly List<object> Listeners = new List<object>();
        static volatile bool StopFlag;

        public static void Start()
        {
            StopFlag = false;
            Doh.WarmUp();
            StartListener(IPAddress.Loopback);
            StartListener(IPAddress.IPv6Loopback);
            Program.Log("listeners up (IPv4 + IPv6 loopback)");
        }

        public static void Stop()
        {
            StopFlag = true;
            lock (Listeners)
            {
                foreach (object l in Listeners)
                {
                    try { if (l is UdpClient) ((UdpClient)l).Close(); } catch { }
                    try { if (l is TcpListener) ((TcpListener)l).Stop(); } catch { }
                }
                Listeners.Clear();
            }
            Program.Log("stopped");
        }

        static void StartListener(IPAddress addr)
        {
            try
            {
                var udp = new UdpClient(new IPEndPoint(addr, LISTEN_PORT));
                var tcp = new TcpListener(addr, LISTEN_PORT);
                tcp.Start();
                lock (Listeners) { Listeners.Add(udp); Listeners.Add(tcp); }
                var tu = new Thread(() => UdpLoop(udp)) { IsBackground = true };
                var tt = new Thread(() => TcpLoop(tcp)) { IsBackground = true };
                tu.Start();
                tt.Start();
            }
            catch (SocketException) { Program.Log("listener unavailable on " + addr + ", skipped"); }
        }

        static void UdpLoop(UdpClient udp)
        {
            while (!StopFlag)
            {
                try
                {
                    var remote = new IPEndPoint(IPAddress.Any, 0);
                    byte[] data = udp.Receive(ref remote);
                    byte[] query = (byte[])data.Clone();
                    IPEndPoint target = remote;
                    ThreadPool.QueueUserWorkItem(o =>
                    {
                        try
                        {
                            byte[] resp = Resolve(query);
                            if (resp != null)
                            {
                                lock (UdpLock) udp.Send(resp, resp.Length, target);
                            }
                        }
                        catch { }
                    });
                }
                catch (SocketException)
                {
                    if (!StopFlag) Thread.Sleep(100);
                }
            }
        }

        static void TcpLoop(TcpListener tcp)
        {
            while (!StopFlag)
            {
                try
                {
                    var client = tcp.AcceptTcpClient();
                    ThreadPool.QueueUserWorkItem(o =>
                    {
                        try { HandleTcp(client); }
                        catch { }
                        finally { try { client.Close(); } catch { } }
                    });
                }
                catch (SocketException)
                {
                    if (!StopFlag) Thread.Sleep(100);
                }
            }
        }

        static void HandleTcp(TcpClient c)
        {
            try
            {
                c.ReceiveTimeout = 10000;
                var ns = c.GetStream();
                byte[] lenBuf = new byte[2];
                if (!ReadFully(ns, lenBuf, 0, 2)) return;
                int len = (lenBuf[0] << 8) | lenBuf[1];
                if (len <= 0 || len > 4096) return;
                byte[] query = new byte[len];
                if (!ReadFully(ns, query, 0, len)) return;
                byte[] resp = Resolve(query);
                if (resp != null)
                {
                    byte[] outLen = new byte[] { (byte)(resp.Length >> 8), (byte)(resp.Length & 0xFF) };
                    ns.Write(outLen, 0, 2);
                    ns.Write(resp, 0, resp.Length);
                    ns.Flush();
                }
            }
            finally { try { c.Close(); } catch { } }
        }

        static byte[] Resolve(byte[] query)
        {
            byte[] key = (byte[])query.Clone();
            key[0] = 0; key[1] = 0;
            string k = Convert.ToBase64String(key);

            CacheEntry ce;
            if (Cache.TryGetValue(k, out ce) && DateTime.UtcNow < ce.Expires)
            {
                byte[] hit = (byte[])ce.Response.Clone();
                hit[0] = query[0]; hit[1] = query[1];
                return hit;
            }

            byte[] resp = Doh.Query(query);
            if (resp == null || resp.Length < 12) return null;

            int ttl = DnsParse.GetMinTtl(resp);
            if (ttl < 5) ttl = 5;
            if (ttl > 300) ttl = 300;

            byte[] cached = (byte[])resp.Clone();
            cached[0] = 0; cached[1] = 0;
            Cache[k] = new CacheEntry { Response = cached, Expires = DateTime.UtcNow.AddSeconds(ttl) };

            resp[0] = query[0]; resp[1] = query[1];
            return resp;
        }

        static bool ReadFully(Stream s, byte[] buf, int off, int count)
        {
            int got = 0;
            while (got < count)
            {
                int r = s.Read(buf, off + got, count - got);
                if (r <= 0) return false;
                got += r;
            }
            return true;
        }

        class CacheEntry
        {
            public byte[] Response;
            public DateTime Expires;
        }
    }

    class DohClient
    {
        readonly string[] _hosts;
        readonly string[] _bootstrap;
        readonly Dictionary<string, string[]> _fallback;
        readonly Dictionary<string, string> _ipCache = new Dictionary<string, string>();
        readonly object _lock = new object();

        TcpClient _tcp;
        SslStream _ssl;
        string _host;

        public DohClient(string[] hosts, string[] bootstrap, Dictionary<string, string[]> fallback)
        {
            _hosts = hosts;
            _bootstrap = bootstrap;
            _fallback = fallback;
        }

        public void WarmUp()
        {
            foreach (string h in _hosts) GetIp(h);
        }

        string GetIp(string host)
        {
            string cached;
            if (_ipCache.TryGetValue(host, out cached)) return cached;
            string ip = DnsParse.ResolveHostUdp(host, _bootstrap);
            if (ip == null)
            {
                string[] fb;
                if (_fallback.TryGetValue(host, out fb) && fb.Length > 0) ip = fb[0];
            }
            if (ip != null) _ipCache[host] = ip;
            return ip;
        }

        public byte[] Query(byte[] query)
        {
            for (int round = 0; round < 2; round++)
            {
                foreach (string host in _hosts)
                {
                    try
                    {
                        byte[] r = QueryHost(host, query);
                        if (r != null && r.Length >= 12) return r;
                    }
                    catch (Exception ex) { Program.Log("DoH " + host + ": " + ex.Message); }
                }
                if (round == 0)
                {
                    foreach (string h in _hosts) _ipCache.Remove(h);
                    WarmUp();
                }
            }
            return null;
        }

        byte[] QueryHost(string host, byte[] query)
        {
            lock (_lock)
            {
                if (_tcp == null || !_tcp.Connected || host != _host)
                {
                    CloseConn();
                    CreateConn(host);
                }
                byte[] request = BuildRequest(host, query);
                try
                {
                    _ssl.Write(request, 0, request.Length);
                    _ssl.Flush();
                    byte[] body = ReadResponse(_ssl);
                    if (body == null)
                    {
                        CloseConn();
                        return null;
                    }
                    return body;
                }
                catch
                {
                    CloseConn();
                    throw;
                }
            }
        }

        void CreateConn(string host)
        {
            string ip = GetIp(host);
            if (ip == null) throw new IOException("no IP for " + host);
            _tcp = new TcpClient();
            _tcp.Connect(ip, 443);
            _tcp.NoDelay = true;
            _ssl = new SslStream(_tcp.GetStream(), false);
            _ssl.ReadTimeout = 10000;
            _ssl.WriteTimeout = 10000;
            _ssl.AuthenticateAsClient(host, null, SslProtocols.Tls12, false);
            _host = host;
        }

        void CloseConn()
        {
            try { if (_ssl != null) _ssl.Close(); } catch { }
            try { if (_tcp != null) _tcp.Close(); } catch { }
            _ssl = null; _tcp = null; _host = null;
        }

        static byte[] BuildRequest(string host, byte[] query)
        {
            var sb = new StringBuilder();
            sb.Append("POST /dns-query HTTP/1.1\r\n");
            sb.Append("Host: ").Append(host).Append("\r\n");
            sb.Append("Content-Type: application/dns-message\r\n");
            sb.Append("Accept: application/dns-message\r\n");
            sb.Append("Accept-Encoding: identity\r\n");
            sb.Append("User-Agent: dnsonlien-dns/1.0\r\n");
            sb.Append("Content-Length: ").Append(query.Length).Append("\r\n");
            sb.Append("Connection: keep-alive\r\n");
            sb.Append("\r\n");
            byte[] head = Encoding.ASCII.GetBytes(sb.ToString());
            var ms = new MemoryStream(head.Length + query.Length);
            ms.Write(head, 0, head.Length);
            ms.Write(query, 0, query.Length);
            return ms.ToArray();
        }

        static byte[] ReadResponse(Stream s)
        {
            var statusLine = ReadLine(s);
            if (statusLine == null) return null;
            string[] parts = statusLine.Split(' ');
            if (parts.Length < 2 || parts[1] != "200") return null;

            long contentLength = -1;
            bool chunked = false;
            string line;
            while ((line = ReadLine(s)) != null && line.Length > 0)
            {
                int idx = line.IndexOf(':');
                if (idx < 0) continue;
                string name = line.Substring(0, idx).Trim().ToLowerInvariant();
                string val = line.Substring(idx + 1).Trim();
                if (name == "content-length") long.TryParse(val, out contentLength);
                else if (name == "transfer-encoding" && val.ToLowerInvariant().Contains("chunked")) chunked = true;
            }

            byte[] body;
            if (chunked)
            {
                body = ReadChunked(s);
            }
            else if (contentLength >= 0)
            {
                body = new byte[contentLength];
                if (!ReadFully(s, body, 0, body.Length)) return null;
            }
            else
            {
                var ms = new MemoryStream();
                byte[] buf = new byte[8192];
                int n;
                while ((n = s.Read(buf, 0, buf.Length)) > 0) ms.Write(buf, 0, n);
                body = ms.ToArray();
            }
            return body;
        }

        static string ReadLine(Stream s)
        {
            var sb = new StringBuilder();
            int prev = -1;
            while (true)
            {
                int b = s.ReadByte();
                if (b < 0) return sb.Length == 0 ? null : sb.ToString();
                if (prev == 13 && b == 10)
                {
                    if (sb.Length > 0) sb.Length -= 1;
                    return sb.ToString();
                }
                sb.Append((char)b);
                prev = b;
                if (sb.Length > 32768) return null;
            }
        }

        static byte[] ReadChunked(Stream s)
        {
            var ms = new MemoryStream();
            while (true)
            {
                string sizeLine = ReadLine(s);
                if (sizeLine == null) return null;
                int semi = sizeLine.IndexOf(';');
                if (semi >= 0) sizeLine = sizeLine.Substring(0, semi);
                int size;
                if (!int.TryParse(sizeLine.Trim(), System.Globalization.NumberStyles.HexNumber, null, out size)) return null;
                if (size == 0)
                {
                    while (true) { string t = ReadLine(s); if (t == null || t.Length == 0) break; }
                    break;
                }
                byte[] chunk = new byte[size];
                if (!ReadFully(s, chunk, 0, size)) return null;
                ms.Write(chunk, 0, chunk.Length);
                s.ReadByte(); s.ReadByte();
            }
            return ms.ToArray();
        }

        static bool ReadFully(Stream s, byte[] buf, int off, int count)
        {
            int got = 0;
            while (got < count)
            {
                int r = s.Read(buf, off + got, count - got);
                if (r <= 0) return false;
                got += r;
            }
            return true;
        }
    }

    static class DnsParse
    {
        public static string ResolveHostUdp(string host, string[] servers)
        {
            byte[] query = BuildQuery(host);
            foreach (string server in servers)
            {
                try
                {
                    var udp = new UdpClient();
                    udp.Client.ReceiveTimeout = 1500;
                    udp.Connect(IPAddress.Parse(server), 53);
                    udp.Send(query, query.Length);
                    var remote = new IPEndPoint(IPAddress.Any, 0);
                    byte[] resp = udp.Receive(ref remote);
                    udp.Close();
                    string ip = FirstARecord(resp);
                    if (ip != null) return ip;
                }
                catch { }
            }
            return null;
        }

        static byte[] BuildQuery(string host)
        {
            var parts = new List<byte>();
            parts.Add(0xAA); parts.Add(0xBB);
            parts.Add(0x01); parts.Add(0x00);
            parts.Add(0x00); parts.Add(0x01);
            parts.AddRange(new byte[] { 0, 0, 0, 0, 0, 0 });
            foreach (string label in host.Split('.'))
            {
                parts.Add((byte)label.Length);
                parts.AddRange(Encoding.ASCII.GetBytes(label));
            }
            parts.Add(0x00);
            parts.AddRange(new byte[] { 0x00, 0x01 });
            parts.AddRange(new byte[] { 0x00, 0x01 });
            return parts.ToArray();
        }

        static string FirstARecord(byte[] resp)
        {
            if (resp == null || resp.Length < 12) return null;
            int qd = (resp[4] << 8) | resp[5];
            int an = (resp[6] << 8) | resp[7];
            if (an == 0) return null;
            int pos = 12;
            for (int i = 0; i < qd; i++)
            {
                pos = SkipName(resp, pos);
                pos += 4;
            }
            for (int i = 0; i < an; i++)
            {
                pos = SkipName(resp, pos);
                if (pos + 10 > resp.Length) return null;
                int type = (resp[pos] << 8) | resp[pos + 1];
                int cls = (resp[pos + 2] << 8) | resp[pos + 3];
                int rdlen = (resp[pos + 8] << 8) | resp[pos + 9];
                pos += 10;
                if (type == 1 && cls == 1 && rdlen == 4 && pos + 4 <= resp.Length)
                {
                    return string.Join(".", resp[pos], resp[pos + 1], resp[pos + 2], resp[pos + 3]);
                }
                pos += rdlen;
            }
            return null;
        }

        public static int GetMinTtl(byte[] resp)
        {
            if (resp == null || resp.Length < 12) return 60;
            try
            {
                int qd = (resp[4] << 8) | resp[5];
                int an = (resp[6] << 8) | resp[7];
                int ns = (resp[8] << 8) | resp[9];
                int pos = 12;
                for (int i = 0; i < qd; i++) { pos = SkipName(resp, pos); pos += 4; }
                int min = int.MaxValue;
                for (int i = 0; i < an + ns; i++)
                {
                    pos = SkipName(resp, pos);
                    if (pos + 10 > resp.Length) break;
                    int ttl = (resp[pos + 4] << 24) | (resp[pos + 5] << 16) | (resp[pos + 6] << 8) | resp[pos + 7];
                    int rdlen = (resp[pos + 8] << 8) | resp[pos + 9];
                    pos += 10;
                    if (ttl < min) min = ttl;
                    pos += rdlen;
                }
                return min == int.MaxValue ? 60 : min;
            }
            catch { return 60; }
        }

        static int SkipName(byte[] resp, int pos)
        {
            int p = pos;
            int jumps = 0;
            while (p < resp.Length)
            {
                byte len = resp[p];
                if ((len & 0xC0) == 0xC0) { p += 2; if (++jumps > 10) return resp.Length; break; }
                if (len == 0) { p++; break; }
                p += 1 + len;
            }
            return p;
        }
    }
}
