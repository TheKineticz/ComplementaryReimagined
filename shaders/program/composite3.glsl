/////////////////////////////////////
// Complementary Shaders by EminGT //
/////////////////////////////////////

//Common//
#include "/lib/common.glsl"

// Copy scaled HDR to a matching bloom buffer so mipmaps stay inside the rendered area
#ifdef FRAGMENT_SHADER
void main() {
    vec3 color = texelFetch(colortex0, texelCoord, 0).rgb;
    /* RENDERTARGETS:11 */
    gl_FragData[0] = vec4(color, 1.0);
}
#endif

#ifdef VERTEX_SHADER
void main() {
    gl_Position = ftransform();
}
#endif
