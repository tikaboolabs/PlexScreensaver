import Metal
import AppKit

/// GPU-accelerated background renderer.
/// Uses shared-memory textures on Apple Silicon (unified memory = zero-copy readback).
/// Falls back gracefully if Metal is unavailable.
final class MetalBackgroundRenderer {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var uniformBuffer: MTLBuffer
    private var particleBuffer: MTLBuffer

    // Render target — shared memory on Apple Silicon for zero-copy
    private var renderTexture: MTLTexture?
    private var pixelBuffer: UnsafeMutablePointer<UInt8>?
    private var pixelBufferSize: Int = 0
    private var cachedWidth: Int = 0
    private var cachedHeight: Int = 0

    private let maxParticles = 256
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()

    struct Uniforms {
        var time: Float
        var width: Float
        var height: Float
        var particleCount: UInt32
    }

    struct GPUParticle {
        var x: Float
        var y: Float
        var size: Float
        var opacity: Float
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue

        // Build shader library — try bundle, then default, then runtime compile
        let library: MTLLibrary
        let bundle = Bundle(for: MetalBackgroundRenderer.self)
        if let lib = try? device.makeDefaultLibrary(bundle: bundle) {
            library = lib
        } else if let lib = device.makeDefaultLibrary() {
            library = lib
        } else if let lib = try? device.makeLibrary(source: MetalBackgroundRenderer.shaderSource, options: nil) {
            library = lib
        } else {
            return nil
        }

        guard let vertFunc = library.makeFunction(name: "backgroundVertex"),
              let fragFunc = library.makeFunction(name: "backgroundFragment") else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertFunc
        desc.fragmentFunction = fragFunc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let ps = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipelineState = ps

