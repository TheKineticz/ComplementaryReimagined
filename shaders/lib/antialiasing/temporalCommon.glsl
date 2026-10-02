const float temporalEncodeScale = 1.45 * TM_EXPOSURE;

vec3 TAAEncode(vec3 c) {
    c = max(c * temporalEncodeScale, 0.0);
    return sqrt(c / (1.0 + c));
}

vec3 TAADecode(vec3 c) {
    c *= c;
    return c / (max(1.0 - c, 1e-3) * temporalEncodeScale);
}

vec3 RGBToYCoCg(vec3 c) {
    return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 YCoCgToRGB(vec3 c) {
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

vec4 SampleHistory(vec2 uv, out vec3 localMean, out vec3 localDeviation) {
    vec3 top, left, right, bottom;
    vec4 history, center;
    #if TAA_MOVEMENT_IMPROVEMENT_FILTER == 1
        //Catmull-Rom sampling from Filmic SMAA presentation
        vec2 position = uv * view;
        vec2 centerPosition = floor(position - 0.5) + 0.5;
        vec2 f = position - centerPosition;
        vec2 f2 = f * f;
        vec2 f3 = f * f2;

        float c = 0.7;
        vec2 w0 =        -c  * f3 +  2.0 * c         * f2 - c * f;
        vec2 w1 =  (2.0 - c) * f3 - (3.0 - c)        * f2         + 1.0;
        vec2 w2 = -(2.0 - c) * f3 + (3.0 -  2.0 * c) * f2 + c * f;
        vec2 w3 =         c  * f3 -                c * f2;

        vec2 w12 = w1 + w2;
        vec2 tc12 = (centerPosition + w2 / w12) / view;
        vec2 tc0 = (centerPosition - 1.0) / view;
        vec2 tc3 = (centerPosition + 2.0) / view;
        top = texture2DLod(colortex2, vec2(tc12.x, tc0.y), 0).rgb;
        left = texture2DLod(colortex2, vec2(tc0.x, tc12.y), 0).rgb;
        center = texture2DLod(colortex2, tc12, 0);
        right = texture2DLod(colortex2, vec2(tc3.x, tc12.y), 0).rgb;
        bottom = texture2DLod(colortex2, vec2(tc12.x, tc3.y), 0).rgb;
        vec4 color = vec4(top, 1.0)        * (w12.x * w0.y ) +
                     vec4(left, 1.0)       * (w0.x  * w12.y) +
                     vec4(center.rgb, 1.0) * (w12.x * w12.y) +
                     vec4(right, 1.0)      * (w3.x  * w12.y) +
                     vec4(bottom, 1.0)     * (w12.x * w3.y );
        history = vec4(color.rgb / color.a, center.a);
    #else
        center = texture2DLod(colortex2, uv, 0);
        history = center;
        vec2 offset = 1.5 / view;
        top = texture2DLod(colortex2, uv - vec2(0.0, offset.y), 0).rgb;
        left = texture2DLod(colortex2, uv - vec2(offset.x, 0.0), 0).rgb;
        right = texture2DLod(colortex2, uv + vec2(offset.x, 0.0), 0).rgb;
        bottom = texture2DLod(colortex2, uv + vec2(0.0, offset.y), 0).rgb;
    #endif

    vec3 t0 = RGBToYCoCg(top), t1 = RGBToYCoCg(left), t2 = RGBToYCoCg(center.rgb), t3 = RGBToYCoCg(right);
    vec3 t4 = RGBToYCoCg(bottom);
    localMean = 0.2 * (t0 + t1 + t2 + t3 + t4);
    vec3 squares = 0.2 * (t0 * t0 + t1 * t1 + t2 * t2 + t3 * t3 + t4 * t4);
    localDeviation = sqrt(max(squares - localMean * localMean, 0.0));
    return history;
}

vec3 SampleHistory(vec2 uv) {
    #if TAA_MOVEMENT_IMPROVEMENT_FILTER == 1
        vec3 mean, deviation;
        return SampleHistory(uv, mean, deviation).rgb;
    #else
        return texture2D(colortex2, uv).rgb;
    #endif
}

// Previous frame reprojection from Chocapic13
vec2 Reprojection(vec4 viewPos, mat4 previousProjection) {
    vec4 pos = gbufferModelViewInverse * viewPos;
    vec4 previousPosition = pos + vec4(cameraPosition - previousCameraPosition, 0.0);
    previousPosition = gbufferPreviousModelView * previousPosition;
    previousPosition = previousProjection * previousPosition;
    return previousPosition.xy / previousPosition.w * 0.5 + 0.5;
}

vec2 Reprojection(vec4 viewPos) {
    return Reprojection(viewPos, gbufferPreviousProjection);
}

vec2 Reprojection(vec3 pos, mat4 projectionInverse, mat4 previousProjection) {
    vec4 viewPos = projectionInverse * vec4(pos * 2.0 - 1.0, 1.0);
    return Reprojection(viewPos / viewPos.w, previousProjection);
}

vec3 ClipAABB(vec3 color, vec3 boxMin, vec3 boxMax) {
    vec3 center = 0.5 * (boxMax + boxMin);
    vec3 extent = 0.5 * (boxMax - boxMin) + 0.00000001;
    vec3 offset = color - center;
    vec3 ratio = abs(offset / extent);
    float scale = max(ratio.x, max(ratio.y, ratio.z));
    return scale > 1.0 ? center + offset / scale : color;
}

ivec2 neighbourhoodOffsets[8] = ivec2[8](
    ivec2( 1, 1),
    ivec2( 1,-1),
    ivec2(-1, 1),
    ivec2(-1,-1),
    ivec2( 1, 0),
    ivec2( 0, 1),
    ivec2(-1, 0),
    ivec2( 0,-1)
);
