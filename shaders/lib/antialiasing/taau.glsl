const float handDepthThreshold = 0.56; // Hand depth is 0.44-0.56

vec3 SampleFilteredCurrent(vec2 sourcePosition) {
    // Keep samples inside the rendered area.
    sourcePosition = clamp(sourcePosition, vec2(0.5), scaledViewSizeF - 0.5);
    return TAAEncode(SampleTemporal(colortex0, sourcePosition, scaledViewSizeF));
}

vec2 GetTAAUHistoryCoord(ivec2 sourceTexel, float opaqueDepth, vec4 viewPosition, out bool isLodChunk) {
    vec2 historyCoord = texCoord;
    if (opaqueDepth > handDepthThreshold) {
        historyCoord = Reprojection(viewPosition);
    }

    isLodChunk = false;
    #if defined DISTANT_HORIZONS || defined VOXY
        if (opaqueDepth == 1.0) {
            #ifdef VOXY
                float voxyDepth = texelFetch(vxDepthTexOpaque, sourceTexel, 0).r;
                if (voxyDepth < 1.0) {
                    historyCoord = Reprojection(vec3(texCoord, voxyDepth), vxProjInv, vxProjPrev);
                    isLodChunk = true;
                }
            #elif defined DISTANT_HORIZONS
                float distantHorizonsDepth = texelFetch(dhDepthTex1, sourceTexel, 0).r;
                if (distantHorizonsDepth < 1.0) {
                    historyCoord = Reprojection(vec3(texCoord, distantHorizonsDepth),
                                                dhProjectionInverse, dhPreviousProjection);
                    isLodChunk = true;
                }
            #endif
        }
    #endif

    return historyCoord;
}

#ifdef CLOUDS_REIMAGINED
    bool IsValidTAAUCloudDepth(float cloudDepth, ivec2 sourceTexel) {
        // Cloud distance can exceed 1.0; exactly 1.0 means no cloud.
        // The top-right pixel is reserved for light shafts.
        return cloudDepth > 0.0 && cloudDepth != 1.0
            && any(notEqual(sourceTexel, scaledViewSize - 1));
    }

    float FindTAAUCloudDepth(vec2 sourcePosition, ivec2 sourceTexel) {
        float cloudDepth = texelFetch(colortex5, sourceTexel, 0).a;
        if (cloudDepth != 1.0) return cloudDepth;

        // Look for cloud depth in the other samples covered by this output pixel.
        ivec2 sampleBase = ivec2(floor(sourcePosition - 0.5));
        for (int y = 0; y < 2; y++) {
            for (int x = 0; x < 2; x++) {
                ivec2 sampleTexel = clamp(sampleBase + ivec2(x, y), ivec2(0), scaledViewSize - 1);
                if (all(equal(sampleTexel, sourceTexel))) continue;

                float sampleDepth = texelFetch(colortex5, sampleTexel, 0).a;
                if (IsValidTAAUCloudDepth(sampleDepth, sampleTexel)) {
                    cloudDepth = cloudDepth == 1.0 ? sampleDepth : min(cloudDepth, sampleDepth);
                }
            }
        }
        return cloudDepth;
    }

    vec2 ReprojectTAAUCloud(vec2 historyCoord, vec4 viewPosition, vec2 sourcePosition, ivec2 sourceTexel,
                           float sceneDepth, float opaqueDepth, bool isMoving, bool isLodChunk) {
        if (isMoving || sceneDepth != 1.0 || opaqueDepth != 1.0 || isLodChunk) return historyCoord;

        float cloudDepth = FindTAAUCloudDepth(sourcePosition, sourceTexel);
        if (!IsValidTAAUCloudDepth(cloudDepth, sourceTexel)) return historyCoord;

        float cloudDistance = cloudDepth * cloudDepth * renderDistance;
        vec4 cloudViewPosition = vec4(normalize(viewPosition.xyz) * cloudDistance, 1.0);
        return Reprojection(cloudViewPosition);
    }
#endif

vec3 ClipTAAUMovingHistory(vec3 historyColor, vec3 colorSum, vec3 colorSquaredSum, out float clipDistance) {
    vec3 mean = colorSum / 9.0;
    vec3 sigma = sqrt(max(colorSquaredSum / 9.0 - mean * mean, 0.0));
    vec3 historyYCoCg = RGBToYCoCg(historyColor);
    vec3 clippedHistory = ClipAABB(historyYCoCg, mean - sigma, mean + sigma);

    clipDistance = length(clippedHistory - historyYCoCg) / (length(sigma) + 0.01);
    return YCoCgToRGB(clippedHistory);
}

