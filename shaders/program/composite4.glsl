/////////////////////////////////////
// Complementary Shaders by EminGT //
/////////////////////////////////////

//Common//
#include "/lib/common.glsl"

//////////Fragment Shader//////////Fragment Shader//////////Fragment Shader//////////
#ifdef FRAGMENT_SHADER

noperspective in vec2 texCoord;

#if MOTION_BLUR_EFFECT == 1 && defined MOTION_BLUR_BLOOM_FOG_FIX
    flat in vec3 upVec, sunVec;
#endif

//Pipeline Constants//
#ifdef TAAU_BLOOM
    uniform sampler2D colortex11;
    const bool colortex11MipmapEnabled = true;
    #define sceneTex colortex11
#else
    const bool colortex0MipmapEnabled = true;
    #define sceneTex colortex0
#endif

//Common Variables//
float weight[7] = float[7](1.0, 6.0, 15.0, 20.0, 15.0, 6.0, 1.0);

vec2 view = vec2(viewWidth, viewHeight);

#if MOTION_BLUR_EFFECT == 1 && defined MOTION_BLUR_BLOOM_FOG_FIX
    float SdotU = dot(sunVec, upVec);
    float sunFactor = SdotU < 0.0 ? clamp(SdotU + 0.375, 0.0, 0.75) / 0.75 : clamp(SdotU + 0.03125, 0.0, 0.0625) / 0.0625;
#endif

//Common Functions//
vec3 BloomTile(float lod, vec2 offset, vec2 scaledCoord) {
    vec3 bloom = vec3(0.0);
    float scale = exp2(lod);
    vec2 scaledCoordMinusOffset = scaledCoord - offset;
    vec2 coord = scaledCoordMinusOffset * scale;
    float padding = 0.5 + 0.005 * scale;

    if (abs(coord.x - 0.5) < padding && abs(coord.y - 0.5) < padding) {
        for (int i = -3; i <= 3; i++) {
            for (int j = -3; j <= 3; j++) {
                float wg = weight[i + 3] * weight[j + 3];
                vec2 pixelOffset = vec2(i, j) / view;
                vec2 bloomCoord = (scaledCoordMinusOffset + pixelOffset) * scale;
                bloom += texture2D(sceneTex, bloomCoord).rgb * wg;
            }
        }
        bloom /= 4096.0;
    }

    return pow(bloom / 128.0, vec3(0.25));
}

//Includes//
#if MOTION_BLUR_EFFECT == 1 && !defined TAAU_MOTION_BLUR
    #include "/lib/util/dither.glsl"

    #ifdef MOTION_BLUR_BLOOM_FOG_FIX
        #include "/lib/atmospherics/fog/bloomFog.glsl"
    #endif

    #include "/lib/misc/motionBlur.glsl"
#endif

//Program//
void main() {
    vec3 blur = vec3(0.0);

    #if BLOOM_ENABLED == 1
        vec2 scaledCoord = (RENDER_SCALE_M < 1.0 ? gl_FragCoord.xy / view : texCoord) * max(vec2(viewWidth, viewHeight) / vec2(1920.0, 1080.0), vec2(1.0));

        #if defined OVERWORLD || defined END
            blur += BloomTile(2.0, vec2(0.0      , 0.0   ), scaledCoord);
            blur += BloomTile(3.0, vec2(0.0      , 0.26  ), scaledCoord);
            blur += BloomTile(4.0, vec2(0.135    , 0.26  ), scaledCoord);
            blur += BloomTile(5.0, vec2(0.2075   , 0.26  ), scaledCoord) * 0.8;
            blur += BloomTile(6.0, vec2(0.135    , 0.3325), scaledCoord) * 0.8;
            blur += BloomTile(7.0, vec2(0.160625 , 0.3325), scaledCoord) * 0.6;
            blur += BloomTile(8.0, vec2(0.1784375, 0.3325), scaledCoord) * 0.4;
        #else
            blur += BloomTile(2.0, vec2(0.0      , 0.0   ), scaledCoord);
            blur += BloomTile(3.0, vec2(0.0      , 0.26  ), scaledCoord);
            blur += BloomTile(4.0, vec2(0.135    , 0.26  ), scaledCoord);
            blur += BloomTile(5.0, vec2(0.2075   , 0.26  ), scaledCoord);
            blur += BloomTile(6.0, vec2(0.135    , 0.3325), scaledCoord);
            blur += BloomTile(7.0, vec2(0.160625 , 0.3325), scaledCoord);
            blur += BloomTile(8.0, vec2(0.1784375, 0.3325), scaledCoord) * 0.6;
        #endif
    #endif

    #if MOTION_BLUR_EFFECT == 1 && !defined TAAU_MOTION_BLUR
        vec3 color = texelFetch(colortex0, texelCoord, 0).rgb;
        DoMotionBlur(color);
    #endif

    /* DRAWBUFFERS:3 */
    gl_FragData[0] = vec4(blur, 1.0);

    #if MOTION_BLUR_EFFECT == 1 && !defined TAAU_MOTION_BLUR
        /* DRAWBUFFERS:30 */
        gl_FragData[1] = vec4(color, 1.0);
    #endif
}

#endif

//////////Vertex Shader//////////Vertex Shader//////////Vertex Shader//////////
#ifdef VERTEX_SHADER

noperspective out vec2 texCoord;

#if MOTION_BLUR_EFFECT == 1 && defined MOTION_BLUR_BLOOM_FOG_FIX
    flat out vec3 upVec, sunVec;
#endif

//Attributes//

//Common Variables//

//Common Functions//

//Includes//

//Program//
void main() {
    gl_Position = ftransform();

    texCoord = gl_MultiTexCoord0.xy;

    #if MOTION_BLUR_EFFECT == 1 && defined MOTION_BLUR_BLOOM_FOG_FIX
        upVec = normalize(gbufferModelView[1].xyz);
        sunVec = GetSunVector();
    #endif
}

#endif
