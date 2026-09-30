/////////////////////////////////////
// Complementary Shaders by EminGT //
/////////////////////////////////////

//Common//
#include "/lib/common.glsl"

//////////Fragment Shader//////////Fragment Shader//////////Fragment Shader//////////
#ifdef FRAGMENT_SHADER

noperspective in vec2 texCoord;

//Pipeline Constants//
#include "/lib/pipelineSettings.glsl"

const bool colortex3MipmapEnabled = true;

//Common Variables//
vec2 view = vec2(viewWidth, viewHeight);

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

//Attributes//

//Common Variables//

//Common Functions//

//Includes//

//Program//
void main() {
    gl_Position = ftransform();

    texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
}

#endif