vec4 DoTAAU() {
    // Map this output pixel to the jittered source buffer.
    vec2 jitter = TAAJitter(vec2(0.0), 1.0) * scaledViewSizeF * 0.5;
    vec2 sourcePosition = texCoord * scaledViewSizeF + jitter;
    ivec2 sourceTexel = clamp(ivec2(sourcePosition), ivec2(0), scaledViewSize - 1);

    vec3 currentColor = TAAEncode(texelFetch(colortex0, sourceTexel, 0).rgb);
    vec2 texelCenterOffset = (vec2(sourceTexel) + 0.5 - sourcePosition) / renderScaleV;
    float currentSampleWeight = exp(-2.5 * dot(texelCenterOffset, texelCenterOffset));

    float opaqueDepth = texelFetch(depthtex1, sourceTexel, 0).r;
    float sceneDepth = texelFetch(depthtex0, sourceTexel, 0).r;
    int materialMask = int(texelFetch(colortex6, sourceTexel, 0).g * 255.1);

    vec4 screenPosition = vec4(texCoord, opaqueDepth, 1.0);
    vec4 viewPosition = gbufferProjectionInverse * (screenPosition * 2.0 - 1.0);
    viewPosition /= viewPosition.w;
    float viewDistance = length(viewPosition);

    #ifdef ENTITY_TAA_NOISY_CLOUD_FIX
        float cloudLinearDepth = texture2D(colortex5, ToBufferUV(texCoord)).a;
        if (pow2(cloudLinearDepth) * renderDistance < min(viewDistance, renderDistance)) {
            // The material is obstructed by the cloud volume.
            materialMask = 0;
        }
    #endif

    bool isHand = opaqueDepth < handDepthThreshold;
    bool isEntity = !isHand && (
        abs(float(materialMask) - 149.5) < 50.0 // Entity Reflection Handling (see common.glsl for details)
        || materialMask == 254 // No SSAO, No TAA, Reduce Reflection
    );
    bool isMoving = isHand || isEntity;

    // Reproject the visible surface into the previous frame.
    bool isLodChunk;
    vec2 historyCoord = GetTAAUHistoryCoord(sourceTexel, opaqueDepth, viewPosition, isLodChunk);

    #ifdef CLOUDS_REIMAGINED
        historyCoord = ReprojectTAAUCloud(
            historyCoord, viewPosition, sourcePosition, sourceTexel,
            sceneDepth, opaqueDepth, isMoving, isLodChunk
        );
    #endif

    vec3 historyColor = SampleHistory(historyCoord);

    if (historyColor == vec3(0.0) || any(isnan(historyColor))) {
        // The history is unavailable on the first frame and invalid after some camera transitions.
        return vec4(SampleFilteredCurrent(sourcePosition), 1.0);
    }

    // Store the moving-object distance blend in alpha and recover it over four frames.
    ivec2 historyTexel = clamp(ivec2(historyCoord * view), ivec2(0), ivec2(view) - 1);
    float previousHistoryAlpha = texelFetch(colortex2, historyTexel, 0).a;
    float entityDistanceFactor = isEntity ? 1.0 - exp2(-0.05 * max(viewDistance - 8.0, 0.0)) : 0.0;
    float distanceBlendFactor = isMoving ? entityDistanceFactor : previousHistoryAlpha;
    float historyAlpha = isMoving ? entityDistanceFactor : min(previousHistoryAlpha + 0.25, 1.0);
    isMoving = isMoving || previousHistoryAlpha < 1.0;

    // Gather RGB bounds and moving-object clipping data in one neighborhood pass.
    float edge = 0.0;
    vec3 colorMin = currentColor;
    vec3 colorMax = currentColor;
    vec3 colorSum = vec3(0.0);
    vec3 colorSquaredSum = vec3(0.0);
    if (isMoving) {
        colorSum = RGBToYCoCg(currentColor);
        colorSquaredSum = colorSum * colorSum;
    }

    ivec2 maxSourceTexel = scaledViewSize - 1;
    for (int i = 0; i < 8; i++) {
        ivec2 neighbourTexel = clamp(sourceTexel + neighbourhoodOffsets[i], ivec2(0), maxSourceTexel);
        vec3 neighbourColor = SampleNeighbourhood(neighbourTexel, sceneDepth, opaqueDepth,
                                                  edge, colorMin, colorMax);
        if (isMoving) {
            vec3 neighbourYCoCg = RGBToYCoCg(neighbourColor);
            colorSum += neighbourYCoCg;
            colorSquaredSum += neighbourYCoCg * neighbourYCoCg;
        }
    }

    historyColor = ClipAABB(historyColor, colorMin, colorMax);
    vec3 worldHistoryColor = historyColor; // Preserve the result before tighter moving-object clipping.

    float clipDistance = 0.0;
    if (isMoving) {
        historyColor = ClipTAAUMovingHistory(historyColor, colorSum, colorSquaredSum, clipDistance);
    }

    float historyWeight = GetHistoryWeight(historyCoord, opaqueDepth, materialMask, edge, isLodChunk);

    vec3 resolvedColor;
    if (historyWeight == 0.0) {
        resolvedColor = SampleFilteredCurrent(sourcePosition);
    } else if (isMoving) {
        float worldHistoryWeight = historyWeight;
        historyWeight = min(historyWeight, 0.80) * exp(-4.0 * clipDistance);

        // Bilinear reconstruction avoids cubic ringing on hand and entity edges.
        vec3 filteredCurrent = TAAEncode(SampleTemporalColor(colortex0, sourcePosition, scaledViewSizeF));
        filteredCurrent = mix(filteredCurrent, currentColor, currentSampleWeight);
        resolvedColor = mix(historyColor, filteredCurrent, 1.0 - historyWeight);

        // Keep more world history on distant moving objects to reduce shimmer.
        vec3 worldColor = mix(worldHistoryColor, currentColor,
                              (1.0 - worldHistoryWeight) * currentSampleWeight);
        resolvedColor = mix(resolvedColor, worldColor, distanceBlendFactor);
    } else {
        resolvedColor = mix(historyColor, currentColor, (1.0 - historyWeight) * currentSampleWeight);
    }

    return vec4(clamp(resolvedColor, 0.0, 1.0), historyAlpha);
}