        self.uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)!
        self.particleBuffer = device.makeBuffer(length: MemoryLayout<GPUParticle>.stride * maxParticles, options: .storageModeShared)!
    }

    deinit {
        pixelBuffer?.deallocate()
    }

    private func ensureTexture(width: Int, height: Int) {
        guard width != cachedWidth || height != cachedHeight else { return }
        cachedWidth = width
        cachedHeight = height

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        // Shared storage = unified memory on Apple Silicon = zero-copy CPU access
        desc.storageMode = .shared
        renderTexture = device.makeTexture(descriptor: desc)

        // Reuse pixel buffer for CGImage creation
        let newSize = width * height * 4
        if newSize != pixelBufferSize {
            pixelBuffer?.deallocate()
            pixelBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: newSize)
            pixelBufferSize = newSize
        }
    }

    /// Render background and return a CGImage. GPU does the heavy lifting;
    /// on Apple Silicon the texture readback is effectively free (shared memory).
    /// Renders at half resolution to save ~75% memory — the soft gradient background
    /// is visually identical when upscaled.
    func render(width: Int, height: Int, time: Float,
                particles: [(x: Float, y: Float, size: Float, opacity: Float)]) -> CGImage? {

        guard width > 0, height > 0 else { return nil }
        // Render at half resolution — gradients and soft particles look identical upscaled
        let rw = max(width / 2, 1)
        let rh = max(height / 2, 1)
        let scale: Float = 0.5
        ensureTexture(width: rw, height: rh)
        guard let texture = renderTexture, let pixels = pixelBuffer else { return nil }

        // Update uniforms (use full dimensions for correct gradient positions)
        var uniforms = Uniforms(time: time, width: Float(width), height: Float(height),
                                particleCount: UInt32(min(particles.count, maxParticles)))
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

        // Update particle buffer (scale positions to match render resolution)
        let count = min(particles.count, maxParticles)
        let ptr = particleBuffer.contents().bindMemory(to: GPUParticle.self, capacity: maxParticles)
        for i in 0..<count {
            let p = particles[i]
            ptr[i] = GPUParticle(x: p.x, y: p.y, size: p.size, opacity: p.opacity)
        }

        // Render
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1)

        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return nil }

        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                         width: Double(rw), height: Double(rh),
                                         znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(particleBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        // Read pixels from shared texture (zero-copy on Apple Silicon)
        let bytesPerRow = rw * 4
        texture.getBytes(pixels, bytesPerRow: bytesPerRow,
                         from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                         size: MTLSize(width: rw, height: rh, depth: 1)),
                         mipmapLevel: 0)

        // Create CGImage — BGRA8 → use byteOrder32Little + premultipliedFirst
        guard let context = CGContext(
            data: pixels,
            width: rw, height: rh,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: Self.deviceRGB,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        return context.makeImage()
    }

    // MARK: - Inline Shader Source (fallback if .metallib not in bundle)

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct Uniforms {
        float time;
        float width;
        float height;
        uint  particleCount;
    };

    struct Particle {
        float x;
        float y;
        float size;
        float opacity;
    };

    vertex VertexOut backgroundVertex(uint vid [[vertex_id]]) {
        float2 positions[4] = {
            float2(-1, -1), float2( 1, -1),
            float2(-1,  1), float2( 1,  1)
        };
        float2 uvs[4] = {
            float2(0, 0), float2(1, 0),
            float2(0, 1), float2(1, 1)
        };
        VertexOut out;
        out.position = float4(positions[vid], 0, 1);
        out.uv = uvs[vid];
        return out;
    }

    fragment float4 backgroundFragment(VertexOut in [[stage_in]],
                                        constant Uniforms &u [[buffer(0)]],
                                        constant Particle *particles [[buffer(1)]]) {
        float2 uv = in.uv;
        float2 pixelPos = float2(uv.x * u.width, uv.y * u.height);
        float t = u.time;
        float maxDim = max(u.width, u.height);

        float3 color = float3(0.02, 0.02, 0.04);

        // Magenta — upper left orbit
        float2 magC = float2(
            u.width  * (0.20 + 0.25 * cos(t * 0.41)),
            u.height * (0.75 + 0.20 * sin(t * 0.37))
        );
        float magF = 1.0 - smoothstep(0.0, maxDim * 0.55, distance(pixelPos, magC));
        color += float3(1.0, 0.08, 0.58) * magF * (0.20 + 0.08 * sin(t * 0.67));

        // Deep blue — upper right orbit
        float2 blueC = float2(
            u.width  * (0.78 + 0.20 * sin(t * 0.53 + 1.0)),
            u.height * (0.70 + 0.22 * cos(t * 0.31))
        );
        float blueF = 1.0 - smoothstep(0.0, maxDim * 0.6, distance(pixelPos, blueC));
        color += float3(0.08, 0.18, 1.0) * blueF * (0.22 + 0.08 * sin(t * 0.83 + 0.5));

        // Teal/green — lower right orbit
        float2 greenC = float2(
            u.width  * (0.72 - 0.22 * cos(t * 0.47 + 2.0)),
            u.height * (0.28 + 0.18 * sin(t * 0.43 + 1.5))
        );
        float greenF = 1.0 - smoothstep(0.0, maxDim * 0.55, distance(pixelPos, greenC));
        color += float3(0.02, 0.95, 0.55) * greenF * (0.16 + 0.07 * sin(t * 0.59 + 3.0));

        // Warm yellow — lower left orbit
        float2 yellowC = float2(
            u.width  * (0.30 + 0.20 * sin(t * 0.37 + 3.5)),
            u.height * (0.25 - 0.18 * cos(t * 0.51 + 2.0))
        );
        float yellowF = 1.0 - smoothstep(0.0, maxDim * 0.5, distance(pixelPos, yellowC));
        color += float3(1.0, 0.82, 0.05) * yellowF * (0.16 + 0.06 * sin(t * 0.73 + 1.0));

        // Particles (soft white)
        for (uint i = 0; i < u.particleCount; i++) {
            Particle p = particles[i];
            float dist = distance(pixelPos, float2(p.x, p.y));
            float radius = p.size * 0.5;
            float core = 1.0 - smoothstep(0.0, radius, dist);
            float glow = 1.0 - smoothstep(radius, radius * 3.0, dist);
            color += float3(0.9, 0.95, 1.0) * (core * 0.8 + glow * 0.2) * p.opacity;
        }

        // Dither to eliminate color banding
        float2 seed = pixelPos + float2(t * 100.0, t * 73.0);
        float noise = fract(sin(dot(seed, float2(12.9898, 78.233))) * 43758.5453);
        color += (noise - 0.5) / 255.0;

        return float4(color, 1.0);
    }
    """
}
