// Keep HDR history in a compact range for temporal blending and neighbourhood clamping.
// Decode the resolved scene back to HDR before depth of field, motion blur and tonemapping.
const float temporalEncodeScale = 1.45 * TM_EXPOSURE;

vec3 TAAEncode(vec3 c) {
    c = max(c * temporalEncodeScale, 0.0);
    return sqrt(c / (1.0 + c));
}

vec3 TAADecode(vec3 c) {
    c *= c;
    return c / (max(1.0 - c, 1e-3) * temporalEncodeScale);
}
