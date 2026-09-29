// Render Scale upscaling (see RENDER_SCALE_PCT in common.glsl)
//
// Each frame renders one jittered sample per scaled pixel. Every output pixel keeps a running weighted average of the
// samples that landed near its centre: this frame's samples are weighted by their distance to the centre, in output
// pixels, and added to the history. History alpha holds how much sample weight the average already contains, so a new
// pixel settles within a few frames while a settled one takes only small corrections. Where that weight is still low,
// a bilinear reconstruction of the current frame fills in.
//
// The history is then checked against the current samples around the pixel, more or less strictly depending on
// whether the pixel is changing. A change test compares the local mean of the current samples with the blurred history,
// relative to how much the jitter alone moves that mean; the parallax between the nearest and farthest surface around
// the pixel marks where the camera uncovers background; and nearby entities, which have no motion vectors, always
// count as changing. Unchanged pixels keep a long history that is only loosely checked, so that fine distant detail
// stays calm; changing ones are clipped hard and keep little of their past.

const float taauSampleSigma = 0.4;        // accumulation Gaussian, in output pixels
const float taauStableSigma = 0.75;       // neighbourhood statistics for unchanged pixels, in scaled pixels
const float taauReactiveSigma = 0.5;      // neighbourhood statistics for changing pixels, in scaled pixels
const float taauStableGamma = 2.5;        // variance box size for unchanged pixels, in standard deviations
const float taauReactiveGamma = 1.0;      // variance box size for changing pixels, in standard deviations
const float taauConsistentWeight = 24.0;  // history weight cap where the local mean matches the history exactly
const float taauStableWeight = 12.0;      // history weight cap at the change test's threshold
const float taauReactiveWeight = 4.0;     // history weight cap for changing pixels and the hand
const float taauChangeThreshold = 2.0;    // change test: standard errors up to which a pixel counts as unchanged
const float taauChangeRange = 2.0;        // change test: further standard errors until a pixel is fully reactive
const float taauParallaxRange = 1.0;      // parallax that makes a pixel fully reactive, in output pixels
const float taauClipSampleWeight = 2.0;   // sample weight that makes the check of an unchanged pixel a full clip
const float taauResampleLoss = 0.1;       // weight lost per axis when history is read halfway between texels
const float taauReactiveFill = 2.0;       // extra weight changing pixels take from the bilinear reconstruction

