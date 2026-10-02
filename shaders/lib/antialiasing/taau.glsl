const float SampleFilterSigma = 0.4;
const float NeighborhoodSigma = 0.75;
const float StableClipSigma = 2.5;
const float ReactiveClipSigma = 1.0;

const float ConsistentHistoryCap = 12.0;
const float StableHistoryCap = 6.0;
const float ReactiveHistoryCap = 2.0;

const float ChangeThreshold = 2.0;
const float ChangeRange = 2.0;
const float ReactiveParallaxPixels = 1.0;
const float FullClipSampleWeight = 2.0;
const float ResampleWeightLoss = 0.1;
const float ReactiveFillWeight = 2.0;
const float DetailNoiseScale = 2.0;
const float DetailMotionPixels = 1.0;

const float ReflectionShare = 0.3;

const float NearHistoryScale = 0.2;
const float HistoryHalfRecoveryDistance = 32.0;

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
        reactive = min(parallax / ReactiveParallaxPixels, 1.0);

        float surfaceDistance = length(nearView.xyz / nearView.w);
        weightScale = mix(NearHistoryScale, 1.0, 1.0 - exp2(-surfaceDistance / HistoryHalfRecoveryDistance));
    }

    // Reflection-dominated translucents follow their mirror image
    vec2 reflection = texelFetch(colortex10, centerTexel, 0).rg;
    if (!lodChunk && reflection.g > ReflectionShare) {
        vec4 ray = gbufferProjectionInverse * vec4(texCoord * 2.0 - 1.0, 1.0, 1.0);
        prvCoord = Reprojection(vec4(normalize(ray.xyz) * reflection.r, 1.0));
    }

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
                vec4 ray = gbufferProjectionInverse * vec4(texCoord * 2.0 - 1.0, 1.0, 1.0);
                prvCoord = Reprojection(vec4(normalize(ray.xyz) * (cloudDepth * cloudDepth * renderDistance), 1.0));
            }
        }
    #endif

    vec2 centerOffset = vec2(centerTexel) + 0.5 - inputPos;
    vec3 dx = centerOffset.x + vec3(-1.0, 0.0, 1.0), dy = centerOffset.y + vec3(-1.0, 0.0, 1.0);
    vec3 dx2 = dx * dx, dy2 = dy * dy;
    vec2 sampleK = -0.7213475 / (SampleFilterSigma * SampleFilterSigma) * outputPerInput * outputPerInput;
    vec3 sampleX = exp2(dx2 * sampleK.x), sampleY = exp2(dy2 * sampleK.y);
    vec3 stableX = exp2(dx2 * (-0.7213475 / (NeighborhoodSigma * NeighborhoodSigma)));
    vec3 stableY = exp2(dy2 * (-0.7213475 / (NeighborhoodSigma * NeighborhoodSigma)));
    vec3 tentX = max(1.0 - abs(dx), 0.0), tentY = max(1.0 - abs(dy), 0.0);

    vec3 sampleSum = vec3(0.0), fill = vec3(0.0);
    vec3 minColor = vec3(1e9), maxColor = vec3(-1e9);
    vec3 stableSum = vec3(0.0), stableSquares = vec3(0.0);
    vec3 reactiveSum = vec3(0.0), reactiveSquares = vec3(0.0);
    float sampleWeight = 0.0, stableWeight = 0.0, reactiveWeight = 0.0;
    for (int y = 0; y < 3; y++) {
        for (int x = 0; x < 3; x++) {
            ivec2 coord = clamp(centerTexel + ivec2(x - 1, y - 1), ivec2(0), scaledViewSize - 1);
            vec3 c = TAAEncode(texelFetch(colortex0, coord, 0).rgb);
            float w = sampleX[x] * sampleY[y];
            sampleSum += w * c;
            sampleWeight += w;
            fill += tentX[x] * tentY[y] * c;

            vec3 ycocg = RGBToYCoCg(c);
            minColor = min(minColor, ycocg);
            maxColor = max(maxColor, ycocg);
            float s = stableX[x] * stableY[y];
            stableSum += s * ycocg;
            stableSquares += s * ycocg * ycocg;
            stableWeight += s;
            float r = s * s;
            reactiveSum += r * ycocg;
            reactiveSquares += r * ycocg * ycocg;
            reactiveWeight += r;
        }
    }
    vec3 stableMean = stableSum / stableWeight;
    vec3 stableDeviation = sqrt(max(stableSquares / stableWeight - stableMean * stableMean, 0.0));
    vec3 reactiveMean = reactiveSum / reactiveWeight;
    vec3 reactiveDeviation = sqrt(max(reactiveSquares / reactiveWeight - reactiveMean * reactiveMean, 0.0));

    vec3 historyMean, historyDeviation;
    vec4 history = SampleHistory(prvCoord, historyMean, historyDeviation);
    float historyWeight = history.a;
    bool validHistory = all(greaterThan(prvCoord, vec2(0.0))) && all(lessThan(prvCoord, vec2(1.0))) &&
                        historyWeight > 0.0 && !any(isnan(history)) && !any(isinf(history));

    vec3 clipped = vec3(0.0);
    float maxWeight = ReactiveHistoryCap;
    if (validHistory) {
        vec3 historyYCoCg = RGBToYCoCg(clamp(history.rgb, 0.0, 1.0));

        // Prevents thin detail flickering when standing still; distant detail barely moves on screen, so it keeps
        // the allowance while the camera moves
        float stillness = clamp(1.0 - length((texCoord - prvCoord) * view) / DetailMotionPixels, 0.0, 1.0);
        float farness = (weightScale - NearHistoryScale) / (1.0 - NearHistoryScale);
        vec3 detail = historyDeviation * max(stillness, farness * farness);

        vec3 spread = sqrt(stableDeviation * stableDeviation + DetailNoiseScale * DetailNoiseScale * detail * detail);
        vec3 standardError = spread * sqrt(reactiveWeight) / stableWeight + 0.01;
        float change = length((stableMean - historyMean) / standardError);
        reactive = max(reactive, clamp((change - ChangeThreshold) / ChangeRange, 0.0, 1.0));

        vec3 stableSpread = StableClipSigma * stableDeviation, reactiveSpread = ReactiveClipSigma * reactiveDeviation;
        vec3 boxMin = max(minColor, mix(stableMean - stableSpread, reactiveMean - reactiveSpread, reactive));
        vec3 boxMax = min(maxColor, mix(stableMean + stableSpread, reactiveMean + reactiveSpread, reactive));
        clipped = ClipAABB(historyYCoCg, boxMin, boxMax);
        clipped = mix(historyYCoCg, clipped, max(min(sampleWeight / FullClipSampleWeight, 1.0), reactive));

        float rejection = length(clipped - historyYCoCg) / (0.5 * length(boxMax - boxMin) + 0.004);
        historyWeight /= 1.0 + rejection * rejection;

        vec2 texelFraction = fract(prvCoord * view - 0.5);
        vec2 resample = 1.0 - ResampleWeightLoss * 4.0 * texelFraction * (1.0 - texelFraction);
        historyWeight *= resample.x * resample.y;

        float stableCap = mix(ConsistentHistoryCap, StableHistoryCap, min(change / ChangeThreshold, 1.0));
        maxWeight = mix(stableCap, ReactiveHistoryCap, reactive) * weightScale;
        historyWeight = min(historyWeight, maxWeight);
    } else {
        historyWeight = 0.0;
    }

    float fillWeight = max(1.0 + ReactiveFillWeight * reactive - historyWeight - sampleWeight, 0.0);
    vec3 color = historyWeight * YCoCgToRGB(clipped) + sampleSum + fillWeight * fill;
    color = clamp(color / (historyWeight + sampleWeight + fillWeight), 0.0, 1.0);
    return vec4(color, min(historyWeight + sampleWeight, maxWeight));
}
