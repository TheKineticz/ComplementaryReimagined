// Render Scale upscaling, based on Photon's TAAU by SixthSurge (see Photon-LICENSE.txt).
// Terrain, entities and the hand share colour clipping and accumulation. Only reprojection depends on the surface.
// The reconstruction and interpolated neighbourhood bounds share a 4x4 gather here, combining Photon's bounds
// preparation and resolve into one pass. Our input is already tonemapped, so no reversible tonemap is needed.

vec3 RGBToYCoCg(vec3 c) {
    return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 YCoCgToRGB(vec3 c) {
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

#if TAA_MOVEMENT_IMPROVEMENT_FILTER == 1
    vec4 TAAUCubicWeights(float f) {
        float f2 = f * f, f3 = f2 * f;
        return vec4(-0.5 * f3 + f2 - 0.5 * f,
                     1.5 * f3 - 2.5 * f2 + 1.0,
                    -1.5 * f3 + 2.0 * f2 + 0.5 * f,
                     0.5 * f3 - 0.5 * f2);
    }
#endif

void ReconstructTAAU(vec2 inputPos, out vec3 current, out vec3 minColor, out vec3 maxColor, out float confidence) {
    vec2 position = clamp(inputPos, vec2(0.5), scaledViewSizeF - 0.5);
    ivec2 base = ivec2(floor(position - 0.5));
    vec2 f = fract(position - 0.5);

    #if TAA_MOVEMENT_IMPROVEMENT_FILTER == 1
        vec4 wx = TAAUCubicWeights(f.x), wy = TAAUCubicWeights(f.y);
    #else
        vec4 wx = vec4(0.0, 1.0 - f.x, f.x, 0.0), wy = vec4(0.0, 1.0 - f.y, f.y, 0.0);
    #endif
    confidence = max(wx.y, wx.z) * max(wy.y, wy.z);

    // The four bilinear centres each need a 3x3 neighbourhood: their union is just 16 source texels.
    // Clamp every read to the rendered viewport, including at odd resolutions and screen edges.
    vec3 samples[16];
    current = vec3(0.0);
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            ivec2 coord = clamp(base + ivec2(x - 1, y - 1), ivec2(0), scaledViewSize - 1);
            vec3 c = texelFetch(colortex3, coord, 0).rgb;
            current += c * wx[x] * wy[y];
            samples[y * 4 + x] = RGBToYCoCg(c);
        }
    }
    // Cubic ringing can overshoot our LDR input. Fall back to the same footprint's bilinear reconstruction.
    if (any(lessThan(current, vec3(0.0))) || any(greaterThan(current, vec3(1.0))))
        current = YCoCgToRGB(mix(mix(samples[5], samples[6], f.x), mix(samples[9], samples[10], f.x), f.y));

    vec3 lower[4], upper[4];
    for (int y = 0; y < 2; y++) {
        for (int x = 0; x < 2; x++) {
            int center = (y + 1) * 4 + x + 1;
            vec3 crossMin = min(samples[center], min(min(samples[center - 1], samples[center + 1]), min(samples[center - 4], samples[center + 4])));
            vec3 crossMax = max(samples[center], max(max(samples[center - 1], samples[center + 1]), max(samples[center - 4], samples[center + 4])));
            vec3 cornerMin = min(min(samples[center - 5], samples[center - 3]), min(samples[center + 3], samples[center + 5]));
            vec3 cornerMax = max(max(samples[center - 5], samples[center - 3]), max(samples[center + 3], samples[center + 5]));
            // Average the cross and full-square bounds, then interpolate those limits at the output sample.
            lower[y * 2 + x] = 0.5 * (crossMin + min(crossMin, cornerMin));
            upper[y * 2 + x] = 0.5 * (crossMax + max(crossMax, cornerMax));
        }
    }
    minColor = mix(mix(lower[0], lower[1], f.x), mix(lower[2], lower[3], f.x), f.y);
    maxColor = mix(mix(upper[0], upper[1], f.x), mix(upper[2], upper[3], f.x), f.y);
}

// Dilate foreground motion over silhouettes using the centre and four corners of a 5x5 footprint.
vec3 ClosestTAAUSample(sampler2D depthSampler, ivec2 texel) {
    vec3 closest = vec3(vec2(texel), texelFetch(depthSampler, texel, 0).r);
    for (int y = -2; y <= 2; y += 4) {
        for (int x = -2; x <= 2; x += 4) {
            ivec2 coord = clamp(texel + ivec2(x, y), ivec2(0), scaledViewSize - 1);
            float depth = texelFetch(depthSampler, coord, 0).r;
            if (depth < closest.z) closest = vec3(vec2(coord), depth);
        }
    }
    return closest;
}

