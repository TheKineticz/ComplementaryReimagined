/////////////////////////////////////
// Complementary Shaders by EminGT //
/////////////////////////////////////

//Common//
#include "/lib/common.glsl"

//////////Fragment Shader//////////Fragment Shader//////////Fragment Shader//////////
#ifdef FRAGMENT_SHADER

noperspective in vec2 texCoord;

//Pipeline Constants//

//Common Variables//

//Common Functions//

//Includes//
#if defined TAAU && MOTION_BLUR_EFFECT == 1
    #include "/lib/util/dither.glsl"
    #include "/lib/misc/motionBlur.glsl"
#endif

//Program//
void main() {
    #if defined TAAU && MOTION_BLUR_EFFECT == 1
        vec3 color = texelFetch(colortex3, texelCoord, 0).rgb;
        DoMotionBlur(color);

        /* DRAWBUFFERS:3 */
        gl_FragData[0] = vec4(color, 1.0);
    #else
        discard;
    #endif
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
