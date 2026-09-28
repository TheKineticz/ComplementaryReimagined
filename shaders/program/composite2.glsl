/////////////////////////////////////
// Complementary Shaders by EminGT //
/////////////////////////////////////

#include "/lib/common.glsl"

#ifdef FRAGMENT_SHADER
    #if defined IS_IRIS && RENDER_SCALE_PCT < 100 && WORLD_BLUR == 2 && WB_DOF_FOCUS == 0
        // Iris samples the center of the whole depth target, not the scaled viewport.
        // Keep our own 1x1 history; half-float depth loses too much precision at long distances.
        uniform sampler2D colortex9;
        /*
        const int colortex9Format = R32F;
        */
        const bool colortex9Clear = false;

        #ifdef TAA
            #include "/lib/antialiasing/jitter.glsl"
        #endif

        void main() {
            vec2 center = vec2(0.5);
            #ifdef TAA
                center = TAAJitter(center, 0.5);
            #endif
            ivec2 centerTexel = clamp(ivec2(center * scaledViewSizeF), ivec2(0), scaledViewSize - 1);
            float currentDepth = texelFetch(depthtex1, centerTexel, 0).r;
            float previousDepth = texelFetch(colortex9, ivec2(0), 0).r;
            if (previousDepth <= 0.0 || previousDepth > 1.0 || isnan(previousDepth)) previousDepth = currentDepth;
            // Iris's default centerDepthHalflife of 1.0 corresponds to 0.1 seconds.
            float focusDepth = mix(previousDepth, currentDepth, 1.0 - exp2(-10.0 * frameTime));

            /* DRAWBUFFERS:9 */
            gl_FragData[0] = vec4(focusDepth, 0.0, 0.0, 1.0);
        }
    #else
        void main() { discard; } // The pass is disabled in shaders.properties.
    #endif
#endif

#ifdef VERTEX_SHADER
    void main() {
        gl_Position = ftransform();
    }
#endif
