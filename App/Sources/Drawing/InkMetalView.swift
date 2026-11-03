#if os(iOS)
import MetalKit
import QuartzCore
import TroveCore
import UIKit

/// Trove's own GPU ink renderer for the iPad (docs/plans/sketch-2-plan.md S3). PencilKit re-sharpens
/// its ink tiles only after a zoom ends, which is the blur-then-sharp the user saw. Here every
/// visible stroke is drawn as triangles (`InkTessellator`) at the exact zoom on every frame the view
/// moves, so ink is never soft. PencilKit still takes the Pencil (its latency and prediction are the
/// best there is) and shows only the stroke being written; when it reaches the model it's drawn here
/// in the same frame as PencilKit lets it go.
///
/// Efficient by design: strokes are tessellated once (cached by id and look); a page's triangles sit
/// in GPU buffers; a frame is one or two draw calls per visible page; nothing runs while the page is
/// still (the view only draws when asked).
@MainActor
final class InkMetalView: MTKView {
    /// Whether the GPU renderer is used (Settings → Sketch → Classic ink turns it off).
    static var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "ink.classic") && InkGPU.shared != nil }
        set { UserDefaults.standard.set(!newValue, forKey: "ink.classic") }
    }

    /// One page's ink on the GPU.
    final class PageInk {
        var key = ""
        /// Canvas points = page points + offset.
        var offset = CGPoint.zero
        var frame = CGRect.zero
        var highlights: Buffers?
        var ink: Buffers?
        /// The stroke list (id + look) the buffers were built from.
        var sig = ""
    }

    struct Buffers {
        let vertices: MTLBuffer
        let strokes: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
    }

    private typealias Mesh = InkStrokeMesh
    private var meshes: [String: Mesh] = [:]
    private var pages: [String: PageInk] = [:]
    private var zoom: CGFloat = 1

    init?() {
        guard let gpu = InkGPU.shared else { return nil }
        super.init(frame: .zero, device: gpu.device)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        sampleCount = 4
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        clearDepth = 1
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        presentsWithTransaction = true
        framebufferOnly = true
        (layer as? CAMetalLayer)?.isOpaque = false
    }

    required init(coder: NSCoder) { fatalError("not used") }

    // MARK: Content

    /// Brings a page's ink up to date. `lines`: what the page shows (dark colours already swapped).
    func setPage(_ key: String, offset: CGPoint, frame: CGRect, lines: [InkLine], dark: Bool) {
        let page = pages[key] ?? { let p = PageInk(); p.key = key; pages[key] = p; return p }()
        page.offset = offset
        page.frame = frame
        let sig = lines.map { $0.id + "@" + $0.stamp }.joined(separator: ",") + (dark ? "|d" : "")
        guard sig != page.sig else { return }
        page.sig = sig
        guard let gpu = InkGPU.shared else { return }
        var highlightLines: [InkLine] = []
        var inkLines: [InkLine] = []
        // Highlighters lie under the ink, like a real highlighter on paper (see the plan's R3 note).
        for l in lines { if l.tool == .highlighter { highlightLines.append(l) } else { inkLines.append(l) } }
        let ordered = highlightLines + inkLines
        var mesh: [(Mesh, Int)] = []
        for (i, l) in ordered.enumerated() {
            let stamp = l.stamp + (dark ? "|d" : "")
            let m: Mesh
            if let cached = meshes[l.id], cached.stamp == stamp {
                m = cached
            } else {
                m = Mesh(stamp: stamp, parts: InkTessellator.parts(tool: l.tool, color: l.color, width: l.width, points: l.points, shape: l.shape, style: l.style), tool: l.tool)
                meshes[l.id] = m
            }
            mesh.append((m, i))
        }
        let total = ordered.count
        page.highlights = gpu.buffers(mesh.filter { $0.0.tool == .highlighter }, total: total)
        page.ink = gpu.buffers(mesh.filter { $0.0.tool != .highlighter }, total: total)
    }

    /// Pages that went away.
    func keep(only keys: Set<String>) {
        pages = pages.filter { keys.contains($0.key) }
        if meshes.count > 60_000 { meshes = [:] }
    }

    // MARK: Drawing

    /// Draws what's on screen now. `visible`: the scroll view's bounds (content points, zoomed).
    func render(visible: CGRect, zoom z: CGFloat) {
        guard let gpu = InkGPU.shared, bounds.width > 0, bounds.height > 0 else { return }
        zoom = z
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = gpu.queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setDepthStencilState(gpu.depth)
        encoder.setFragmentTexture(gpu.grain, index: 0)
        let w = Float(visible.width), h = Float(visible.height)
        let area = CGRect(x: visible.minX / z, y: visible.minY / z, width: visible.width / z, height: visible.height / z)
        for page in pages.values where page.frame.intersects(area) {
            var u = InkGPU.Uniforms(scale: SIMD2(Float(2 * z) / w, -Float(2 * z) / h),
                                    translate: SIMD2(-1 - 2 * Float(visible.minX) / w, 1 + 2 * Float(visible.minY) / h),
                                    offset: SIMD2(Float(page.offset.x), Float(page.offset.y)))
            for b in [page.highlights, page.ink].compactMap({ $0 }) where b.indexCount > 0 {
                encoder.setRenderPipelineState(gpu.pipeline)
                encoder.setVertexBuffer(b.vertices, offset: 0, index: 0)
                encoder.setVertexBuffer(b.strokes, offset: 0, index: 1)
                encoder.setVertexBytes(&u, length: MemoryLayout<InkGPU.Uniforms>.stride, index: 2)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: b.indexCount, indexType: .uint32, indexBuffer: b.indices, indexBufferOffset: 0)
            }
        }
        encoder.endEncoding()
        // In step with UIKit's scrolling: the frame is presented with the same transaction.
        buffer.commit()
        buffer.waitUntilScheduled()
        drawable.present()
    }
}

