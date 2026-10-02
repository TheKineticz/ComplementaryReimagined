// Needs texCoord and dither.glsl, plus jitter.glsl when TAA is enabled.
// Samples resolved HDR colortex0 after world blur, before bloom compositing and tonemapping.

void DoMotionBlur(inout vec3 color) {
    #ifdef TAA
        vec2 depthCoord = TAAJitter(texCoord, 0.5);
    #else
        vec2 depthCoord = texCoord;
    #endif
    float z = texture2D(depthtex1, ToBufferUV(depthCoord)).x;
    float dither = Bayer64(gl_FragCoord.xy);

    if (z > 0.56) {
        color = vec3(0.0);
        float mbwg = 0.0;
        vec2 doublePixel = 2.0 / vec2(viewWidth, viewHeight);

        vec4 currentPosition = vec4(texCoord, z, 1.0) * 2.0 - 1.0;

        vec4 viewPos = gbufferProjectionInverse * currentPosition;
        viewPos = gbufferModelViewInverse * viewPos;
        viewPos /= viewPos.w;
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
            vec3 sampleb = texture2DLod(colortex0, coordb, 0).rgb;

            color += sampleb;
            mbwg += 1.0;
        }
        color /= mbwg;
    }
}
