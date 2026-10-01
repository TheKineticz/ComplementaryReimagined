// Needs texCoord and dither.glsl, plus bloomFog.glsl for MOTION_BLUR_BLOOM_FOG_FIX
// With TAAU this runs after the upscale and mixes the tonemapped image roughly as it would in HDR

#ifdef TAAU
    #include "/lib/util/approxTonemap.glsl"
    #define motionBlurTex colortex3
    #define MotionBlurDecode(color) UndoTonemapApprox(color)
    #define MotionBlurEncode(color) RedoTonemapApprox(color)
#else
    #define motionBlurTex colortex0
    #define MotionBlurDecode(color) (color)
    #define MotionBlurEncode(color) (color)
#endif

void DoMotionBlur(inout vec3 color) {
    float z = texture2D(depthtex1, ToBufferUV(texCoord)).x;
    float dither = Bayer64(gl_FragCoord.xy);

    if (z > 0.56) {
        color = vec3(0.0);
        float mbwg = 0.0;
        vec2 doublePixel = 2.0 / vec2(viewWidth, viewHeight);

        vec4 currentPosition = vec4(texCoord, z, 1.0) * 2.0 - 1.0;

        vec4 viewPos = gbufferProjectionInverse * currentPosition;
        viewPos = gbufferModelViewInverse * viewPos;
        viewPos /= viewPos.w;
        float lViewPos = length(viewPos.xyz);

        #if defined DISTANT_HORIZONS || defined VOXY
            #ifdef DISTANT_HORIZONS
                float z1lod = texelFetch(dhDepthTex1, texelCoord, 0).r;
                vec4 screenPos1Lod = vec4(texCoord, z1lod, 1.0);
                vec4 viewPos1Lod = dhProjectionInverse * (screenPos1Lod * 2.0 - 1.0);
            #elif defined VOXY
                float z1lod = texelFetch(vxDepthTexOpaque, texelCoord, 0).r;
                vec4 screenPos1Lod = vec4(texCoord, z1lod, 1.0);
                vec4 viewPos1Lod = vxProjInv * (screenPos1Lod * 2.0 - 1.0);
            #endif
            viewPos1Lod /= viewPos1Lod.w;
            lViewPos = min(lViewPos, length(viewPos1Lod.xyz));
        #endif

        vec3 cameraOffset = cameraPosition - previousCameraPosition;

        vec4 previousPosition = viewPos + vec4(cameraOffset, 0.0);
        previousPosition = gbufferPreviousModelView * previousPosition;
        previousPosition = gbufferPreviousProjection * previousPosition;
        previousPosition /= previousPosition.w;

        vec2 velocity = (currentPosition - previousPosition).xy;
        velocity = velocity / (1.0 + length(velocity)) * MOTION_BLURRING_STRENGTH;

        #ifndef LOW_QUALITY_MOTION_BLUR
            int sampleCount = 9;
            velocity *= 0.02;
        #else
            int sampleCount = 3;
            velocity *= 0.06;
        #endif

        vec2 coord = texCoord - velocity * (float(sampleCount) / 2.0 - 1.0 + dither);
        for (int i = 0; i < sampleCount; i++, coord += velocity) {
            vec2 coordb = clamp(coord, doublePixel, 1.0 - doublePixel);
            vec3 sampleb = MotionBlurDecode(texture2DLod(motionBlurTex, coordb, 0).rgb);

            #ifdef MOTION_BLUR_BLOOM_FOG_FIX
                float z1 = texture2D(depthtex1, coordb).r;
                vec4 screenPos = vec4(coordb, z1, 1.0);
                vec4 viewPos = gbufferProjectionInverse * (screenPos * 2.0 - 1.0);
                viewPos /= viewPos.w;
                float lViewPos = length(viewPos.xyz);

                #if defined DISTANT_HORIZONS || defined VOXY
                    #ifdef DISTANT_HORIZONS
                        float z1lod = texture2D(dhDepthTex1, coordb).r;
                        vec4 screenPos1Lod = vec4(texCoord, z1lod, 1.0);
                        vec4 viewPos1Lod = dhProjectionInverse * (screenPos1Lod * 2.0 - 1.0);
                    #elif defined VOXY
                        float z1lod = texture2D(vxDepthTexOpaque, coordb).r;
                        vec4 screenPos1Lod = vec4(texCoord, z1lod, 1.0);
                        vec4 viewPos1Lod = vxProjInv * (screenPos1Lod * 2.0 - 1.0);
                    #endif
                    viewPos1Lod /= viewPos1Lod.w;
                    lViewPos = min(lViewPos, length(viewPos1Lod.xyz));
                #endif

                // Remove bloom fog from mb samples or else we get edge artifacts
                sampleb /= GetBloomFog(lViewPos);
            #endif

            color += sampleb;
            mbwg += 1.0;
        }
        color = MotionBlurEncode(color / mbwg);

        #ifdef MOTION_BLUR_BLOOM_FOG_FIX
            // Reapply bloom fog because we removed it from our samples
            color *= GetBloomFog(lViewPos);
        #endif
    }
}
