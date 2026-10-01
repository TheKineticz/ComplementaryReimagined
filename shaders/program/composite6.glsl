/////////////////////////////////////
// Complementary Shaders by EminGT //
/////////////////////////////////////

//Common//
#include "/lib/common.glsl"

//////////Fragment Shader//////////Fragment Shader//////////Fragment Shader//////////
#ifdef FRAGMENT_SHADER

noperspective in vec2 texCoord;

#ifdef TAAU_LENS_FLARE
    flat in vec3 upVec, sunVec;
    flat in float lensFlareVisibility;
#endif

//Pipeline Constants//
#include "/lib/pipelineSettings.glsl"

const bool colortex3MipmapEnabled = true;

//Common Variables//
vec2 view = vec2(viewWidth, viewHeight);

#ifdef TAAU_LENS_FLARE
    float SdotU = dot(sunVec, upVec);
    float sunFactor = SdotU < 0.0 ? clamp(SdotU + 0.375, 0.0, 0.75) / 0.75 : clamp(SdotU + 0.03125, 0.0, 0.0625) / 0.0625;
#endif

//Common Functions//
float GetLinearDepth(float depth) {
    return (2.0 * near) / (far + near - depth * (far - near));
}

//Includes//
#ifdef TAA
    #include "/lib/antialiasing/jitter.glsl"
    #include "/lib/antialiasing/taa.glsl"
#endif
#ifdef TAAU
    #include "/lib/antialiasing/taau.glsl"
#endif
#ifdef TAAU_LENS_FLARE
    #define LENS_FLARE_VISIBILITY lensFlareVisibility
    #include "/lib/misc/lensFlare.glsl"
#endif

//Program//
void main() {
    vec3 color;
    vec3 temp = vec3(0.0);
    float tempAlpha = 1.0;

    #ifdef TAAU
        DoTAAU(color, temp, tempAlpha);

        #ifdef TAAU_BLOOM
            // Match TAAU's current-frame position and keep the correction out of history.
            vec3 bloomCorrection = texture2DLod(colortex8, ToBufferUV(TAAJitter(texCoord, 0.5)), 0.0).rgb;
            color = clamp01(color + bloomCorrection);
        #endif

        #ifdef TAAU_LENS_FLARE
            DoLensFlare(color, vec3(0.0), 0.0);
        #endif
    #else
        color = texelFetch(colortex3, texelCoord, 0).rgb;

        #ifdef TAA
            float z1 = texelFetch(depthtex1, texelCoord, 0).r;
            DoTAA(color, temp, z1);
        #endif
    #endif

    /* DRAWBUFFERS:32 */
    gl_FragData[0] = vec4(color, 1.0);
    gl_FragData[1] = vec4(temp, tempAlpha);
}

#endif

//////////Vertex Shader//////////Vertex Shader//////////Vertex Shader//////////
#ifdef VERTEX_SHADER

noperspective out vec2 texCoord;

#ifdef TAAU_LENS_FLARE
    flat out vec3 upVec, sunVec;
    flat out float lensFlareVisibility;
#endif

//Attributes//

//Common Variables//

//Common Functions//

//Includes//
#ifdef TAAU_LENS_FLARE
    #include "/lib/misc/lensFlareVisibility.glsl"
#endif

//Program//
void main() {
    gl_Position = ftransform();

    texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;

    #ifdef TAAU_LENS_FLARE
        upVec = normalize(gbufferModelView[1].xyz);
        sunVec = GetSunVector();

        // Average the occlusion test over its dither offsets once, as this pass has no TAA to smooth per-pixel dither
        vec4 clipPosSun = gbufferProjection * vec4(sunVec + 0.001, 1.0);
        vec2 screenPosSun = clipPosSun.xy / clipPosSun.w * 0.5 + 0.5;
        lensFlareVisibility = 0.0;
        for (int i = 0; i < 8; i++) {
            lensFlareVisibility += GetLensFlareVisibility(screenPosSun, (float(i) + 0.5) / 8.0);
        }
        lensFlareVisibility /= 8.0;
    #endif
}

#endif
