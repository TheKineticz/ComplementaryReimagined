const float sampleFilterSigma = 0.4;
const float neighborhoodSigma = 0.75;
const float stableClipSigma = 2.5;
const float reactiveClipSigma = 1.0;

const float consistentHistoryCap = 12.0;
const float stableHistoryCap = 6.0;
const float reactiveHistoryCap = 2.0;

const float changeThreshold = 2.0;
const float changeRange = 2.0;
const float reactiveParallaxPixels = 1.0;
const float fullClipSampleWeight = 2.0;
const float resampleWeightLoss = 0.1;
const float reactiveFillWeight = 2.0;
const float detailNoiseScale = 2.0;
const float detailMotionPixels = 1.0;

const float reflectionShare = 0.3;

const float nearHistoryScale = 0.2;
const float historyHalfRecoveryDistance = 32.0;

void DepthRange(sampler2D depthSampler, ivec2 texel, out vec3 nearest, out vec3 farthest) {
    nearest = vec3(vec2(texel), texelFetch(depthSampler, texel, 0).r);
    farthest = nearest;
    for (int i = 4; i < 8; i++) { // Cardinal neighbors
        ivec2 coord = clamp(texel + neighbourhoodOffsets[i], ivec2(0), scaledViewSize - 1);
        float depth = texelFetch(depthSampler, coord, 0).r;
        if (depth < nearest.z) nearest = vec3(vec2(coord), depth);
        if (depth > farthest.z) farthest = vec3(vec2(coord), depth);
    }
}

