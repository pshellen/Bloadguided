precision lowp float;

varying vec2 TexCoord;

uniform sampler2D Tex0;
uniform vec2 size;
uniform float radius;
uniform float border;
uniform vec4 borderColor;
uniform float time;

float roundedBoxSDF(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) - r;
}

// branchless perimeter coordinate approximation
float perimeterCoord(vec2 p, vec2 b) {
    vec2 a = abs(p);

    vec2 ratio = a / b;

    // weights for vertical vs horizontal dominance
    float h = step(ratio.x, ratio.y);
    float v = 1.0 - h;

    // horizontal contribution (top/bottom)
    float x = (p.x / (2.0 * b.x)) * 0.25;

    // vertical contribution (left/right)
    float y = (p.y / (2.0 * b.y)) * 0.25;

    float sideH = (p.y > 0.0 ? 0.0 + x : 1.5 - x);
    // float sideV = (p.x > 0.0 ? 0.25 : 0.75) + y;
    float sideV = (p.x > 0.0 ? 0.25 - y : 0.75 + y);

    return sideH * h + sideV * v;
}

void main() {
    vec2 uv = TexCoord;
    vec2 px = uv * size;

    vec2 center = px - size * 0.5;
    vec2 halfSize = size * 0.5;

    float outerDist = roundedBoxSDF(center, halfSize, radius);
    float innerDist = roundedBoxSDF(center, halfSize - vec2(border), radius - border);

    float aa = 1.0;

    float outerMask = 1.0 - smoothstep(0.0, aa, outerDist);
    float innerMask = 1.0 - smoothstep(0.0, aa, innerDist);
    float borderMask = clamp(outerMask - innerMask, 0.0, 1.0);

    float p = perimeterCoord(center, halfSize);
    float d = abs(fract(p - time + 0.5) - 0.5);

    float glowWidth = 0.25;

    float glow = smoothstep(glowWidth, 0.0, d);
    glow = pow(glow, 2.5) * borderMask;

    vec4 img = texture2D(Tex0, uv);
    vec3 finalBorder = borderColor.rgb + glow * 0.5;

    vec4 color = img * innerMask + vec4(finalBorder, 1.0) * borderMask;

    color.a = outerMask;

    gl_FragColor = color;
}