void DoTAAU(out vec3 color, out vec3 temp, out float tempAlpha) {
    vec2 jitterPx = TAAJitter(vec2(0.0), 1.0) * scaledViewSizeF * 0.5;
    vec2 inputPos = texCoord * scaledViewSizeF + jitterPx;
    ivec2 inputTexel = clamp(ivec2(inputPos), ivec2(0), scaledViewSize - 1);

    vec3 current, minColor, maxColor;
    float confidence;
    ReconstructTAAU(inputPos, current, minColor, maxColor, confidence);
    color = current;
    temp = current;
    tempAlpha = 1.0;

    // depthtex0 includes depth-writing translucent surfaces; depthtex1 would reproject their background instead.
    vec3 closest = ClosestTAAUSample(depthtex0, inputTexel);
    mat4 projectionInverse = gbufferProjectionInverse;
    mat4 previousProjection = gbufferPreviousProjection;
    bool lodChunk = false;
    #if defined DISTANT_HORIZONS || defined VOXY
        if (closest.z == 1.0) {
            #ifdef VOXY
                vec3 lodClosest = ClosestTAAUSample(vxDepthTexTrans, inputTexel);
            #else
                vec3 lodClosest = ClosestTAAUSample(dhDepthTex, inputTexel);
            #endif
            if (lodClosest.z < 1.0) {
                closest = lodClosest;
                lodChunk = true;
                #ifdef VOXY
                    projectionInverse = vxProjInv;
                    previousProjection = vxProjPrev;
                #else
                    projectionInverse = dhProjectionInverse;
                    previousProjection = dhPreviousProjection;
                #endif
            }
        }
    #endif

    vec2 closestUV = (closest.xy + 0.5 - jitterPx) / scaledViewSizeF;
    vec4 viewPos = projectionInverse * vec4(vec3(closestUV, closest.z) * 2.0 - 1.0, 1.0);
    viewPos /= viewPos.w;
    float surfaceDistance = length(viewPos.xyz);
    bool hand = !lodChunk && closest.z < 0.56;
    // The hand stays in screen space. Other surfaces supply camera motion to the output pixel, even when the
    // closest sample belongs to a neighbouring foreground object rather than this pixel's background.
    vec2 prvCoord = texCoord;
    if (!hand)
        prvCoord += Reprojection(vec3(closestUV, closest.z), projectionInverse, previousProjection) - closestUV;

    #ifdef CLOUDS_REIMAGINED
        // Clouds have no geometry depth. Preserve their camera-translation reprojection against empty sky.
        if (!lodChunk && closest.z == 1.0) {
            float cloudDepth = texelFetch(colortex5, inputTexel, 0).a;
            if (cloudDepth == 1.0) {
                ivec2 cloudBase = ivec2(floor(inputPos - 0.5));
                for (int y = 0; y < 2; y++) {
                    for (int x = 0; x < 2; x++) {
                        ivec2 coord = clamp(cloudBase + ivec2(x, y), ivec2(0), scaledViewSize - 1);
                        if (all(equal(coord, inputTexel))) continue;
                        float depth = texelFetch(colortex5, coord, 0).a;
                        if (depth > 0.0 && any(notEqual(coord, scaledViewSize - 1)))
                            cloudDepth = min(cloudDepth, depth);
                    }
                }
            }
            // Alpha 1 is also the no-cloud value; the top-right texel may contain the light-shaft factor.
            if (cloudDepth > 0.0 && cloudDepth < 1.0 && any(notEqual(inputTexel, scaledViewSize - 1))) {
                surfaceDistance = cloudDepth * cloudDepth * renderDistance;
                vec4 ray = gbufferProjectionInverse * vec4(texCoord * 2.0 - 1.0, 1.0, 1.0);
                prvCoord = Reprojection(vec4(normalize(ray.xyz) * surfaceDistance, 1.0));
            }
        }
    #endif

    // Validate before fetching history. Alpha now holds pixel age; black is a valid history colour.
    if (any(isnan(prvCoord)) || any(isinf(prvCoord)) || any(lessThanEqual(prvCoord, vec2(0.0))) || any(greaterThanEqual(prvCoord, vec2(1.0)))) return;
    float age = texelFetch(colortex2, clamp(ivec2(prvCoord * view), ivec2(0), ivec2(view) - 1), 0).a;
    if (isnan(age) || isinf(age) || age <= 0.0) return;
    #if TAA_MOVEMENT_IMPROVEMENT_FILTER == 1
        vec3 history = textureCatmullRom(colortex2, prvCoord, view);
    #else
        vec3 history = texture2DLod(colortex2, prvCoord, 0.0).rgb;
    #endif
    if (any(isnan(history)) || any(isinf(history))) return;

    history = RGBToYCoCg(clamp(history, 0.0, 1.0));
    bool clipped = any(lessThan(history, minColor)) || any(greaterThan(history, maxColor));
    history = ClipAABB(history, minColor, maxColor);
    // Distance to the nearest clipping boundary indicates how safely history fits the current neighbourhood.
    float flickerReduction = clipped ? 0.0 : clamp(length(min(history - minColor, maxColor - history)) * 5.0, 0.0, 1.0);

    float distanceFactor = 1.0 - exp2(-0.025 * surfaceDistance);
    age = min(age + 1.0, 32.0);
    float currentWeight = max(1.0 / age, mix(0.35, 0.10, distanceFactor));
    currentWeight *= pow(confidence, 5.0) * (1.0 - flickerReduction);

    // Reduce history moderately when reprojection lands between history texels to avoid blur during motion.
    vec2 pixelOffset = 1.0 - abs(2.0 * fract(prvCoord * view) - 1.0);
    float offcenter = 0.75 + 0.25 * sqrt(max(pixelOffset.x * pixelOffset.y, 0.0));
    float historyWeight = (1.0 - currentWeight) * offcenter;
    color = clamp(mix(current, YCoCgToRGB(history), historyWeight), 0.0, 1.0);
    temp = color;
    tempAlpha = age * offcenter;
}