/// The Metal device, pipeline and grain texture, made once.
@MainActor
final class InkGPU {
    static let shared: InkGPU? = InkGPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let depth: MTLDepthStencilState
    let grain: MTLTexture

    struct Vertex {
        var x: Float
        var y: Float
        var stroke: UInt32
    }

    struct Stroke {
        var color: SIMD4<Float>
        var depth: Float
        var grain: Float
        var pad: SIMD2<Float> = .zero
    }

    struct Uniforms {
        var scale: SIMD2<Float>
        var translate: SIMD2<Float>
        var offset: SIMD2<Float>
        var grainPeriod: Float = 32
        var pad: Float = 0
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { packed_float2 pos; uint stroke; };
    struct S { float4 color; float depth; float grain; float2 pad; };
    struct U { float2 scale; float2 translate; float2 offset; float grainPeriod; float pad; };
    struct O { float4 position [[position]]; float4 color; float2 page; float grain; };
    vertex O ink_vertex(uint vid [[vertex_id]], const device V* v [[buffer(0)]], const device S* s [[buffer(1)]], constant U& u [[buffer(2)]]) {
        V a = v[vid];
        S st = s[a.stroke];
        float2 p = float2(a.pos) + u.offset;
        O o;
        o.position = float4(p * u.scale + u.translate, st.depth, 1.0);
        o.color = st.color;
        o.page = float2(a.pos) / u.grainPeriod;
        o.grain = st.grain;
        return o;
    }
    fragment float4 ink_fragment(O in [[stage_in]], texture2d<float> grain [[texture(0)]]) {
        constexpr sampler sm(address::repeat, filter::nearest);
        float g = in.grain > 0.5 ? grain.sample(sm, in.page).r : 1.0;
        return in.color * g;
    }
    """

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "ink_vertex")
        d.fragmentFunction = library.makeFunction(name: "ink_fragment")
        d.rasterSampleCount = 4
        d.depthAttachmentPixelFormat = .depth32Float
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        // Premultiplied "over".
        c.sourceRGBBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.sourceAlphaBlendFactor = .one
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        // Each stroke has its own depth (later strokes nearer); "less" lets each sample be covered
        // once per stroke, so a see-through stroke's own overlaps don't darken it.
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: ds) else { return nil }
        let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: InkOutline.grainSize, height: InkOutline.grainSize, mipmapped: false)
        t.usage = .shaderRead
        guard let grain = device.makeTexture(descriptor: t) else { return nil }
        let tile = InkOutline.grainTile
        tile.withUnsafeBytes { raw in
            grain.replace(region: MTLRegionMake2D(0, 0, InkOutline.grainSize, InkOutline.grainSize), mipmapLevel: 0,
                          withBytes: raw.baseAddress!, bytesPerRow: InkOutline.grainSize)
        }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.depth = depth
        self.grain = grain
    }

    /// GPU buffers for strokes. `index`: each stroke's place in the page's order, for its depth.
    func buffers(_ list: [(InkStrokeMesh, Int)], total: Int) -> InkMetalView.Buffers? {
        var vertices: [Vertex] = []
        var strokes: [Stroke] = []
        var indices: [UInt32] = []
        for (mesh, index) in list {
            let depth = Float(1 - (Double(index) + 1) / (Double(total) + 2))
            let opacity = Float(mesh.tool.opacity)
            for part in mesh.parts {
                let (r, g, b) = InkStroke.rgb(part.color)
                let s = UInt32(strokes.count)
                strokes.append(Stroke(color: SIMD4(Float(r) * opacity, Float(g) * opacity, Float(b) * opacity, opacity), depth: depth, grain: part.grain ? 1 : 0))
                let base = UInt32(vertices.count)
                var i = 0
                while i + 1 < part.positions.count {
                    vertices.append(Vertex(x: part.positions[i], y: part.positions[i + 1], stroke: s))
                    i += 2
                }
                indices.append(contentsOf: part.indices.map { $0 + base })
            }
        }
        guard !indices.isEmpty,
              let v = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Vertex>.stride, options: .storageModeShared),
              let s = device.makeBuffer(bytes: strokes, length: strokes.count * MemoryLayout<Stroke>.stride, options: .storageModeShared),
              let ix = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        else { return nil }
        return InkMetalView.Buffers(vertices: v, strokes: s, indices: ix, indexCount: indices.count)
    }
}

/// One stroke's cached triangles, with the look they were made for.
struct InkStrokeMesh {
    let stamp: String
    let parts: [InkTessellator.Part]
    let tool: InkTool
}
#endif
