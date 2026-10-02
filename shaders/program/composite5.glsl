/////////////////////////////////////
// Complementary Shaders by EminGT //
/////////////////////////////////////

//Common//
#include "/lib/common.glsl"

// Resolve native TAA or TAAU in HDR. Only this pass writes temporal history;
// depth of field, motion blur, bloom compositing and tonemapping follow it.

//////////Fragment Shader//////////Fragment Shader//////////Fragment Shader//////////
#ifdef FRAGMENT_SHADER

noperspective in vec2 texCoord;

//Pipeline Constants//
#include "/lib/pipelineSettings.glsl"

vec2 view = vec2(viewWidth, viewHeight);

float GetLinearDepth(float depth) {
    return (2.0 * near) / (far + near - depth * (far - near));
}

#ifdef TAA
    #include "/lib/antialiasing/temporalColor.glsl"
    #include "/lib/antialiasing/taa.glsl"
    #ifdef TAAU
        #include "/lib/antialiasing/jitter.glsl"
        #include "/lib/antialiasing/taau.glsl"
    #endif
#endif

void main() {
    #ifdef TAAU
        vec3 color, temp;
        float tempAlpha;
        DoTAAU(color, temp, tempAlpha);
        color = TAADecode(color);
    #else
        vec3 color = texelFetch(colortex0, texelCoord, 0).rgb;
        #ifdef TAA
            color = TAAEncode(color);
            vec3 temp = vec3(0.0);
            float tempAlpha = 1.0;
            float z1 = texelFetch(depthtex1, texelCoord, 0).r;
            DoTAA(color, temp, z1);
            color = TAADecode(color);
        #endif
    #endif

    #ifdef TAA
        /* DRAWBUFFERS:02 */
        gl_FragData[1] = vec4(temp, tempAlpha);
    #else
        /* DRAWBUFFERS:0 */
    #endif
    gl_FragData[0] = vec4(color, 1.0);
}

#endif

//////////Vertex Shader//////////Vertex Shader//////////Vertex Shader//////////
#ifdef VERTEX_SHADER

noperspective out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
}

#endif
