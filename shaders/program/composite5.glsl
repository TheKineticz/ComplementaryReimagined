/////////////////////////////////////
// Complementary Shaders by EminGT //
/////////////////////////////////////

//Common//
#include "/lib/common.glsl"

#if defined TAAU && MOTION_BLUR_EFFECT == 1
    // Motion blur needs neighbouring upscaled HDR pixels. Leave post-processing to composite6.
    #ifdef FRAGMENT_SHADER
        noperspective in vec2 texCoord;

        vec2 view = vec2(viewWidth, viewHeight);

        float GetLinearDepth(float depth) {
            return (2.0 * near) / (far + near - depth * (far - near));
        }

        #include "/lib/antialiasing/jitter.glsl"
        #include "/lib/antialiasing/taa.glsl"
        #include "/lib/antialiasing/taau.glsl"

        void main() {
            vec3 color, temp;
            float tempAlpha;
            DoTAAU(color, temp, tempAlpha);

            /* DRAWBUFFERS:02 */
            gl_FragData[0] = vec4(TAAUDecode(color), 1.0);
            gl_FragData[1] = vec4(temp, tempAlpha);
        }
    #endif

    #ifdef VERTEX_SHADER
        noperspective out vec2 texCoord;

        void main() {
            gl_Position = ftransform();
            texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
        }
    #endif
#else
    #include "/lib/misc/postProcessing.glsl"
#endif
