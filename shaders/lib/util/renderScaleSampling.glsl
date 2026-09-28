#ifndef RENDER_SCALE_SAMPLING_INCLUDED
#define RENDER_SCALE_SAMPLING_INCLUDED

// The viewport is rounded separately for each target, including half-size reflections.
vec2 ScaledBufferUV(sampler2D source, vec2 uv) {
    if (RENDER_SCALE_M >= 1.0) return uv;
    vec2 bufferSize = vec2(textureSize(source, 0));
    vec2 renderedSize = max(floor(bufferSize * RENDER_SCALE_M), vec2(1.0));
    return clamp(uv * renderedSize, vec2(0.5), renderedSize - 0.5) / bufferSize;
}

vec2 ScaledBufferLodUV(sampler2D source, vec2 uv, inout float lod) {
    if (RENDER_SCALE_M >= 1.0) return uv;
    vec2 bufferSize = vec2(textureSize(source, 0));
    vec2 renderedSize = max(floor(bufferSize * RENDER_SCALE_M), vec2(1.0));
    // Trilinear filtering reads ceil(lod). Leave a further texel inside generated NPOT mips,
    // whose edge texel may already contain pixels from outside the rendered viewport.
    float maxLod = max(floor(log2(min(renderedSize.x, renderedSize.y))) - 1.0, 0.0);
    lod = clamp(lod, 0.0, maxLod);
    vec2 bufferUV = ScaledBufferUV(source, uv);
    if (lod > 0.0) {
        vec2 mipSize = vec2(textureSize(source, int(ceil(lod))));
        vec2 cleanSize = max(floor(renderedSize / bufferSize * mipSize) - 1.0, vec2(1.0));
        bufferUV = min(bufferUV, (cleanSize - 0.5) / mipSize);
    }
    return bufferUV;
}

vec4 SampleScaledBufferLod(sampler2D source, vec2 uv, float lod) {
    // Compute the limited LOD before sampling; GLSL does not specify argument evaluation order.
    vec2 bufferUV = ScaledBufferLodUV(source, uv, lod);
    return texture2DLod(source, bufferUV, lod);
}

#endif
