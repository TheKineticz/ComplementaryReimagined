#if TAA_SMOOTHING_M == 2
    float blendMinimum = 0.3;
    float blendVariable = 0.3;
    float blendConstant = 0.6;

    float regularEdge = 10.0;
    float extraEdgeMult = 2.0;

    float farEdgeDist = 128.0;
#elif TAA_SMOOTHING_M == 3
    float blendMinimum = 0.35;
    float blendVariable = 0.2;
    float blendConstant = 0.7;

    float regularEdge = 6.0;
    float extraEdgeMult = 3.0;

    float farEdgeDist = 112.0;
#elif TAA_SMOOTHING_M == 4
    float blendMinimum = 0.5;
    float blendVariable = 0.15;
    float blendConstant = 0.75;

    float regularEdge = 4.0;
    float extraEdgeMult = 3.5;

    float farEdgeDist = 96.0;
#endif

float GetLinearDepth(float depth) {
    return (2.0 * near) / (far + near - depth * (far - near));
}

void NeighbourhoodClamping(vec3 color, inout vec3 tempColor, float z0, float z1, inout float edge) {
    vec3 minclr = color; vec3 maxclr = minclr;

    int cc = 2;
    ivec2 texelCoordM1 = clamp(texelCoord, ivec2(cc), ivec2(view) - cc); // Fixes screen edges
    for (int i = 0; i < 8; i++) {
        ivec2 texelCoordM2 = texelCoordM1 + neighbourhoodOffsets[i];

        float z0CheckLinear = GetLinearDepth(texelFetch(depthtex0, texelCoordM2, 0).r);
        float z1CheckLinear = GetLinearDepth(texelFetch(depthtex1, texelCoordM2, 0).r);
        float z0Linear = GetLinearDepth(z0);
        float z1Linear = GetLinearDepth(z1);
        if (max(abs(z0CheckLinear - z0Linear), abs(z1CheckLinear - z1Linear)) > 0.09) {
            edge = regularEdge;

            float approxClosestDist = min(z0CheckLinear, z0Linear) * far;
            if (approxClosestDist < farEdgeDist)
                if (int(texelFetch(colortex6, texelCoordM2, 0).g * 255.1) == 253) // Reduced Edge TAA (Leaves)
                    edge *= extraEdgeMult;
        }

        vec3 clr = TAAEncode(texelFetch(colortex0, texelCoordM2, 0).rgb);
        minclr = min(minclr, clr); maxclr = max(maxclr, clr);
    }

    tempColor = ClipAABB(tempColor, minclr, maxclr);
}

void DoTAA(inout vec3 color, inout vec3 temp, float z1) {
    int materialMask = int(texelFetch(colortex6, texelCoord, 0).g * 255.1);

    vec4 screenPos1 = vec4(texCoord, z1, 1.0);
    vec4 viewPos1 = gbufferProjectionInverse * (screenPos1 * 2.0 - 1.0);
    viewPos1 /= viewPos1.w;
    float lViewPos1 = length(viewPos1);

    #ifdef ENTITY_TAA_NOISY_CLOUD_FIX
        float cloudLinearDepth = texture2D(colortex5, texCoord).a;

        if (pow2(cloudLinearDepth) * renderDistance < min(lViewPos1, renderDistance)) {
            // Material in question is obstructed by the cloud volume
            materialMask = 0;
        }
    #endif

    if (
        abs(materialMask - 149.5) < 50.0 // Entity Reflection Handling (see common.glsl for details)
        || materialMask == 254 // No SSAO, No TAA, Reduce Reflection
    ) {
        return;
    }

    /*if (materialMask == 254) { // No SSAO, No TAA, Reduce Reflection
        #ifndef CUSTOM_PBR
            if (z1 <= 0.56) return; // The edge pixel trick doesn't look nice on hand
        #endif
        int i = 0;
        while (i < 4) {
            int mms = int(texelFetch(colortex6, texelCoord + neighbourhoodOffsets[i], 0).g * 255.1);
            if (mms != materialMask) break;
            i++;
        } // Checking edge-pixels prevents flickering
        if (i == 4) return;
    }*/

    float z0 = texelFetch(depthtex0, texelCoord, 0).r;

    vec2 prvCoord = texCoord;
    if (z1 > 0.56) prvCoord = Reprojection(viewPos1);

	#if defined DISTANT_HORIZONS || defined VOXY
        bool lodChunk = false;
    	if (z1 == 1.0) {
            #ifdef VOXY
                float vxDepth = texture2D(vxDepthTexOpaque, texCoord).r;
                if (vxDepth < 1.0) {
                    vec3 vxCoord = vec3(texCoord, vxDepth);
                    prvCoord = Reprojection(vxCoord, vxProjInv, vxProjPrev);
                    lodChunk = true;
                }
            #elif defined DISTANT_HORIZONS
                float dhDepth = texture2D(dhDepthTex1, texCoord).r;
                if (dhDepth < 1.0) {
                    vec3 dhCoord = vec3(texCoord, dhDepth);
                    prvCoord = Reprojection(dhCoord, dhProjectionInverse, dhPreviousProjection);
                    lodChunk = true;
                }
            #endif
        }
	#endif

    vec3 tempColor = SampleHistory(prvCoord);

    if (tempColor == vec3(0.0) || any(isnan(tempColor))) { // Fixes the first frame and nans
        temp = color;
        return;
    }

    float edge = 0.0;
    NeighbourhoodClamping(color, tempColor, z0, z1, edge);

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

    color = mix(color, tempColor, blendFactor);
    temp = color;

    //if (edge > 0.05) color.rgb = vec3(1.0, 0.0, 1.0);
}
