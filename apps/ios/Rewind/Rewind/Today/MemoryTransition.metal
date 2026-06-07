#include <SwiftUI/SwiftUI.h>
using namespace metal;

[[ stitchable ]]
half4 memoryTransition(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float progress,
    float direction,
    float cornerRadius,
    float edgeWidth
) {
    float2 safeSize = max(size, float2(1.0, 1.0));
    float motionAmount = smoothstep(0.0, 1.0, clamp(progress, 0.0, 1.0));

    float radius = max(cornerRadius, 1.0);
    float2 halfSize = safeSize * 0.5;
    float2 roundedRectHalfSize = max(halfSize - radius, float2(1.0, 1.0));
    float2 roundedPosition = abs(position - halfSize) - roundedRectHalfSize;
    float signedDistance = length(max(roundedPosition, float2(0.0, 0.0)))
        + min(max(roundedPosition.x, roundedPosition.y), 0.0)
        - radius;
    float distanceInsideAperture = max(-signedDistance, 0.0);
    float edgeAmount = 1.0 - smoothstep(0.0, max(edgeWidth, 1.0), distanceInsideAperture);
    edgeAmount = smoothstep(0.0, 1.0, clamp(edgeAmount, 0.0, 1.0));

    float2 sampleMin = float2(0.5, 0.5);
    float2 sampleMax = safeSize - sampleMin;
    float2 normalizedPosition = position / safeSize;
    float2 center = safeSize * 0.5;
    float2 radialVector = position - center;
    float contentScale = mix(0.982, 0.958, motionAmount);
    float2 sampleVector = radialVector / contentScale;

    float2 centeredUV = normalizedPosition - 0.5;
    float screenDistance = length(centeredUV);
    float distanceToEdge = min(
        min(normalizedPosition.x, 1.0 - normalizedPosition.x),
        min(normalizedPosition.y, 1.0 - normalizedPosition.y)
    );
    float edgeBand = 1.0 - smoothstep(0.0, 0.20, distanceToEdge);
    float outerEdgeBoost = mix(0.70, 0.82, pow(clamp(edgeBand, 0.0, 1.0), 2.0));
    float outerField = pow(clamp(edgeBand, 0.0, 1.0), 0.52) * outerEdgeBoost;
    float edgeMotion = outerField * motionAmount;

    float2 angleUV = centeredUV;
    angleUV.x *= safeSize.x / safeSize.y;
    float rayAngle = atan2(angleUV.y, angleUV.x);
    float travelDirection = direction < 0.0 ? -1.0 : 1.0;
    float rayPhase = progress * travelDirection;
    float broadRay = sin(rayAngle * 13.0 - rayPhase * 5.0) * 0.5 + 0.5;
    float fineRay = sin(rayAngle * 29.0 + screenDistance * 18.0 + rayPhase * 7.0) * 0.5 + 0.5;
    float rayPattern = pow(broadRay, 7.0) * 0.70 + pow(fineRay, 10.0) * 0.30;
    float rayMask = rayPattern * edgeMotion;

    half4 baseColor = layer.sample(clamp(center + sampleVector, sampleMin, sampleMax));

    float zoomReach = (0.46 + 1.06 * motionAmount) * outerField;

    // Zoom burst: long-exposure samples are pulled along the ray between image center and the pixel.
    half4 zoomBlur = baseColor * half(0.018);
    float zoomWeight = 0.018;
    for (int sampleIndex = 0; sampleIndex < 56; sampleIndex += 1) {
        float sampleProgress = float(sampleIndex + 1) / 56.0;
        float depth = pow(sampleProgress, 0.72);
        float2 samplePosition = center + sampleVector * (1.0 - zoomReach * depth);
        half4 sampleColor = layer.sample(clamp(samplePosition, sampleMin, sampleMax));
        float sampleLuma = float(dot(sampleColor.rgb, half3(0.2126, 0.7152, 0.0722)));
        float highlightWeight = mix(0.86, 1.42, smoothstep(0.22, 0.88, sampleLuma));
        float weight = mix(1.08, 0.10, sampleProgress) * highlightWeight;
        zoomBlur += sampleColor * half(weight);
        zoomWeight += weight;
    }
    zoomBlur /= half(zoomWeight);

    half4 glassColor = zoomBlur;
    half4 gradientBlur = baseColor * half(0.04);
    float gradientWeight = 0.04;
    for (int sampleIndex = 0; sampleIndex < 24; sampleIndex += 1) {
        float sampleProgress = float(sampleIndex + 1) / 24.0;
        float depth = pow(sampleProgress, 0.58);
        float2 samplePosition = center + sampleVector * (1.0 - zoomReach * depth * 1.48);
        float weight = mix(0.78, 0.10, sampleProgress);
        gradientBlur += layer.sample(clamp(samplePosition, sampleMin, sampleMax)) * half(weight);
        gradientWeight += weight;
    }
    gradientBlur /= half(gradientWeight);
    glassColor = mix(glassColor, gradientBlur, half(clamp(edgeMotion * 0.48, 0.0, 0.48)));

    float blurMix = clamp(edgeMotion * (1.58 + motionAmount * 0.34), 0.0, 1.0);
    half4 mixedColor = mix(baseColor, glassColor, half(blurMix));
    half rayShine = half(rayMask * (0.22 + motionAmount * 0.16) * (0.45 + edgeAmount * 0.55));
    half3 shineColor = min(mixedColor.rgb + half3(0.22, 0.24, 0.30), half3(1.0));
    return half4(mix(mixedColor.rgb, shineColor, rayShine), mixedColor.a);
}