vec4 DoTAAU() {
    vec2 outputPerInput = view / scaledViewSizeF;
    vec2 jitterPx = TAAJitter(vec2(0.0), 1.0) * scaledViewSizeF * 0.5;
    vec2 inputPos = texCoord * scaledViewSizeF + jitterPx;
    ivec2 centerTexel = clamp(ivec2(inputPos), ivec2(0), scaledViewSize - 1);

    vec3 nearest, farthest;
    DepthRange(depthtex0, centerTexel, nearest, farthest);
    mat4 projectionInverse = gbufferProjectionInverse;
    mat4 previousProjection = gbufferPreviousProjection;
    bool lodChunk = false;
    #if defined DISTANT_HORIZONS || defined VOXY
        if (nearest.z == 1.0) {
            #ifdef VOXY
                DepthRange(vxDepthTexTrans, centerTexel, nearest, farthest);
            #else
                DepthRange(dhDepthTex, centerTexel, nearest, farthest);
            #endif
            if (nearest.z < 1.0) {
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

    float reactive = 1.0, weightScale = 1.0;
    vec2 prvCoord = texCoord;
    if (lodChunk || nearest.z >= 0.56) {
        vec2 nearestUV = (nearest.xy + 0.5 - jitterPx) / scaledViewSizeF;
        prvCoord += Reprojection(vec3(nearestUV, nearest.z), projectionInverse, previousProjection) - nearestUV;

        vec2 ndc = texCoord * 2.0 - 1.0;
        vec4 nearView = projectionInverse * vec4(ndc, nearest.z * 2.0 - 1.0, 1.0);
        vec4 farView = projectionInverse * vec4(ndc, farthest.z * 2.0 - 1.0, 1.0);
        vec3 cameraShift = mat3(gbufferModelView) * (cameraPosition - previousCameraPosition);
        vec2 ray = ndc / vec2(gbufferProjection[0][0], gbufferProjection[1][1]);
        float focalLength = 0.5 * viewHeight * gbufferProjection[1][1];
        float inverseDistanceGap = abs(nearView.w / nearView.z - farView.w / farView.z);
        float parallax = focalLength * inverseDistanceGap * length(cameraShift.xy + ray * cameraShift.z);
        reactive = min(parallax / reactiveParallaxPixels, 1.0); // Less history at moving depth edges

        float surfaceDistance = length(nearView.xyz / nearView.w);
        weightScale = mix(nearHistoryScale, 1.0, 1.0 - exp2(-surfaceDistance / historyHalfRecoveryDistance));
    }

    // Reflection-dominated translucents follow their mirror image
    vec2 reflection = texelFetch(colortex10, centerTexel, 0).rg;
    bool useRayReprojection = !lodChunk && reflection.g > reflectionShare;
    float reprojectionDistance = reflection.r;

    #ifdef CLOUDS_REIMAGINED
        if (!lodChunk && nearest.z == 1.0) {
            float cloudDepth = texelFetch(colortex5, centerTexel, 0).a;
            if (cloudDepth == 1.0) {
                ivec2 cloudBase = ivec2(floor(inputPos - 0.5));
                for (int y = 0; y < 2; y++) {
                    for (int x = 0; x < 2; x++) {
                        ivec2 coord = clamp(cloudBase + ivec2(x, y), ivec2(0), scaledViewSize - 1);
                        float depth = texelFetch(colortex5, coord, 0).a;
                        if (depth > 0.0 && any(notEqual(coord, scaledViewSize - 1)))
                            cloudDepth = min(cloudDepth, depth);
                    }
                }
            }
            // Top right pixel stores vlFactor
            if (cloudDepth > 0.0 && cloudDepth < 1.0 && any(notEqual(centerTexel, scaledViewSize - 1))) {
                useRayReprojection = true;
                reprojectionDistance = cloudDepth * cloudDepth * renderDistance;
            }
        }
    #endif

    if (useRayReprojection) {
        vec4 ray = gbufferProjectionInverse * vec4(texCoord * 2.0 - 1.0, 1.0, 1.0);
        prvCoord = Reprojection(vec4(normalize(ray.xyz) * reprojectionDistance, 1.0));
    }

    vec2 centerOffset = vec2(centerTexel) + 0.5 - inputPos;
    vec3 dx = centerOffset.x + vec3(-1.0, 0.0, 1.0), dy = centerOffset.y + vec3(-1.0, 0.0, 1.0);
    vec3 dx2 = dx * dx, dy2 = dy * dy;
    // -0.5 / ln(2) converts Gaussian weights to exp2
    vec2 sampleK = -0.7213475 / (sampleFilterSigma * sampleFilterSigma) * outputPerInput * outputPerInput;
    vec3 sampleX = exp2(dx2 * sampleK.x), sampleY = exp2(dy2 * sampleK.y);
    vec3 neighborhoodX = exp2(dx2 * (-0.7213475 / (neighborhoodSigma * neighborhoodSigma)));
    vec3 neighborhoodY = exp2(dy2 * (-0.7213475 / (neighborhoodSigma * neighborhoodSigma)));
    vec3 tentX = max(1.0 - abs(dx), 0.0), tentY = max(1.0 - abs(dy), 0.0);

    vec3 sampleSum = vec3(0.0), fill = vec3(0.0);
    // One neighborhood distribution drives change detection and clipping
    vec3 neighborhoodSum = vec3(0.0), neighborhoodSquares = vec3(0.0);
    float sampleWeight = 0.0, neighborhoodWeight = 0.0, neighborhoodSquaredWeight = 0.0;
    for (int y = 0; y < 3; y++) {
        for (int x = 0; x < 3; x++) {
            ivec2 coord = clamp(centerTexel + ivec2(x - 1, y - 1), ivec2(0), scaledViewSize - 1);
            vec3 c = TAAEncode(texelFetch(colortex0, coord, 0).rgb);
            float w = sampleX[x] * sampleY[y];
            sampleSum += w * c;
            sampleWeight += w;
            fill += tentX[x] * tentY[y] * c;

            vec3 ycocg = RGBToYCoCg(c);
            float s = neighborhoodX[x] * neighborhoodY[y];
            neighborhoodSum += s * ycocg;
            neighborhoodSquares += s * ycocg * ycocg;
            neighborhoodWeight += s;
            neighborhoodSquaredWeight += s * s;
        }
    }
    vec3 neighborhoodMean = neighborhoodSum / neighborhoodWeight;
    vec3 neighborhoodDeviation = sqrt(max(neighborhoodSquares / neighborhoodWeight - neighborhoodMean * neighborhoodMean, 0.0));

    vec3 historyMean, historyDeviation;
    vec4 history = SampleHistory(prvCoord, historyMean, historyDeviation);
    float historyWeight = history.a; // Accumulated sample weight
    bool validHistory = all(greaterThan(prvCoord, vec2(0.0))) && all(lessThan(prvCoord, vec2(1.0))) &&
                        historyWeight > 0.0 && !any(isnan(history)) && !any(isinf(history));

    vec3 clipped = vec3(0.0);
    float maxWeight = reactiveHistoryCap;
    if (validHistory) {
        vec3 historyYCoCg = RGBToYCoCg(clamp(history.rgb, 0.0, 1.0));

        // Prevents thin detail flickering when still or far away
        float stillness = clamp(1.0 - length((texCoord - prvCoord) * view) / detailMotionPixels, 0.0, 1.0);
        float farness = (weightScale - nearHistoryScale) / (1.0 - nearHistoryScale);
        vec3 detail = historyDeviation * max(stillness, farness * farness);

        vec3 spread = sqrt(neighborhoodDeviation * neighborhoodDeviation + detailNoiseScale * detailNoiseScale * detail * detail);
        // Squared weights estimate noise in the weighted neighborhood mean
        vec3 standardError = spread * sqrt(neighborhoodSquaredWeight) / neighborhoodWeight + 0.01;
        float change = length((neighborhoodMean - historyMean) / standardError); // Color change relative to local variation
        reactive = max(reactive, clamp((change - changeThreshold) / changeRange, 0.0, 1.0));

        vec3 clipSpread = mix(stableClipSigma, reactiveClipSigma, reactive) * neighborhoodDeviation;
        vec3 boxMin = neighborhoodMean - clipSpread;
        vec3 boxMax = neighborhoodMean + clipSpread;
        clipped = ClipAABB(historyYCoCg, boxMin, boxMax);
        clipped = mix(historyYCoCg, clipped, max(min(sampleWeight / fullClipSampleWeight, 1.0), reactive));

        float rejection = length(clipped - historyYCoCg) / (0.5 * length(boxMax - boxMin) + 0.004);
        historyWeight /= 1.0 + rejection * rejection;

        vec2 texelFraction = fract(prvCoord * view - 0.5);
        vec2 resample = 1.0 - resampleWeightLoss * 4.0 * texelFraction * (1.0 - texelFraction);
        historyWeight *= resample.x * resample.y;

        float stableCap = mix(consistentHistoryCap, stableHistoryCap, min(change / changeThreshold, 1.0));
        maxWeight = mix(stableCap, reactiveHistoryCap, reactive) * weightScale;
        historyWeight = min(historyWeight, maxWeight);
    } else {
        historyWeight = 0.0;
    }

    float fillWeight = max(1.0 + reactiveFillWeight * reactive - historyWeight - sampleWeight, 0.0);
    vec3 color = historyWeight * YCoCgToRGB(clipped) + sampleSum + fillWeight * fill;
    color = clamp(color / (historyWeight + sampleWeight + fillWeight), 0.0, 1.0);
    return vec4(color, min(historyWeight + sampleWeight, maxWeight));
}
