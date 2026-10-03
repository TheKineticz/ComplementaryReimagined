vec3 SampleCurrent(vec2 inputPosition) {
    // Keep the reconstruction inside the rendered part of the HDR buffer.
    vec2 position = clamp(inputPosition, vec2(0.5), scaledViewSizeF - 0.5);
    return TAAEncode(SampleTemporal(colortex0, position, scaledViewSizeF));
}

vec4 DoTAAU() {
    vec3 color;
    float historyAlpha = 1.0;
    vec2 jitter = TAAJitter(vec2(0.0), 1.0) * scaledViewSizeF * 0.5;
    vec2 inputPosition = texCoord * scaledViewSizeF + jitter;
    ivec2 inputCoord = clamp(ivec2(inputPosition), ivec2(0), scaledViewSize - 1);

    vec3 currentSample = TAAEncode(texelFetch(colortex0, inputCoord, 0).rgb);
    // Sample distance in output pixels determines its contribution to this pixel.
    vec2 sampleOffset = (vec2(inputCoord) + 0.5 - inputPosition) / renderScaleV;
    float sampleWeight = exp(-2.5 * dot(sampleOffset, sampleOffset));

    float z1 = texelFetch(depthtex1, inputCoord, 0).r;
    int materialMask = int(texelFetch(colortex6, inputCoord, 0).g * 255.1);

    vec4 screenPos1 = vec4(texCoord, z1, 1.0);
    vec4 viewPos1 = gbufferProjectionInverse * (screenPos1 * 2.0 - 1.0);
    viewPos1 /= viewPos1.w;
    float lViewPos1 = length(viewPos1);

    #ifdef ENTITY_TAA_NOISY_CLOUD_FIX
        float cloudLinearDepth = texture2D(colortex5, ToBufferUV(texCoord)).a;

        if (pow2(cloudLinearDepth) * renderDistance < min(lViewPos1, renderDistance)) {
            materialMask = 0;
        }
    #endif

    bool hand = z1 < 0.56; // Hand depth is 0.44-0.56
    bool entity = !hand && (
        abs(materialMask - 149.5) < 50.0 // Entity Reflection Handling (see common.glsl for details)
        || materialMask == 254 // No SSAO, No TAA, Reduce Reflection
    );
    bool moving = hand || entity;

    float z0 = texelFetch(depthtex0, inputCoord, 0).r;

    vec2 previousCoord = texCoord;
    if (z1 > 0.56) previousCoord = Reprojection(viewPos1);

    bool lodChunk = false;
    #if defined DISTANT_HORIZONS || defined VOXY
        if (z1 == 1.0) {
            #ifdef VOXY
                float vxDepth = texelFetch(vxDepthTexOpaque, inputCoord, 0).r;
                if (vxDepth < 1.0) {
                    vec3 vxCoord = vec3(texCoord, vxDepth);
                    previousCoord = Reprojection(vxCoord, vxProjInv, vxProjPrev);
                    lodChunk = true;
                }
            #elif defined DISTANT_HORIZONS
                float dhDepth = texelFetch(dhDepthTex1, inputCoord, 0).r;
                if (dhDepth < 1.0) {
                    vec3 dhCoord = vec3(texCoord, dhDepth);
                    previousCoord = Reprojection(dhCoord, dhProjectionInverse, dhPreviousProjection);
                    lodChunk = true;
                }
            #endif
        }
    #endif

    #ifdef CLOUDS_REIMAGINED
        // Reproject sky clouds using their raymarched distance.
        if (!moving && z0 == 1.0 && z1 == 1.0
            #if defined DISTANT_HORIZONS || defined VOXY
                && !lodChunk
            #endif
        ) {
            float cloudDepth = texelFetch(colortex5, inputCoord, 0).a;
            // Include clouds in the reconstruction footprint of a sky sample.
            if (cloudDepth == 1.0) {
                ivec2 cloudBase = ivec2(floor(inputPosition - 0.5));
                for (int y = 0; y < 2; y++) {
                    for (int x = 0; x < 2; x++) {
                        ivec2 coord = clamp(cloudBase + ivec2(x, y), ivec2(0), scaledViewSize - 1);
                        if (all(equal(coord, inputCoord))) continue;
                        float depth = texelFetch(colortex5, coord, 0).a;
                        if (depth > 0.0 && depth != 1.0 && any(notEqual(coord, scaledViewSize - 1)))
                            cloudDepth = cloudDepth == 1.0 ? depth : min(cloudDepth, depth);
                    }
                }
            }

            // Distances may exceed 1 in the floating-point target; exactly 1 means no cloud.
            // The top-right texel can store light-shaft data.
            if (cloudDepth > 0.0 && cloudDepth != 1.0 && any(notEqual(inputCoord, scaledViewSize - 1))) {
                float cloudDistance = cloudDepth * cloudDepth * renderDistance;
                vec4 cloudViewPos = vec4(normalize(viewPos1.xyz) * cloudDistance, 1.0);
                previousCoord = Reprojection(cloudViewPos);
            }
        }
    #endif

    vec3 historyColor = SampleHistory(previousCoord);

    if (historyColor == vec3(0.0) || any(isnan(historyColor))) { // First frame or invalid history
        return vec4(SampleCurrent(inputPosition), 1.0);
    }

    // Alpha records the distance blend of moving objects, recovering over four frames.
    float previousAlpha = texelFetch(colortex2, clamp(ivec2(previousCoord * view), ivec2(0), ivec2(view) - 1), 0).a;
    float entityFactor = entity ? 1.0 - exp2(-0.05 * max(lViewPos1 - 8.0, 0.0)) : 0.0;
    float distanceFactor = moving ? entityFactor : previousAlpha;
    historyAlpha = moving ? entityFactor : min(previousAlpha + 0.25, 1.0);
    moving = moving || previousAlpha < 1.0;

    // Gather RGB bounds and moving-object YCoCg moments from the same neighborhood.
    float edge = 0.0;
    vec3 colorMin = currentSample, colorMax = currentSample;
    vec3 colorSum = vec3(0.0), colorSquaredSum = vec3(0.0);
    if (moving) {
        colorSum = RGBToYCoCg(currentSample);
        colorSquaredSum = colorSum * colorSum;
    }
    ivec2 maxTexel = scaledViewSize - 1;
    for (int i = 0; i < 8; i++) {
        vec3 colorSample = SampleNeighbourhood(clamp(inputCoord + neighbourhoodOffsets[i], ivec2(0), maxTexel), z0, z1, edge, colorMin, colorMax);
        if (moving) {
            vec3 ycocg = RGBToYCoCg(colorSample);
            colorSum += ycocg;
            colorSquaredSum += ycocg * ycocg;
        }
    }
    historyColor = ClipAABB(historyColor, colorMin, colorMax);
    vec3 worldHistory = historyColor; // Before moving-object variance clipping

    // Moving objects use mean +/- one standard deviation; correction reduces history.
    float clipDistance = 0.0;
    if (moving) {
        vec3 mean = colorSum / 9.0;
        vec3 sigma = sqrt(max(colorSquaredSum / 9.0 - mean * mean, 0.0));
        vec3 historyYCoCg = RGBToYCoCg(historyColor);
        vec3 clipped = ClipAABB(historyYCoCg, mean - sigma, mean + sigma);
        clipDistance = length(clipped - historyYCoCg) / (length(sigma) + 0.01);
        historyColor = YCoCgToRGB(clipped);
    }

    float historyWeight = GetHistoryWeight(previousCoord, z1, materialMask, edge, lodChunk);

    if (historyWeight == 0.0) {
        color = SampleCurrent(inputPosition);
    } else if (moving) {
        float worldHistoryWeight = historyWeight;
        historyWeight = min(historyWeight, 0.75) * exp(-4.0 * clipDistance);
        vec3 current = mix(SampleCurrent(inputPosition), currentSample, sampleWeight);
        color = mix(historyColor, current, 1.0 - historyWeight);
        // Distant moving objects favor world accumulation to limit shimmer.
        vec3 worldColor = mix(worldHistory, currentSample, (1.0 - worldHistoryWeight) * sampleWeight);
        color = mix(color, worldColor, distanceFactor);
    } else {
        color = mix(historyColor, currentSample, (1.0 - historyWeight) * sampleWeight);
    }
    return vec4(clamp(color, 0.0, 1.0), historyAlpha);
}
