#ifndef INCLUDE_DFDX_DFDY
    #define INCLUDE_DFDX_DFDY

    // Explicit material gradients use the same mip bias as texture2DMaterial.
    vec2 dcdx = dFdx(texCoord.xy) * RENDER_SCALE_M;
    vec2 dcdy = dFdy(texCoord.xy) * RENDER_SCALE_M;
#endif
