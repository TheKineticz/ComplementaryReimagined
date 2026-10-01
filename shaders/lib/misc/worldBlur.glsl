// Needs texCoord, sunFactor and a full-resolution colortex0 with mipmaps

#if WORLD_BLUR == 2 && WB_DOF_FOCUS >= 0
    #if WB_DOF_FOCUS == 0
        #ifdef TAAU
            uniform sampler2D colortex9;
            #define centerDepthSmooth texelFetch(colortex9, ivec2(0), 0).r
        #else
            uniform float centerDepthSmooth;
        #endif
    #else
        float centerDepthSmooth = (far * (WB_DOF_FOCUS - near)) / (WB_DOF_FOCUS * (far - near));
    #endif
#endif

vec2 dofOffsets[18] = vec2[18](
    vec2( 0.0    ,  0.25  ),
    vec2(-0.2165 ,  0.125 ),
    vec2(-0.2165 , -0.125 ),
    vec2( 0      , -0.25  ),
    vec2( 0.2165 , -0.125 ),
    vec2( 0.2165 ,  0.125 ),
    vec2( 0      ,  0.5   ),
    vec2(-0.25   ,  0.433 ),
    vec2(-0.433  ,  0.25  ),
    vec2(-0.5    ,  0     ),
    vec2(-0.433  , -0.25  ),
    vec2(-0.25   , -0.433 ),
    vec2( 0      , -0.5   ),
    vec2( 0.25   , -0.433 ),
    vec2( 0.433  , -0.2   ),
    vec2( 0.5    ,  0     ),
    vec2( 0.433  ,  0.25  ),
    vec2( 0.25   ,  0.433 )
);

// Returns whether the pixel was blurred
bool DoWorldBlur(inout vec3 color, float z1, float lViewPos0) {
    if (z1 < 0.56) return false;
    vec3 dof = vec3(0.0);
    vec2 dofScale = vec2(1.0, aspectRatio);

    #if WORLD_BLUR == 1 // Distance Blur
        #ifdef OVERWORLD
            float dbMult;
            if (isEyeInWater == 0) {
                dbMult = mix(WB_DB_NIGHT_I, WB_DB_DAY_I, sunFactor * eyeBrightnessM);
                dbMult = mix(dbMult, WB_DB_RAIN_I, rainFactor * eyeBrightnessM);
            } else dbMult = WB_DB_WATER_I;
        #elif defined NETHER
            float dbMult = WB_DB_NETHER_I;
        #elif defined END
            float dbMult = WB_DB_END_I;
        #endif
        float coc = clamp(lViewPos0 * 0.001, 0.0, 0.1) * dbMult * 0.03;
    #elif WORLD_BLUR == 2 // Depth Of Field
        #if WB_DOF_FOCUS >= 0
            float coc = max(abs(z1 - centerDepthSmooth) * 0.125 * WB_DOF_I - 0.0001, 0.0);
        #elif WB_DOF_FOCUS == -1
            float coc = clamp(abs(lViewPos0 * 0.005 - pow2(vsBrightness)), 0.0, 0.1) * WB_DOF_I * 0.03;
        #endif
    #endif
    coc = coc / sqrt(coc * coc + 0.1);

    #ifdef WB_FOV_SCALED
        coc *= gbufferProjection[1][1] * 0.8;
    #endif
    #ifdef WB_CHROMATIC
        float midDistX = texCoord.x - 0.5;
        float midDistY = texCoord.y - 0.5;
        vec2 chromaticScale = vec2(midDistX, midDistY);
        chromaticScale = sign(chromaticScale) * sqrt(abs(chromaticScale));
        chromaticScale *= vec2(1.0, viewHeight / viewWidth);
        vec2 aberration = (15.0 / vec2(viewWidth, viewHeight)) * chromaticScale * coc;
    #endif
    #ifdef WB_ANAMORPHIC
        dofScale *= vec2(0.5, 1.5);
    #endif

    if (coc * 0.5 > 1.0 / max(viewWidth, viewHeight)) {
        for (int i = 0; i < 18; i++) {
            vec2 offset = dofOffsets[i] * coc * 0.0085 * dofScale;
            float lod = log2(viewHeight * aspectRatio * coc * RENDER_SCALE_M * 0.75 / 320.0);
            #ifndef WB_CHROMATIC
                dof += texture2DLod(colortex0, texCoord + offset, lod).rgb;
            #else
                dof += vec3(texture2DLod(colortex0, texCoord + offset + aberration, lod).r,
                            texture2DLod(colortex0, texCoord + offset             , lod).g,
                            texture2DLod(colortex0, texCoord + offset - aberration, lod).b);
            #endif
        }
        dof /= 18.0;
        color = dof;
        return true;
    }
    return false;
}
