import UIKit

/// 版本：跟随 App 版本（见 Config.swift，iOS v0.2 新增；和安卓版 TdtRaster.kt 一样）
///
/// 天地图图片地图：
/// 1. 下载当前位置附近的天地图矢量底图小图片（不带文字标注的 vec_w 图层，16 级，每张 256 像素），
///    下载过的存在手机缓存里，下次经过直接用。
/// 2. 按我们的坐标（高德坐标、北朝上、每像素 2 米）重新取样拼成一大张，
///    同时把天地图的 WGS-84 坐标换算成高德坐标，保证和导航路线对齐。
/// 3. 把每个像素的颜色归成 4 类（街区 / 道路 / 绿地 / 水面），压缩后发给圆屏。
/// 卫星图风格：改下天地图卫星照片（img_w），压成 16 色连同调色板发给圆屏。
/// 这里的函数都是同步的（会等网络），只在 MapFeeder 的后台队列里调用。
enum TdtRaster {
    static let Z = 16                       // 瓦片级别：16 级约 2 米/像素
    static let MPP = 2.0                    // 输出每像素多少米
    static let SAT_MPP = 3.5                // 卫星图每像素 3.5 米（范围小一些，数据量才发得动）

    struct Result { let bytes: Data; let tiles: Int; let fromCache: Int }

    struct Fail: LocalizedError {
        let msg: String
        init(_ m: String) { msg = m }
        var errorDescription: String? { msg }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    private static func cacheFile(_ x: Int, _ y: Int, _ layer: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(layer == "vec_w" ? "tdt" : "tdt_\(layer)")
            .appendingPathComponent("\(Z)/\(x)/\(y).png")
    }

