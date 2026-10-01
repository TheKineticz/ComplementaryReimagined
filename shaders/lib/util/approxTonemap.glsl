#ifndef INCLUDE_APPROX_TONEMAP
    #define INCLUDE_APPROX_TONEMAP

    // Lets blurs that run after the tonemap mix colours roughly as they would in HDR, so highlights keep their weight.
    // The two curves are exact inverses on [0, 1]. White maps to about the tonemap's maximum input.
    const float approxTonemapK = 1.45 * TM_EXPOSURE;
    const float approxTonemapWhite = 0.9;

    vec3 UndoTonemapApprox(vec3 color) {
        color *= color;
        return color / (approxTonemapK * (1.0 - approxTonemapWhite * color));
    }

    vec3 RedoTonemapApprox(vec3 color) {
        color *= approxTonemapK;
        return sqrt(color / (1.0 + approxTonemapWhite * color));
    }
#endif