vec3 RGBToYCoCg(vec3 c) {
    return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 YCoCgToRGB(vec3 c) {
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// Nearest and farthest depth, as (texel, depth), over texel and its four edge neighbours
void TAAUDepthRange(sampler2D depthSampler, ivec2 texel, out vec3 nearest, out vec3 farthest) {
    nearest = vec3(vec2(texel), texelFetch(depthSampler, texel, 0).r);
    farthest = nearest;
    ivec2 offsets[4] = ivec2[4](ivec2(1, 0), ivec2(0, 1), ivec2(-1, 0), ivec2(0, -1));
    for (int i = 0; i < 4; i++) {
        ivec2 coord = clamp(texel + offsets[i], ivec2(0), scaledViewSize - 1);
        float depth = texelFetch(depthSampler, coord, 0).r;
        if (depth < nearest.z) nearest = vec3(vec2(coord), depth);
        if (depth > farthest.z) farthest = vec3(vec2(coord), depth);
    }
}

// History read at uv, with the history's Catmull-Rom sampling when that is on. Alpha is the history weight near uv.
// lowPass receives a blurred history, about three pixels wide, for the change test.
vec4 TAAUHistory(vec2 uv, out vec3 lowPass) {
    #if TAA_MOVEMENT_IMPROVEMENT_FILTER == 1
        // The five-tap Catmull-Rom of textureCatmullRom (taa.glsl), whose taps also make the blurred history
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
        vec3 top = texture2DLod(colortex2, vec2(tc12.x, tc0.y), 0).rgb;
        vec3 left = texture2DLod(colortex2, vec2(tc0.x, tc12.y), 0).rgb;
        vec4 center = texture2DLod(colortex2, tc12, 0);
        vec3 right = texture2DLod(colortex2, vec2(tc3.x, tc12.y), 0).rgb;
        vec3 bottom = texture2DLod(colortex2, vec2(tc12.x, tc3.y), 0).rgb;
        lowPass = 0.2 * (top + left + center.rgb + right + bottom);
        vec4 color = vec4(top, 1.0) * (w12.x * w0.y) + vec4(left, 1.0) * (w0.x * w12.y)
                   + vec4(center.rgb, 1.0) * (w12.x * w12.y)
                   + vec4(right, 1.0) * (w3.x * w12.y) + vec4(bottom, 1.0) * (w12.x * w3.y);
        return vec4(color.rgb / color.a, center.a);
    #else
        vec4 history = texture2DLod(colortex2, uv, 0);
        lowPass = history.rgb;
        return history;
    #endif
}

void DoTAAU(out vec3 color, out vec3 temp, out float tempAlpha) {
    vec2 outputPerInput = view / scaledViewSizeF;
    vec2 jitterPx = TAAJitter(vec2(0.0), 1.0) * scaledViewSizeF * 0.5; // this frame's sample offset, in scaled pixels
    vec2 inputPos = texCoord * scaledViewSizeF + jitterPx; // this pixel's centre on the jittered scaled image
    ivec2 centerTexel = clamp(ivec2(inputPos), ivec2(0), scaledViewSize - 1);

    // Reprojection: the pixel takes the camera motion of the nearest surface around it, so that silhouettes move with
    // the foreground. depthtex0 includes depth-writing translucents.
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

    // How strictly the history is checked, from 0 (unchanged pixel) to 1. The hand (depth below 0.56) moves with the
    // camera, so it keeps its screen position and is always checked strictly.
    float reactive = 1.0;
    vec2 prvCoord = texCoord;
    if (lodChunk || nearest.z >= 0.56) {
        vec2 nearestUV = (nearest.xy + 0.5 - jitterPx) / scaledViewSizeF;
        prvCoord += Reprojection(vec3(nearestUV, nearest.z), projectionInverse, previousProjection) - nearestUV;

        // Parallax: camera translation moves a surface on screen by the focal length / its distance * the shift
        // across the view ray. Where the nearest and farthest surface around the pixel move apart, the history may
        // show the other one, like the background uncovered behind an edge. 1 / distance is linear in depth.
        vec2 ndc = texCoord * 2.0 - 1.0;
        vec4 nearView = projectionInverse * vec4(ndc, nearest.z * 2.0 - 1.0, 1.0);
        vec4 farView = projectionInverse * vec4(ndc, farthest.z * 2.0 - 1.0, 1.0);
        vec3 cameraShift = mat3(gbufferModelView) * (cameraPosition - previousCameraPosition);
        vec2 ray = ndc / vec2(gbufferProjection[0][0], gbufferProjection[1][1]);
        float focalLength = 0.5 * viewHeight * gbufferProjection[1][1]; // in output pixels
        float inverseDistanceGap = abs(nearView.w / nearView.z - farView.w / farView.z);
        float parallax = focalLength * inverseDistanceGap * length(cameraShift.xy + ray * cameraShift.z);
        reactive = min(parallax / taauParallaxRange, 1.0);

        // Entities, particles and lightning move without motion vectors (native TAA leaves them out). Up close, where a
        // texel of theirs spans a scaled pixel or more, a sliding texture shows as smearing, so they are checked
        // strictly. Further away they are treated like the world, which keeps their sub-pixel detail from shimmering.
        int materialMask = int(texelFetch(colortex6, centerTexel, 0).g * 255.1);
        if (!lodChunk && (abs(materialMask - 149.5) < 50.0 || materialMask == 254)) {
            float texelSize = focalLength / outputPerInput.y * abs(nearView.w / nearView.z) / 16.0; // in scaled pixels
            reactive = max(reactive, clamp(texelSize - 1.0, 0.0, 1.0));
        }
    }

    #ifdef CLOUDS_REIMAGINED
        // Clouds write no geometry depth. Against the sky, reproject with their raymarched distance so that camera
        // translation moves them like the cloud, not like the far plane.
        if (!lodChunk && nearest.z == 1.0) {
            float cloudDepth = texelFetch(colortex5, centerTexel, 0).a;
            if (cloudDepth == 1.0) {
                // A sky sample can still contribute to a pixel partly covered by cloud; take the cloud's distance
                // from the bilinear footprint then.
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
            // Alpha 1 is also the no-cloud value, and the top-right texel may hold the light-shaft factor.
            if (cloudDepth > 0.0 && cloudDepth < 1.0 && any(notEqual(centerTexel, scaledViewSize - 1))) {
                vec4 ray = gbufferProjectionInverse * vec4(texCoord * 2.0 - 1.0, 1.0, 1.0);
                prvCoord = Reprojection(vec4(normalize(ray.xyz) * (cloudDepth * cloudDepth * renderDistance), 1.0));
            }
        }
    #endif

    // One pass over the 3x3 scaled samples around the pixel centre gathers the accumulation sum (narrow Gaussian of
    // the distance in output pixels), a bilinear reconstruction (tent weights), and YCoCg bounds and moments with a
    // wider and a narrower Gaussian for the history check. The Gaussians are separable, exp2(-d^2 log2(e) / 2 sigma^2).
    vec2 centerOffset = vec2(centerTexel) + 0.5 - inputPos; // centre sample relative to the pixel centre
    vec3 dx = centerOffset.x + vec3(-1.0, 0.0, 1.0), dy = centerOffset.y + vec3(-1.0, 0.0, 1.0);
    vec3 dx2 = dx * dx, dy2 = dy * dy;
    vec2 sampleK = -0.7213475 / (taauSampleSigma * taauSampleSigma) * outputPerInput * outputPerInput;
    vec3 sampleX = exp2(dx2 * sampleK.x), sampleY = exp2(dy2 * sampleK.y);
    vec3 stableX = exp2(dx2 * (-0.7213475 / (taauStableSigma * taauStableSigma)));
    vec3 stableY = exp2(dy2 * (-0.7213475 / (taauStableSigma * taauStableSigma)));
    vec3 reactiveX = exp2(dx2 * (-0.7213475 / (taauReactiveSigma * taauReactiveSigma)));
    vec3 reactiveY = exp2(dy2 * (-0.7213475 / (taauReactiveSigma * taauReactiveSigma)));
    vec3 tentX = max(1.0 - abs(dx), 0.0), tentY = max(1.0 - abs(dy), 0.0);

    vec3 sampleSum = vec3(0.0), fill = vec3(0.0), lo = vec3(1e9), hi = vec3(-1e9);
    vec3 stableSum = vec3(0.0), stableSquares = vec3(0.0), reactiveSum = vec3(0.0), reactiveSquares = vec3(0.0);
    float sampleWeight = 0.0, stableWeight = 0.0, stableWeight2 = 0.0, reactiveWeight = 0.0;
    for (int y = 0; y < 3; y++) {
        for (int x = 0; x < 3; x++) {
            ivec2 coord = clamp(centerTexel + ivec2(x - 1, y - 1), ivec2(0), scaledViewSize - 1);
            vec3 c = texelFetch(colortex3, coord, 0).rgb;
            float w = sampleX[x] * sampleY[y];
            sampleSum += w * c;
            sampleWeight += w;
            fill += tentX[x] * tentY[y] * c;

            vec3 ycocg = RGBToYCoCg(c);
            lo = min(lo, ycocg);
            hi = max(hi, ycocg);
            float s = stableX[x] * stableY[y];
            stableSum += s * ycocg;
            stableSquares += s * ycocg * ycocg;
            stableWeight += s;
            stableWeight2 += s * s;
            float r = reactiveX[x] * reactiveY[y];
            reactiveSum += r * ycocg;
            reactiveSquares += r * ycocg * ycocg;
            reactiveWeight += r;
        }
    }
    vec3 stableMean = stableSum / stableWeight;
    vec3 stableDeviation = sqrt(max(stableSquares / stableWeight - stableMean * stableMean, 0.0));
    vec3 reactiveMean = reactiveSum / reactiveWeight;
    vec3 reactiveDeviation = sqrt(max(reactiveSquares / reactiveWeight - reactiveMean * reactiveMean, 0.0));

    vec3 historyLowPass;
    vec4 history = TAAUHistory(prvCoord, historyLowPass);
    float historyWeight = history.a;
    bool validHistory = all(greaterThan(prvCoord, vec2(0.0))) && all(lessThan(prvCoord, vec2(1.0)))
                     && historyWeight > 0.0 && !any(isnan(history)) && !any(isinf(history));

    vec3 clipped = vec3(0.0);
    float maxWeight = taauReactiveWeight;
    if (validHistory) {
        vec3 historyYCoCg = RGBToYCoCg(clamp(history.rgb, 0.0, 1.0));

        // Change test: the jitter barely moves the wide local mean of the current samples, so a mean that differs
        // from the blurred history by several of its standard errors means the content changed
        vec3 standardError = stableDeviation * sqrt(stableWeight2) / stableWeight + 0.01;
        float change = length((stableMean - RGBToYCoCg(clamp(historyLowPass, 0.0, 1.0))) / standardError);
        reactive = max(reactive, clamp((change - taauChangeThreshold) / taauChangeRange, 0.0, 1.0));

        // Clip the history into the box of the current samples: a loose one for unchanged pixels, a tight one for
        // changing pixels. An unchanged pixel is only clipped as far as this frame's samples cover it, because the
        // few samples around it can miss detail that the history rightly holds.
        vec3 stableSpread = taauStableGamma * stableDeviation, reactiveSpread = taauReactiveGamma * reactiveDeviation;
        vec3 boxMin = max(lo, mix(stableMean - stableSpread, reactiveMean - reactiveSpread, reactive));
        vec3 boxMax = min(hi, mix(stableMean + stableSpread, reactiveMean + reactiveSpread, reactive));
        clipped = ClipAABB(historyYCoCg, boxMin, boxMax);
        clipped = mix(historyYCoCg, clipped, max(min(sampleWeight / taauClipSampleWeight, 1.0), reactive));

        // History loses weight the further it had to move, relative to the box...
        float rejection = length(clipped - historyYCoCg) / (0.5 * length(boxMax - boxMin) + 0.004);
        historyWeight /= 1.0 + rejection * rejection;

        // ...and when it was read between texels, which blurs it
        vec2 texelFraction = fract(prvCoord * view - 0.5);
        vec2 resample = 1.0 - taauResampleLoss * 4.0 * texelFraction * (1.0 - texelFraction);
        historyWeight *= resample.x * resample.y;

        // Unchanged pixels may keep a longer history, the more so the closer their mean matches the history
        float stableCap = mix(taauConsistentWeight, taauStableWeight, min(change / taauChangeThreshold, 1.0));
        maxWeight = mix(stableCap, taauReactiveWeight, reactive);
        historyWeight = min(historyWeight, maxWeight);
    } else {
        historyWeight = 0.0;
    }

    // Below about a sample's worth of weight (a few samples' worth for changing pixels), the bilinear reconstruction of
    // the current frame fills in, which keeps sparse samples from showing the scaled pixel grid
    float fillWeight = max(1.0 + taauReactiveFill * reactive - historyWeight - sampleWeight, 0.0);
    color = historyWeight * YCoCgToRGB(clipped) + sampleSum + fillWeight * fill;
    color = clamp(color / (historyWeight + sampleWeight + fillWeight), 0.0, 1.0);
    temp = color;
    tempAlpha = min(historyWeight + sampleWeight, maxWeight);
}
