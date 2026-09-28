// Render Scale upscaling (see RENDER_SCALE_PCT in common.glsl)
//
// The frame so far was rendered, jittered, into the bottom-left scaledViewSize pixels of the render targets. Each
// output pixel takes the scaled render's sample nearest to it, weighted by how close that sample landed to the
// pixel's center, and accumulates it into the full resolution history. With the TAA jitter walking the samples
// through each pixel, a still image converges to full resolution detail. Where there is no usable history
// (first frame, off-screen, invalid), a filtered upscale of the current frame is used instead. Catmull-Rom Sampling
// selects Catmull-Rom or bilinear filtering for both this reconstruction and the history reads.
//
// Entities, particles, lightning and the hand move by themselves and have no motion vectors. They are jittered and
// accumulated too, but with a shorter history, clipped harder and cut the more the clip corrects it, and their current
// frame comes from the selected filter rather than the nearest sample alone. Beyond 8 blocks they blend towards the
// world's treatment with distance, as Photon treats everything: a steady image for some blur in motion.

vec3 RGBToYCoCg(vec3 c) {
    return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 YCoCgToRGB(vec3 c) {
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

vec2 GetScaledInputPos() {
    vec2 jitterPx = TAAJitter(vec2(0.0), 1.0) * scaledViewSizeF * 0.5; // where this frame sampled, in scaled pixels
    return texCoord * scaledViewSizeF + jitterPx;
}

// Reconstruct the current frame using the same sampling option as history. Clamp to rendered texel centers so
// neither filter reads the unused part of the targets, preserving the sample position at the screen edges.
vec3 GetCurrentUpscale(vec2 inputPos) {
    vec2 position = clamp(inputPos, vec2(0.5), scaledViewSizeF - 0.5);
    #if TAA_MOVEMENT_IMPROVEMENT_FILTER == 1
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
        vec2 tc12 = clamp(centerPosition + w2 / w12, vec2(0.5), scaledViewSizeF - 0.5) / view;
        vec2 tc0 = clamp(centerPosition - 1.0, vec2(0.5), scaledViewSizeF - 0.5) / view;
        vec2 tc3 = clamp(centerPosition + 2.0, vec2(0.5), scaledViewSizeF - 0.5) / view;
        vec4 color = vec4(texture2DLod(colortex3, vec2(tc12.x, tc0.y ), 0).rgb, 1.0) * (w12.x * w0.y ) +
                     vec4(texture2DLod(colortex3, vec2(tc0.x,  tc12.y), 0).rgb, 1.0) * (w0.x  * w12.y) +
                     vec4(texture2DLod(colortex3, vec2(tc12.x, tc12.y), 0).rgb, 1.0) * (w12.x * w12.y) +
                     vec4(texture2DLod(colortex3, vec2(tc3.x,  tc12.y), 0).rgb, 1.0) * (w3.x  * w12.y) +
                     vec4(texture2DLod(colortex3, vec2(tc12.x, tc3.y ), 0).rgb, 1.0) * (w12.x * w3.y );
        return color.rgb / color.a;
    #else
        return texture2DLod(colortex3, position / view, 0.0).rgb;
    #endif
}

// The native TAA's depth-edge and colour bounds, sampled at a clamped scaled-image texel.
vec3 TAAUNeighbourhoodSample(ivec2 coord, float z0, float z1, inout float edge, inout vec3 minclr, inout vec3 maxclr) {
    float z0CheckLinear = GetLinearDepth(texelFetch(depthtex0, coord, 0).r);
    float z1CheckLinear = GetLinearDepth(texelFetch(depthtex1, coord, 0).r);
    float z0Linear = GetLinearDepth(z0);
    float z1Linear = GetLinearDepth(z1);
    if (max(abs(z0CheckLinear - z0Linear), abs(z1CheckLinear - z1Linear)) > 0.09) {
        edge = regularEdge;

        float approxClosestDist = min(z0CheckLinear, z0Linear) * far;
        if (approxClosestDist < farEdgeDist)
            if (int(texelFetch(colortex6, coord, 0).g * 255.1) == 253) // Reduced Edge TAA (Leaves)
                edge *= extraEdgeMult;
    }

    vec3 clr = texelFetch(colortex3, coord, 0).rgb;
    minclr = min(minclr, clr); maxclr = max(maxclr, clr);
    return clr;
}

void DoTAAU(out vec3 color, out vec3 temp, out float tempAlpha) {
    vec2 inputPos = GetScaledInputPos();
    ivec2 inputTexel = clamp(ivec2(inputPos), ivec2(0), scaledViewSize - 1);

    vec3 currentSample = texelFetch(colortex3, inputTexel, 0).rgb;
    // Distance from this pixel's center to where that sample was taken, in output pixels
    vec2 sampleOffset = (vec2(inputTexel) + 0.5 - inputPos) / renderScaleV;
    float sampleWeight = exp(-2.5 * dot(sampleOffset, sampleOffset));

    temp = vec3(0.0);
    tempAlpha = 1.0;

    float z1 = texelFetch(depthtex1, inputTexel, 0).r;
    vec4 materialData = texelFetch(colortex6, inputTexel, 0);
    int materialMask = int(materialData.g * 255.1);

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

    // What moves by itself: its history is reprojected for the camera only, the hand's not at all (it moves with the
    // camera), and clipped harder below
    bool hand = z1 < 0.56; // the hand's own projection squeezes it into depth 0.44-0.56
    bool entity = !hand && (
        abs(materialMask - 149.5) < 50.0 // Entity Reflection Handling (see common.glsl for details)
        || materialMask == 254 // No SSAO, No TAA, Reduce Reflection
    );
    bool dynamic = hand || entity;

    float z0 = texelFetch(depthtex0, inputTexel, 0).r;

    vec2 prvCoord = texCoord;
    if (z1 > 0.56) prvCoord = Reprojection(viewPos1);

    #if defined DISTANT_HORIZONS || defined VOXY
        bool lodChunk = false;
        if (z1 == 1.0) {
            #ifdef VOXY
                float vxDepth = texelFetch(vxDepthTexOpaque, inputTexel, 0).r;
                if (vxDepth < 1.0) {
                    vec3 vxCoord = vec3(texCoord, vxDepth);
                    prvCoord = Reprojection(vxCoord, vxProjInv, vxProjPrev);
                    lodChunk = true;
                }
            #elif defined DISTANT_HORIZONS
                float dhDepth = texelFetch(dhDepthTex1, inputTexel, 0).r;
                if (dhDepth < 1.0) {
                    vec3 dhCoord = vec3(texCoord, dhDepth);
                    prvCoord = Reprojection(dhCoord, dhProjectionInverse, dhPreviousProjection);
                    lodChunk = true;
                }
            #endif
        }
    #endif

    #if TAA_MOVEMENT_IMPROVEMENT_FILTER == 1
        vec3 tempColor = textureCatmullRom(colortex2, prvCoord, view);
    #else
        vec3 tempColor = texture2D(colortex2, prvCoord).rgb;
    #endif

    if (tempColor == vec3(0.0) || any(isnan(tempColor))) { // Fixes the first frame and nans
        color = GetCurrentUpscale(inputPos);
        temp = color;
        return;
    }

    // Far away a moving object covers few pixels, and the jitter changes its neighbourhood completely every frame:
    // the hard clip below would keep rejecting its history and it would shimmer. Beyond 8 blocks it takes the
    // world's treatment instead, more of it with distance (entityFactor).
    // History alpha: entityFactor where a moving object was (0 up close), rising back to 1 over 4 frames. The world
    // just uncovered behind one is treated like the object for those frames, so a close one doesn't leave a trail.
    float historyAlpha = texelFetch(colortex2, clamp(ivec2(prvCoord * view), ivec2(0), ivec2(view) - 1), 0).a;
    float entityFactor = entity ? 1.0 - exp2(-0.05 * max(lViewPos1 - 8.0, 0.0)) : 0.0;
    // Translucent geometry may never write depthtex1. Its own distance must cap the background's blend.
    // Opaque entities keep alpha 1 and retain their existing distance-dependent stability.
    entityFactor = min(entityFactor, materialData.a);
    float distanceFactor = dynamic ? entityFactor : historyAlpha;
    tempAlpha = dynamic ? entityFactor : min(historyAlpha + 0.25, 1.0);
    dynamic = dynamic || historyAlpha < 1.0;

    // Gather RGB bounds and, for moving objects, YCoCg moments from the same samples.
    // Depth-edge checks stay unconditional, including while the camera is stationary.
    float edge = 0.0;
    vec3 minclr = currentSample, maxclr = currentSample;
    vec3 m1 = vec3(0.0), m2 = vec3(0.0);
    if (dynamic) {
        m1 = RGBToYCoCg(currentSample);
        m2 = m1 * m1;
    }
    ivec2 maxTexel = scaledViewSize - 1;
    for (int i = 0; i < 8; i++) {
        vec3 clr = TAAUNeighbourhoodSample(clamp(inputTexel + neighbourhoodOffsets[i], ivec2(0), maxTexel), z0, z1, edge, minclr, maxclr);
        if (dynamic) {
            vec3 ycocg = RGBToYCoCg(clr);
            m1 += ycocg; m2 += ycocg * ycocg;
        }
    }
    tempColor = ClipAABB(tempColor, minclr, maxclr);
    vec3 tempColorWorld = tempColor; // before the moving-object clip below

    // Moving objects: clip the history to the neighbourhood's mean +- 1 sigma in YCoCg, noting how far that had to
    // move it
    float dynamicClip = 0.0;
    if (dynamic) {
        m1 /= 9.0;
        vec3 sigma = sqrt(max(m2 / 9.0 - m1 * m1, 0.0));
        vec3 history = RGBToYCoCg(tempColor);
        vec3 clipped = ClipAABB(history, m1 - sigma, m1 + sigma);
        dynamicClip = length(clipped - history) / (length(sigma) + 0.01);
        tempColor = YCoCgToRGB(clipped);
    }

    if (materialMask == 253) // Reduced Edge TAA (Leaves)
        edge *= extraEdgeMult;

    #if defined DISTANT_HORIZONS || defined VOXY
        if (lodChunk) {
            blendMinimum = 0.75;
            blendVariable = 0.05;
            blendConstant = 0.85;
            edge = 0.0;
        }
    #endif

    vec2 velocity = (texCoord - prvCoord.xy) * view;
    float blendFactor = float(prvCoord.x > 0.0 && prvCoord.x < 1.0 &&
                              prvCoord.y > 0.0 && prvCoord.y < 1.0);
    float velocityFactor = dot(velocity, velocity) * 10.0;

    #ifdef END
        if (z1 == 1.0)
        #if defined DISTANT_HORIZONS || defined VOXY
            if (!lodChunk)
        #endif
        {
            blendVariable *= 0.0;
            #if LIGHTSHAFT_QUALI_DEFINE == 2 // Medium (Default)
                edge = max(edge, regularEdge * 0.5);
            #elif LIGHTSHAFT_QUALI_DEFINE == 3 // High
                edge = max(edge, regularEdge * 0.75);
            #elif LIGHTSHAFT_QUALI_DEFINE == 4 // Very High
                edge = max(edge, regularEdge);
            #endif
        }
    #endif

    blendFactor *= max(exp(-velocityFactor) * blendVariable + blendConstant - min(length(cameraPosition - previousCameraPosition), 0.05) * edge, blendMinimum);

    // Off-screen history (blendFactor 0) falls back to the reconstructed current frame.
    if (blendFactor == 0.0) {
        color = GetCurrentUpscale(inputPos);
    } else if (dynamic) {
        // A shorter history, and less of it the more the clip above had to correct it. The current frame takes its
        // full share, from the nearest sample where that covers this pixel well and a filtered upscale elsewhere.
        float worldBlendFactor = blendFactor;
        blendFactor = min(blendFactor, 0.75) * exp(-4.0 * dynamicClip);
        vec3 current = mix(GetCurrentUpscale(inputPos), currentSample, sampleWeight);
        color = mix(tempColor, current, 1.0 - blendFactor);
        // Towards the world's result with distance (see entityFactor)
        vec3 worldColor = mix(tempColorWorld, currentSample, (1.0 - worldBlendFactor) * sampleWeight);
        color = mix(color, worldColor, distanceFactor);
    } else {
        // The native TAA's share for the current frame, given to the nearest sample by how well it covers this pixel
        color = mix(tempColor, currentSample, (1.0 - blendFactor) * sampleWeight);
    }
    temp = color;
}