    /// 图片 → 256×256 像素（0xRRGGBB）
    private static func decode(_ data: Data) -> [UInt32]? {
        guard let img = UIImage(data: data)?.cgImage else { return nil }
        var px = [UInt32](repeating: 0, count: 256 * 256)
        let ok: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256 * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 256, height: 256))
            return true
        }
        if !ok { return nil }
        for i in 0..<px.count { px[i] &= 0xFFFFFF }      // 32 位小端 + 跳过第一字节 = 0xXXRRGGBB
        return px
    }

    /// 下载一批瓦片（先查缓存，没有的同时下载），返回每张的像素；有一张失败就抛错
    private static func fetchTiles(_ list: [(x: Int, y: Int)], layer: String, key: String) throws -> (px: [[UInt32]], fromCache: Int) {
        if key.isEmpty { throw Fail("没填天地图 key（在 App 的「Key 设置」里填）") }
        var out = [[UInt32]?](repeating: nil, count: list.count)
        var hits = 0
        var err: String?
        let lock = NSLock()
        let group = DispatchGroup()
        for (i, t) in list.enumerated() {
            let file = cacheFile(t.x, t.y, layer)
            if let d = try? Data(contentsOf: file), d.count > 100, let px = decode(d) { out[i] = px; hits += 1; continue }
            let url = URL(string: "https://t\((t.x + t.y) & 7).tianditu.gov.cn/DataServer?T=\(layer)&x=\(t.x)&y=\(t.y)&l=\(Z)&tk=\(key)")!
            var req = URLRequest(url: url)
            // 不能带浏览器标识（Mozilla），否则天地图把它当成网页访问，服务端 key 会被拒绝（错误 301013）
            req.setValue("MotoNav/iOS", forHTTPHeaderField: "User-Agent")
            group.enter()
            session.dataTask(with: req) { data, resp, e in
                defer { group.leave() }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
                var px: [UInt32]?
                var msg: String?
                if let e = e { msg = e.localizedDescription }
                else if code != 200 || !type.hasPrefix("image") {
                    let body = String(data: (data ?? Data()).prefix(80), encoding: .utf8) ?? ""
                    msg = "天地图返回 \(code)：\(body.replacingOccurrences(of: "\n", with: " "))"
                } else if let d = data, let p = decode(d) {
                    px = p
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? d.write(to: file)
                } else { msg = "瓦片图片解析失败" }
                lock.lock()
                if let p = px { out[i] = p } else if err == nil { err = msg }
                lock.unlock()
            }.resume()
        }
        group.wait()
        if let e = err { throw Fail(e) }
        return (out.map { $0 ?? [] }, hits)
    }

    // 经纬度（WGS-84）→ 16 级全球像素坐标（Web 墨卡托）
    private static let WORLD = 256.0 * Double(1 << Z)
    private static func mx(_ lng: Double) -> Double { (lng + 180.0) / 360.0 * WORLD }
    private static func my(_ lat: Double) -> Double {
        let r = lat * .pi / 180
        return (1.0 - log(tan(r) + 1.0 / cos(r)) / .pi) / 2.0 * WORLD
    }

    /// 准备取样：每一列、每一行对应的全球像素坐标，以及要哪些瓦片
    private struct Grid { let n: Int; let x0: Int; let y0: Int; let col: [Double]; let row: [Double]; let tx0: Int; let ty0: Int; let tw: Int; let th: Int }

    private static func grid(_ f: MapGeo.Frame, _ cx: Double, _ cy: Double, _ half: Double, _ mpp: Double) -> Grid {
        let n = Int((2 * half / mpp).rounded())
        let x0 = Int((cx - half).rounded())              // 左上角（米）
        let y0 = Int((cy + half).rounded())
        // 高德坐标和天地图坐标（WGS-84）的偏移：几公里内几乎不变，取中心点的值
        let gLat = f.lat(cy), gLng = f.lng(cx)
        let w = MapGeo.gcjToWgs(gLat, gLng)
        let dLat = gLat - w.lat, dLng = gLng - w.lng
        let col = (0..<n).map { i in mx(f.lng(Double(x0) + (Double(i) + 0.5) * mpp) - dLng) }
        let row = (0..<n).map { j in my(f.lat(Double(y0) - (Double(j) + 0.5) * mpp) - dLat) }
        let tx0 = Int(floor(col[0] / 256)), tx1 = Int(floor(col[n - 1] / 256))
        let ty0 = Int(floor(row[0] / 256)), ty1 = Int(floor(row[n - 1] / 256))
        return Grid(n: n, x0: x0, y0: y0, col: col, row: row, tx0: tx0, ty0: ty0, tw: tx1 - tx0 + 1, th: ty1 - ty0 + 1)
    }

    private static func tileList(_ g: Grid) -> [(x: Int, y: Int)] {
        var l: [(x: Int, y: Int)] = []
        for ty in g.ty0..<(g.ty0 + g.th) { for tx in g.tx0..<(g.tx0 + g.tw) { l.append((tx, ty)) } }
        return l
    }

    /// 生成以 (cx, cy)（平面米坐标）为中心、半边长 half 米的图片地图
    static func build(_ f: MapGeo.Frame, cx: Double, cy: Double, half: Double, key: String) throws -> Result {
        let g = grid(f, cx, cy, half, MPP)
        let n = g.n
        if g.tw * g.th > 120 { throw Fail("需要的瓦片太多（\(g.tw * g.th)）") }
        let (tiles, hits) = try fetchTiles(tileList(g), layer: "vec_w", key: key)
        // 重新取样
        var raw = [UInt32](repeating: 0, count: n * n)
        raw.withUnsafeMutableBufferPointer { r in
            for j in 0..<n {
                let py = g.row[j]
                let ty = Int(floor(py / 256)) - g.ty0
                let iy = min(255, max(0, Int(py - Double(ty + g.ty0) * 256.0)))
                for i in 0..<n {
                    let pxx = g.col[i]
                    let tx = Int(floor(pxx / 256)) - g.tx0
                    let ix = min(255, max(0, Int(pxx - Double(tx + g.tx0) * 256.0)))
                    r[j * n + i] = tiles[ty * g.tw + tx][iy * 256 + ix]
                }
            }
        }
        // 颜色归类（同样的颜色只算一次）
        let bg = MapGeo.backgroundLum(raw)
        var idx = [UInt8](repeating: 0, count: n * n)
        var cache: [UInt32: UInt8] = [:]
        for k in 0..<raw.count {
            let c = raw[k]
            if let v = cache[c] { idx[k] = v } else { let v = MapGeo.classifyPixel(c, bg); cache[c] = v; idx[k] = v }
        }
        let idx2 = MapGeo.dilateRoads(MapGeo.cleanRaster(idx, w: n, h: n), w: n, h: n)   // 先清理杂点再加粗道路
        let bytes = MapGeo.encodeRaster(frameId: f.id, x0: g.x0, y0: g.y0, w: n, h: n, mmPerPx: Int(MPP * 1000), idx: idx2)
        if bytes.count > 480_000 { throw Fail("压缩后 \(bytes.count / 1024) KB，超过圆屏缓冲") }
        return Result(bytes: bytes, tiles: g.tw * g.th, fromCache: hits)
    }

    /// 卫星图：下载天地图卫星照片（img_w），按我们的坐标重新取样，稍微模糊一下（去掉噪点，压缩得更小），
    /// 再挑出最有代表性的 16 种颜色（k 均值），每个像素换成最接近的那种，连同调色板一起发给圆屏。
    static func buildSat(_ f: MapGeo.Frame, cx: Double, cy: Double, half: Double, key: String) throws -> Result {
        let g = grid(f, cx, cy, half, SAT_MPP)
        let n = g.n
        if g.tw * g.th > 64 { throw Fail("需要的卫星瓦片太多（\(g.tw * g.th)）") }
        let (tiles, hits) = try fetchTiles(tileList(g), layer: "img_w", key: key)
        func px(_ gx: Double, _ gy: Double) -> UInt32 {
            let tx = Int(floor(gx / 256)) - g.tx0, ty = Int(floor(gy / 256)) - g.ty0
            let ix = min(255, max(0, Int(gx - Double(tx + g.tx0) * 256.0)))
            let iy = min(255, max(0, Int(gy - Double(ty + g.ty0) * 256.0)))
            return tiles[min(g.th - 1, max(0, ty)) * g.tw + min(g.tw - 1, max(0, tx))][iy * 256 + ix]
        }
        // 取样（每个输出像素取对应位置周围 2×2 的平均，比只取一个点平滑）
        var R = [Int](repeating: 0, count: n * n), G = R, B = R
        let stepX = n > 1 ? (g.col[n - 1] - g.col[0]) / Double(n - 1) / 2 : 0
        let stepY = n > 1 ? (g.row[n - 1] - g.row[0]) / Double(n - 1) / 2 : 0
        for j in 0..<n {
            for i in 0..<n {
                var r = 0, gg = 0, b = 0
                for k in 0..<4 {
                    let c = px(g.col[i] + ((k & 1) == 0 ? -stepX : stepX) / 2, g.row[j] + (k < 2 ? -stepY : stepY) / 2)
                    r += Int((c >> 16) & 255); gg += Int((c >> 8) & 255); b += Int(c & 255)
                }
                R[j * n + i] = r / 4; G[j * n + i] = gg / 4; B[j * n + i] = b / 4
            }
        }
        // 3×3 模糊
        func blur(_ a: [Int]) -> [Int] {
            var o = [Int](repeating: 0, count: n * n)
            for j in 0..<n {
                for i in 0..<n {
                    var sum = 0, cnt = 0
                    for dj in -1...1 {
                        let jj = j + dj
                        if jj < 0 || jj >= n { continue }
                        for di in -1...1 {
                            let ii = i + di
                            if ii < 0 || ii >= n { continue }
                            sum += a[jj * n + ii]; cnt += 1
                        }
                    }
                    o[j * n + i] = sum / cnt
                }
            }
            return o
        }
        let r1 = blur(R), g1 = blur(G), b1 = blur(B)
        // k 均值找 16 种颜色：先按亮度排序均匀取 16 个起点，迭代 10 轮
        var rng = SeededRandom(seed: 7)
        let S = min(6000, n * n)
        let sIdx = (0..<S).map { _ in rng.next(n * n) }
        let sorted = sIdx.sorted { r1[$0] * 3 + g1[$0] * 6 + b1[$0] < r1[$1] * 3 + g1[$1] * 6 + b1[$1] }
        let K = 16
        var cr = (0..<K).map { Double(r1[sorted[($0 * 2 + 1) * S / (2 * K)]]) }
        var cg = (0..<K).map { Double(g1[sorted[($0 * 2 + 1) * S / (2 * K)]]) }
        var cb = (0..<K).map { Double(b1[sorted[($0 * 2 + 1) * S / (2 * K)]]) }
        func nearest(_ r: Int, _ g: Int, _ b: Int) -> Int {
            var best = 0, bd = Double.greatestFiniteMagnitude
            for k in 0..<K {
                let dr = Double(r) - cr[k], dg = Double(g) - cg[k], db = Double(b) - cb[k]
                let d = dr * dr * 2 + dg * dg * 4 + db * db * 3
                if d < bd { bd = d; best = k }
            }
            return best
        }
        for _ in 0..<10 {
            var sr = [Double](repeating: 0, count: K), sg = sr, sb = sr
            var sc = [Int](repeating: 0, count: K)
            for p in sIdx {
                let k = nearest(r1[p], g1[p], b1[p])
                sr[k] += Double(r1[p]); sg[k] += Double(g1[p]); sb[k] += Double(b1[p]); sc[k] += 1
            }
            for k in 0..<K where sc[k] > 0 { cr[k] = sr[k] / Double(sc[k]); cg[k] = sg[k] / Double(sc[k]); cb[k] = sb[k] / Double(sc[k]) }
        }
        let idx = (0..<(n * n)).map { p in UInt8(nearest(r1[p], g1[p], b1[p])) }
        let pal = (0..<K).map { k -> Int in
            let r = min(255, max(0, Int(cr[k].rounded()))), g = min(255, max(0, Int(cg[k].rounded()))), b = min(255, max(0, Int(cb[k].rounded())))
            return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        }
        let bytes = MapGeo.encodeRaster(frameId: f.id, x0: g.x0, y0: g.y0, w: n, h: n, mmPerPx: Int(SAT_MPP * 1000), idx: idx, pal: pal)
        if bytes.count > 480_000 { throw Fail("卫星图压缩后 \(bytes.count / 1024) KB，超过圆屏缓冲") }
        return Result(bytes: bytes, tiles: g.tw * g.th, fromCache: hits)
    }
}

/// 固定种子的随机数（每次结果一样，卫星图颜色不会每次都变）
struct SeededRandom {
    private var s: UInt64
    init(seed: UInt64) { s = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next(_ bound: Int) -> Int {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Int((s >> 33) % UInt64(bound))
    }
}
