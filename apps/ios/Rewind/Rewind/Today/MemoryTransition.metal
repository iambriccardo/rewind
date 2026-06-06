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
    edgeAmount = pow(clamp(edgeAmount, 0.0, 1.0), 0.72);

    float2 sampleMin = float2(0.5, 0.5);
    float2 sampleMax = safeSize - sampleMin;
    float2 normalizedPosition = position / safeSize;
    float2 centeredPosition = normalizedPosition - 0.5;
    float2 edgeDirection = normalize(centeredPosition + float2(0.0001, 0.0001));
    float rightSideEmphasis = smoothstep(0.52, 1.0, normalizedPosition.x);

    float edgeMotion = edgeAmount * motionAmount;
    half4 baseColor = layer.sample(position);

    float lineDistance = (36.0 + 92.0 * motionAmount) * (1.0 + rightSideEmphasis * 0.18) * pow(edgeAmount, 0.68);
    float2 outwardLineVector = edgeDirection * lineDistance;

    half4 outwardLines = layer.sample(clamp(position - outwardLineVector * 0.18, sampleMin, sampleMax)) * half(0.24)
        + layer.sample(clamp(position - outwardLineVector * 0.36, sampleMin, sampleMax)) * half(0.22)
        + layer.sample(clamp(position - outwardLineVector * 0.58, sampleMin, sampleMax)) * half(0.19)
        + layer.sample(clamp(position - outwardLineVector * 0.84, sampleMin, sampleMax)) * half(0.15)
        + layer.sample(clamp(position - outwardLineVector * 1.12, sampleMin, sampleMax)) * half(0.11)
        + layer.sample(clamp(position - outwardLineVector * 1.44, sampleMin, sampleMax)) * half(0.09);

    half4 insetEcho = layer.sample(clamp(position - edgeDirection * edgeWidth * 0.16, sampleMin, sampleMax)) * half(0.34)
        + layer.sample(clamp(position - edgeDirection * edgeWidth * 0.34, sampleMin, sampleMax)) * half(0.28)
        + layer.sample(clamp(position - edgeDirection * edgeWidth * 0.58, sampleMin, sampleMax)) * half(0.22)
        + layer.sample(clamp(position - edgeDirection * edgeWidth * 0.86, sampleMin, sampleMax)) * half(0.16);

    half4 glassColor = mix(insetEcho, outwardLines, half(0.56 + motionAmount * 0.28));
    float lineMix = clamp(edgeMotion * (0.42 + motionAmount * 0.36), 0.0, 0.70);
    half4 mixedColor = mix(baseColor, glassColor, half(lineMix));

    half luma = dot(mixedColor.rgb, half3(0.2126, 0.7152, 0.0722));
    half desaturateAmount = half(edgeMotion * 0.20);
    half3 frostedColor = mix(mixedColor.rgb, half3(luma), desaturateAmount);
    half veil = half(edgeMotion * 0.12);
    half rimShade = half(edgeAmount * motionAmount * 0.08);
    half3 finalColor = mix(frostedColor, half3(1.0), veil) * (half(1.0) - rimShade);

    return half4(finalColor, mixedColor.a);
}
