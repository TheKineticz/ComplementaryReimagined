const float taauSampleFilterSigma = 0.4;
const float taauNeighborhoodSigma = 0.75;
const float taauStableClipSigma = 2.5;
const float taauReactiveClipSigma = 1.0;

const float taauConsistentHistoryCap = 24.0;
const float taauStableHistoryCap = 12.0;
const float taauReactiveHistoryCap = 4.0;

const float taauChangeThreshold = 2.0;
const float taauChangeRange = 2.0;
const float taauReactiveParallaxPixels = 1.0;
const float taauFullClipSampleWeight = 2.0;
const float taauResampleWeightLoss = 0.1;
const float taauReactiveFillWeight = 2.0;
const float taauDetailNoiseScale = 2.0;
const float taauDetailMotionPixels = 1.0;

const float taauReflectionShare = 0.3;

const float taauNearHistoryScale = 0.1;
const float taauHistoryHalfRecoveryDistance = 32.0;

vec3 RGBToYCoCg(vec3 c) {
    return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 YCoCgToRGB(vec3 c) {
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

void TAAUDepthRange(sampler2D depthSampler, ivec2 texel, out vec3 nearest, out vec3 farthest) {
    nearest = vec3(vec2(texel), texelFetch(depthSampler, texel, 0).r);
    farthest = nearest;
    ivec2 offsets[4] = ivec2[4](
        ivec2( 1, 0),
        ivec2( 0, 1),
        ivec2(-1, 0),
        ivec2( 0,-1)
    );
    for (int i = 0; i < 4; i++) {
        ivec2 coord = clamp(texel + offsets[i], ivec2(0), scaledViewSize - 1);
        float depth = texelFetch(depthSampler, coord, 0).r;
        if (depth < nearest.z) nearest = vec3(vec2(coord), depth);
        if (depth > farthest.z) farthest = vec3(vec2(coord), depth);
    }
}

vec4 TAAUHistory(vec2 uv, out vec3 localMean, out vec3 localDeviation) {
    vec3 top, left, right, bottom;
    vec4 history, center;
    #if TAA_MOVEMENT_IMPROVEMENT_FILTER == 1
        //Catmull-Rom sampling from Filmic SMAA presentation
        vec2 position = uv * view;
        vec2 centerPosition = floor(position - 0.5) + 0.5;
        vec2 f = position - centerPosition;
        vec2 f2 = f * f;
        vec2 f3 = f * f2;

        float c = 0.7;
        vec2 w0 =        -c  * f3 +  2.0 * c         * f2 - c * f;
        vec2 w1 =  (2.0 - c) * f3 - (3.0 - c)        * f2         + 1.0;
        vec2 w2 = -(2.0 - c) * f3 + (3.0 -  2.0 * c) * f2 + c * f;
        vec2 w3 =         c  * f3 -                c * f2;

        vec2 w12 = w1 + w2;
        vec2 tc12 = (centerPosition + w2 / w12) / view;
        vec2 tc0 = (centerPosition - 1.0) / view;
        vec2 tc3 = (centerPosition + 2.0) / view;
        top = texture2DLod(colortex2, vec2(tc12.x, tc0.y), 0).rgb;
        left = texture2DLod(colortex2, vec2(tc0.x, tc12.y), 0).rgb;
        center = texture2DLod(colortex2, tc12, 0);
        right = texture2DLod(colortex2, vec2(tc3.x, tc12.y), 0).rgb;
        bottom = texture2DLod(colortex2, vec2(tc12.x, tc3.y), 0).rgb;
        vec4 color = vec4(top, 1.0)        * (w12.x * w0.y ) +
                     vec4(left, 1.0)       * (w0.x  * w12.y) +
                     vec4(center.rgb, 1.0) * (w12.x * w12.y) +
                     vec4(right, 1.0)      * (w3.x  * w12.y) +
                     vec4(bottom, 1.0)     * (w12.x * w3.y );
        history = vec4(color.rgb / color.a, center.a);
    #else
        center = texture2DLod(colortex2, uv, 0);
        history = center;
        vec2 offset = 1.5 / view;
        top = texture2DLod(colortex2, uv - vec2(0.0, offset.y), 0).rgb;
        left = texture2DLod(colortex2, uv - vec2(offset.x, 0.0), 0).rgb;
        right = texture2DLod(colortex2, uv + vec2(offset.x, 0.0), 0).rgb;
        bottom = texture2DLod(colortex2, uv + vec2(0.0, offset.y), 0).rgb;
    #endif

    vec3 t0 = RGBToYCoCg(top), t1 = RGBToYCoCg(left), t2 = RGBToYCoCg(center.rgb), t3 = RGBToYCoCg(right);
    vec3 t4 = RGBToYCoCg(bottom);
    localMean = 0.2 * (t0 + t1 + t2 + t3 + t4);
    vec3 squares = 0.2 * (t0 * t0 + t1 * t1 + t2 * t2 + t3 * t3 + t4 * t4);
    localDeviation = sqrt(max(squares - localMean * localMean, 0.0));
    return history;
}

void DoTAAU(out vec3 color, out vec3 temp, out float tempAlpha) {
    vec2 outputPerInput = view / scaledViewSizeF;
    vec2 jitterPx = TAAJitter(vec2(0.0), 1.0) * scaledViewSizeF * 0.5;
    vec2 inputPos = texCoord * scaledViewSizeF + jitterPx;
    ivec2 centerTexel = clamp(ivec2(inputPos), ivec2(0), scaledViewSize - 1);

    vec3 nearest, farthest;
    TAAUDepthRange(depthtex0, centerTexel, nearest, farthest);
    mat4 projectionInverse = gbufferProjectionInverse;
    mat4 previousProjection = gbufferPreviousProjection;
    bool lodChunk = false;
    #if defined DISTANT_HORIZONS || defined VOXY
        if (nearest.z == 1.0) {
            #ifdef VOXY
                TAAUDepthRange(vxDepthTexTrans, centerTexel, nearest, farthest);
            #else
                TAAUDepthRange(dhDepthTex, centerTexel, nearest, farthest);
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
        reactive = min(parallax / taauReactiveParallaxPixels, 1.0);

        // Nearby entities, particles and lightning have no motion vectors
        int materialMask = int(texelFetch(colortex6, centerTexel, 0).g * 255.1);
        if (!lodChunk && (abs(materialMask - 149.5) < 50.0 || materialMask == 254)) {
            float texelSize = focalLength / outputPerInput.y * abs(nearView.w / nearView.z) / 16.0;
            reactive = max(reactive, clamp(texelSize - 1.0, 0.0, 1.0));
        }

        float surfaceDistance = length(nearView.xyz / nearView.w);
        weightScale = mix(taauNearHistoryScale, 1.0, 1.0 - exp2(-surfaceDistance / taauHistoryHalfRecoveryDistance));
    }

    // Reflection-dominated translucents follow their mirror image
    vec2 reflection = texelFetch(colortex10, centerTexel, 0).rg;
    if (!lodChunk && reflection.g > taauReflectionShare) {
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
    vec2 sampleK = -0.7213475 / (taauSampleFilterSigma * taauSampleFilterSigma) * outputPerInput * outputPerInput;
    vec3 sampleX = exp2(dx2 * sampleK.x), sampleY = exp2(dy2 * sampleK.y);
    vec3 stableX = exp2(dx2 * (-0.7213475 / (taauNeighborhoodSigma * taauNeighborhoodSigma)));
    vec3 stableY = exp2(dy2 * (-0.7213475 / (taauNeighborhoodSigma * taauNeighborhoodSigma)));
    vec3 tentX = max(1.0 - abs(dx), 0.0), tentY = max(1.0 - abs(dy), 0.0);

    vec3 sampleSum = vec3(0.0), fill = vec3(0.0);
    vec3 minColor = vec3(1e9), maxColor = vec3(-1e9);
    vec3 stableSum = vec3(0.0), stableSquares = vec3(0.0);
    vec3 reactiveSum = vec3(0.0), reactiveSquares = vec3(0.0);
    float sampleWeight = 0.0, stableWeight = 0.0, reactiveWeight = 0.0;
    for (int y = 0; y < 3; y++) {
        for (int x = 0; x < 3; x++) {
            ivec2 coord = clamp(centerTexel + ivec2(x - 1, y - 1), ivec2(0), scaledViewSize - 1);
            vec3 c = texelFetch(colortex3, coord, 0).rgb;
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
    vec4 history = TAAUHistory(prvCoord, historyMean, historyDeviation);
    float historyWeight = history.a;
    bool validHistory = all(greaterThan(prvCoord, vec2(0.0))) && all(lessThan(prvCoord, vec2(1.0))) &&
                        historyWeight > 0.0 && !any(isnan(history)) && !any(isinf(history));

    vec3 clipped = vec3(0.0);
    float maxWeight = taauReactiveHistoryCap;
    if (validHistory) {
        vec3 historyYCoCg = RGBToYCoCg(clamp(history.rgb, 0.0, 1.0));

        // Prevents thin detail flickering when standing still
        float stillness = clamp(1.0 - length((texCoord - prvCoord) * view) / taauDetailMotionPixels, 0.0, 1.0);
        vec3 detail = historyDeviation * stillness;

        vec3 spread = sqrt(stableDeviation * stableDeviation + taauDetailNoiseScale * taauDetailNoiseScale * detail * detail);
        vec3 standardError = spread * sqrt(reactiveWeight) / stableWeight + 0.01;
        float change = length((stableMean - historyMean) / standardError);
        reactive = max(reactive, clamp((change - taauChangeThreshold) / taauChangeRange, 0.0, 1.0));

        vec3 stableSpread = taauStableClipSigma * stableDeviation, reactiveSpread = taauReactiveClipSigma * reactiveDeviation;
        vec3 widen = detail * (1.0 - reactive);
        vec3 boxMin = max(minColor - widen, mix(stableMean - stableSpread - widen, reactiveMean - reactiveSpread, reactive));
        vec3 boxMax = min(maxColor + widen, mix(stableMean + stableSpread + widen, reactiveMean + reactiveSpread, reactive));
        clipped = ClipAABB(historyYCoCg, boxMin, boxMax);
        clipped = mix(historyYCoCg, clipped, max(min(sampleWeight / taauFullClipSampleWeight, 1.0), reactive));

        float rejection = length(clipped - historyYCoCg) / (0.5 * length(boxMax - boxMin) + 0.004);
        historyWeight /= 1.0 + rejection * rejection;

        vec2 texelFraction = fract(prvCoord * view - 0.5);
        vec2 resample = 1.0 - taauResampleWeightLoss * 4.0 * texelFraction * (1.0 - texelFraction);
        historyWeight *= resample.x * resample.y;

        float stableCap = mix(taauConsistentHistoryCap, taauStableHistoryCap, min(change / taauChangeThreshold, 1.0));
        maxWeight = mix(stableCap, taauReactiveHistoryCap, reactive) * weightScale;
        historyWeight = min(historyWeight, maxWeight);
    } else {
        historyWeight = 0.0;
    }

    float fillWeight = max(1.0 + taauReactiveFillWeight * reactive - historyWeight - sampleWeight, 0.0);
    color = historyWeight * YCoCgToRGB(clipped) + sampleSum + fillWeight * fill;
    color = clamp(color / (historyWeight + sampleWeight + fillWeight), 0.0, 1.0);
    temp = color;
    tempAlpha = min(historyWeight + sampleWeight, maxWeight);
}
