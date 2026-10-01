vec2 lensFlareCheckOffsets[4] = vec2[4](
    vec2( 1.0,0.0),
    vec2(-1.0,1.0),
    vec2( 0.0,1.0),
    vec2( 1.0,1.0)
);

float GetLensFlareVisibility(vec2 screenPosSun, float dither) {
    float visibility = 1.0;
    vec2 cScale = 40.0 / vec2(viewWidth, viewHeight);
    for (int i = 0; i < 4; i++) {
        vec2 cOffset = (lensFlareCheckOffsets[i] - dither) * cScale;
        vec2 checkCoord1 = screenPosSun + cOffset;
        vec2 checkCoord2 = screenPosSun - cOffset;

        float zSample1 = texture2DLod(depthtex0, ToBufferUV(checkCoord1), 0.0).r;
        float zSample2 = texture2DLod(depthtex0, ToBufferUV(checkCoord2), 0.0).r;
        #ifdef VL_CLOUDS_ACTIVE
            float cloudLinearDepth1 = texture2DLod(colortex5, ToBufferUV(checkCoord1), 0.0).a;
            float cloudLinearDepth2 = texture2DLod(colortex5, ToBufferUV(checkCoord2), 0.0).a;
            zSample1 = min(zSample1, cloudLinearDepth1);
            zSample2 = min(zSample2, cloudLinearDepth2);
        #endif

        if (zSample1 < 1.0)
            visibility -= 0.125;
        if (zSample2 < 1.0)
            visibility -= 0.125;
    }

    return visibility;
}
