/////////////////////////////////////
// Complementary Shaders by EminGT //
/////////////////////////////////////

//Common//
#include "/lib/common.glsl"

//////////Fragment Shader//////////Fragment Shader//////////Fragment Shader//////////
#ifdef FRAGMENT_SHADER

noperspective in vec2 texCoord;

#ifdef TAAU_WORLD_BLUR
    flat in vec3 upVec, sunVec;
#endif

//Pipeline Constants//
#ifdef TAAU_WORLD_BLUR
    const bool colortex0MipmapEnabled = true;
#endif

//Common Variables//
#ifdef TAAU_WORLD_BLUR
    float SdotU = dot(sunVec, upVec);
    float sunFactor = SdotU < 0.0 ? clamp(SdotU + 0.375, 0.0, 0.75) / 0.75 : clamp(SdotU + 0.03125, 0.0, 0.0625) / 0.0625;
#endif

//Common Functions//

//Includes//
#ifdef TAAU_WORLD_BLUR
    #include "/lib/misc/worldBlur.glsl"
    #include "/lib/util/approxTonemap.glsl"
#endif

//Program//
void main() {
    #ifdef TAAU_WORLD_BLUR
        // World blur after TAAU, from composite6's linear copy of the upscaled image
        vec3 color = texelFetch(colortex3, texelCoord, 0).rgb;

        vec2 depthUV = ToBufferUV(texCoord);
        float z1 = texture2D(depthtex1, depthUV).r;
        float z0 = texture2D(depthtex0, depthUV).r;

        vec4 screenPos = vec4(texCoord, z0, 1.0);
        vec4 viewPos = gbufferProjectionInverse * (screenPos * 2.0 - 1.0);
        viewPos /= viewPos.w;
        float lViewPos = length(viewPos.xyz);

        #if defined DISTANT_HORIZONS || defined VOXY
            #ifdef DISTANT_HORIZONS
                float z0lod = texture2D(dhDepthTex, LodBufferUV(texCoord)).r;
                vec4 screenPosLod = vec4(texCoord, z0lod, 1.0);
                vec4 viewPosLod = dhProjectionInverse * (screenPosLod * 2.0 - 1.0);
            #elif defined VOXY
                float z0lod = texture2D(vxDepthTexTrans, LodBufferUV(texCoord)).r;
                vec4 screenPosLod = vec4(texCoord, z0lod, 1.0);
                vec4 viewPosLod = vxProjInv * (screenPosLod * 2.0 - 1.0);
            #endif
            viewPosLod /= viewPosLod.w;
            lViewPos = min(lViewPos, length(viewPosLod.xyz));
        #endif

        vec3 dof;
        if (DoWorldBlur(dof, z1, lViewPos)) color = RedoTonemapApprox(dof);

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

#ifdef TAAU_WORLD_BLUR
    flat out vec3 upVec, sunVec;
#endif

//Attributes//

//Common Variables//

//Common Functions//

//Includes//

//Program//
void main() {
    gl_Position = ftransform();

    texCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;

    #ifdef TAAU_WORLD_BLUR
        upVec = normalize(gbufferModelView[1].xyz);
        sunVec = GetSunVector();
    #endif
}

#endif
