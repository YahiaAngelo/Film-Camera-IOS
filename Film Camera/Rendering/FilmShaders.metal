//
//  FilmShaders.metal
//  Film Camera
//
//  Pipeline:
//    1. filmGrade      (compute)  exposure + white balance → film LUT → tone & color
//    2. filmBright     (compute)  quarter-res highlight extraction, then MPS Gaussian blur
//    3. filmComposite  (fragment) glow, halation, vignette and grain, with a crop transform
//

#include <metal_stdlib>
using namespace metal;

// Must match `FilmUniforms` in FilmRenderer.swift (all 32-bit floats).
struct FilmUniforms {
    float exposure;
    float contrast;
    float highlights;
    float shadows;
    float saturation;
    float temperature;
    float tint;
    float fade;
    float lutIntensity;
    float lutSize;
    float lutDomainMinR, lutDomainMinG, lutDomainMinB;
    float lutDomainMaxR, lutDomainMaxG, lutDomainMaxB;
    float grain;
    float grainScale;
    float glow;
    float halation;
    float vignette;
    float grainSeed;
    float aspect;
    float uvScaleX, uvScaleY;
    float uvOffsetX, uvOffsetY;
};

constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);

inline float luma(float3 c) { return dot(c, kLuma); }

inline float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

inline float3 linearToSrgb(float3 c) {
    c = max(c, 0.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

// MARK: - Grade

kernel void filmGrade(texture2d<float, access::read>   source [[texture(0)]],
                      texture3d<float, access::sample> lut    [[texture(1)]],
                      texture2d<float, access::write>  output [[texture(2)]],
                      constant FilmUniforms &u                [[buffer(0)]],
                      uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    float3 c = source.read(gid).rgb;

    // Exposure and white balance happen in linear light, like adjusting the scene
    // before it hits the film.
    float3 lin = srgbToLinear(c) * exp2(u.exposure);
    lin *= float3(1.0 + 0.22 * u.temperature,
                  1.0 - 0.12 * u.tint,
                  1.0 - 0.22 * u.temperature);
    c = saturate(linearToSrgb(lin));

    // Film LUT (trilinear sampling of the 3D texture, texel-center corrected).
    if (u.lutIntensity > 0.0) {
        constexpr sampler lutSampler(filter::linear, address::clamp_to_edge);
        float3 dMin = float3(u.lutDomainMinR, u.lutDomainMinG, u.lutDomainMinB);
        float3 dMax = float3(u.lutDomainMaxR, u.lutDomainMaxG, u.lutDomainMaxB);
        float3 normalized = saturate((c - dMin) / max(dMax - dMin, 1e-5));
        float n = u.lutSize;
        float3 coord = normalized * ((n - 1.0) / n) + 0.5 / n;
        float3 filmic = lut.sample(lutSampler, coord).rgb;
        c = mix(c, filmic, u.lutIntensity);
    }

    // Highlights / shadows: luminance-weighted lift or pull.
    float l = luma(c);
    float shadowMask = 1.0 - smoothstep(0.0, 0.55, l);
    float highlightMask = smoothstep(0.45, 1.0, l);
    c += u.shadows * 0.28 * shadowMask;
    c += u.highlights * 0.28 * highlightMask;

    // Contrast around mid-grey, softened for negative values.
    float k = u.contrast >= 0.0 ? 1.0 + u.contrast * 0.9 : 1.0 + u.contrast * 0.6;
    c = (c - 0.5) * k + 0.5;

    // Saturation.
    c = mix(float3(luma(c)), c, 1.0 + u.saturation);

    // Fade: lifted blacks and slightly muted whites, like faded prints.
    c = mix(c, c * 0.86 + 0.1, u.fade);

    output.write(float4(saturate(c), 1.0), gid);
}

// MARK: - Bloom extraction

kernel void filmBright(texture2d<float, access::sample> source [[texture(0)]],
                       texture2d<float, access::write>  output [[texture(1)]],
                       uint2 gid                               [[thread_position_in_grid]])
{
    uint w = output.get_width();
    uint h = output.get_height();
    if (gid.x >= w || gid.y >= h) return;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 texel = 1.0 / float2(w, h);
    float2 uv = (float2(gid) + 0.5) * texel;

    // 4 bilinear taps ≈ box filter over the 4×4 source block.
    float3 c = 0.25 * (source.sample(s, uv + texel * float2(-0.25, -0.25)).rgb +
                       source.sample(s, uv + texel * float2( 0.25, -0.25)).rgb +
                       source.sample(s, uv + texel * float2(-0.25,  0.25)).rgb +
                       source.sample(s, uv + texel * float2( 0.25,  0.25)).rgb);

    float weight = smoothstep(0.55, 0.95, luma(c));
    output.write(float4(c * weight, 1.0), gid);
}

// MARK: - Composite

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Single full-screen triangle; uv (0,0) is the top-left of the image.
vertex VertexOut filmVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// PCG3D integer hash (Jarzynski & Olano 2020): no visible lattice patterns,
// unlike fract/sin hashes.
inline uint3 pcg3d(uint3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

// Three roughly Gaussian (unit variance) random values for a grid cell.
// The sum of 3 uniforms has std 0.5, hence the ×2.
inline float3 gaussian3(int2 cell, uint seed, uint salt) {
    float3 a = float3(pcg3d(uint3(uint2(cell), seed ^ salt))) * (1.0 / 4294967295.0);
    float3 b = float3(pcg3d(uint3(uint2(cell), seed ^ (salt + 0x9E3779B9u)))) * (1.0 / 4294967295.0);
    float3 c = float3(pcg3d(uint3(uint2(cell), seed ^ (salt + 0x7F4A7C15u)))) * (1.0 / 4294967295.0);
    return (a + b + c - 1.5) * 2.0;
}

// Smoothly interpolated Gaussian value noise: soft, clumpy grains rather than hard pixels.
// Returns luminance grain in .x and two chroma offsets in .yz.
inline float3 grainNoise(float2 p, uint seed, uint salt) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 w = f * f * (3.0 - 2.0 * f);
    int2 c = int2(i);
    float3 n00 = gaussian3(c, seed, salt);
    float3 n10 = gaussian3(c + int2(1, 0), seed, salt);
    float3 n01 = gaussian3(c + int2(0, 1), seed, salt);
    float3 n11 = gaussian3(c + int2(1, 1), seed, salt);
    // Interpolation shrinks the variance; ×1.6 restores it to roughly unit.
    return mix(mix(n00, n10, w.x), mix(n01, n11, w.x), w.y) * 1.6;
}

fragment float4 filmComposite(VertexOut in                 [[stage_in]],
                              texture2d<float> graded      [[texture(0)]],
                              texture2d<float> bloom       [[texture(1)]],
                              constant FilmUniforms &u     [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = float2(u.uvOffsetX, u.uvOffsetY) + in.uv * float2(u.uvScaleX, u.uvScaleY);

    float3 c = graded.sample(s, uv).rgb;
    float3 b = bloom.sample(s, uv).rgb;

    // Glow: soft screen-blended bloom.
    c = 1.0 - (1.0 - c) * (1.0 - saturate(b * u.glow * 1.6));

    // Halation: red-orange light scattered back through the film base.
    c += float3(1.0, 0.28, 0.1) * luma(b) * u.halation * 1.4;

    // Vignette, measured in image space so preview and photo match.
    float2 centered = (uv - 0.5) * 2.0;
    float r = length(centered) * 0.7071;
    c *= 1.0 - u.vignette * 0.85 * smoothstep(0.35, 1.05, r);

    // Film grain. Two rotated octaves so the pattern never aligns with the
    // pixel grid: fine grains plus larger clumps. Re-seeded every frame.
    if (u.grain > 0.0) {
        uint seed = uint(u.grainSeed) * 747796405u + 2891336453u;
        float2 gp = uv * float2(u.aspect, 1.0) * u.grainScale;
        const float2x2 rotA = float2x2(float2(0.8660, 0.5), float2(-0.5, 0.8660));    // 30°
        const float2x2 rotB = float2x2(float2(0.3420, -0.9397), float2(0.9397, 0.3420)); // -70°
        float3 fine = grainNoise(rotA * gp, seed, 0x68E31DA4u);
        float3 clump = grainNoise(rotB * gp * 0.45 + 17.0, seed, 0xB5297A4Du);
        float3 g = fine * 0.75 + clump * 0.45;

        // Soft-light style response per channel: full strength in the midtones,
        // fading to zero at pure black and white. Grain never clips, so it can't
        // dirty or darken highlights, and the average brightness is unchanged.
        float3 response = pow(saturate(4.0 * c * (1.0 - c)), 0.75);

        // Colour dye clouds only where there's colour, so B&W films stay neutral.
        float l = luma(c);
        float chroma = saturate(length(c - l) * 4.0);
        float3 dye = float3(g.y, -0.5 * (g.y + g.z), g.z) * 0.25 * chroma;
        c += (g.x + dye) * u.grain * 0.11 * response;
    }

    return float4(saturate(c), 1.0);
}
