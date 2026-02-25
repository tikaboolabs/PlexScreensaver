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

    // Dark base
    float3 color = float3(0.02, 0.02, 0.04);

    // --- Color wash: 4 orbiting blobs ---

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

    // --- Particles (soft white) ---
    for (uint i = 0; i < u.particleCount; i++) {
        Particle p = particles[i];
        float dist = distance(pixelPos, float2(p.x, p.y));
        float radius = p.size * 0.5;
        float core = 1.0 - smoothstep(0.0, radius, dist);
        float glow = 1.0 - smoothstep(radius, radius * 3.0, dist);
        color += float3(0.9, 0.95, 1.0) * (core * 0.8 + glow * 0.2) * p.opacity;
    }

    // Dither to eliminate color banding (±0.5/255 noise per channel)
    float2 seed = pixelPos + float2(t * 100.0, t * 73.0);
    float noise = fract(sin(dot(seed, float2(12.9898, 78.233))) * 43758.5453);
    color += (noise - 0.5) / 255.0;

    return float4(color, 1.0);
}
