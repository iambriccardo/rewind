#include <SwiftUI/SwiftUI.h>
using namespace metal;

static float wearableSnapshotHash(float2 value) {
    return fract(sin(dot(value, float2(127.1, 311.7))) * 43758.5453);
}

static float wearableSnapshotLuma(half3 color) {
    return float(dot(color, half3(0.2126, 0.7152, 0.0722)));
}

static float wearableSnapshotValueNoise(float2 value) {
    float2 cell = floor(value);
    float2 local = fract(value);
    float2 smoothLocal = local * local * (3.0 - 2.0 * local);

    float bottomLeft = wearableSnapshotHash(cell);
    float bottomRight = wearableSnapshotHash(cell + float2(1.0, 0.0));
    float topLeft = wearableSnapshotHash(cell + float2(0.0, 1.0));
    float topRight = wearableSnapshotHash(cell + float2(1.0, 1.0));

    float bottom = mix(bottomLeft, bottomRight, smoothLocal.x);
    float top = mix(topLeft, topRight, smoothLocal.x);
    return mix(bottom, top, smoothLocal.y);
}

static float wearableSnapshotOrganicNoise(float2 value) {
    float noise = wearableSnapshotValueNoise(value) * 0.52;
    noise += wearableSnapshotValueNoise(value * 2.03 + 17.0) * 0.28;
    noise += wearableSnapshotValueNoise(value * 4.11 + 41.0) * 0.14;
    noise += wearableSnapshotValueNoise(value * 8.23 + 83.0) * 0.06;
    return noise;
}

[[ stitchable ]]
half4 wearableSnapshotCapture(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float progress
) {
    float2 safeSize = max(size, float2(1.0, 1.0));
    float2 sampleMin = float2(0.5, 0.5);
    float2 sampleMax = safeSize - sampleMin;
    float p = clamp(progress, 0.0, 1.0);

    half4 base = layer.sample(clamp(position, sampleMin, sampleMax));
    float baseLuma = wearableSnapshotLuma(base.rgb);

    float2 uv = position / safeSize;

    float morphEnvelope = pow(sin(p * 3.14159), 0.62);
    float waveProgress = smoothstep(0.0, 1.0, p);
    float organicField = wearableSnapshotOrganicNoise(uv * float2(3.0, 5.8) + float2(0.0, p * 1.45));
    float fineOrganicField = wearableSnapshotOrganicNoise(uv * float2(9.0, 15.0) + float2(p * 1.8, -p * 1.1));
    float waveBend = (organicField - 0.5) * 0.18
        + sin(uv.x * 8.6 + p * 4.1) * 0.035
        + sin(uv.x * 19.0 - p * 5.6 + organicField * 4.0) * 0.018;
    float scanY = 1.08 - waveProgress * 1.18 + waveBend;

    // Image segmentation: each cell receives a stable phase and speed, while
    // the sampled cell luma controls how strongly that segment reacts.
    float2 cellCount = float2(22.0, 40.0);
    float2 cell = floor(uv * cellCount);
    float2 cellCenter = (cell + 0.5) / cellCount * safeSize;
    half4 cellColor = layer.sample(clamp(cellCenter, sampleMin, sampleMax));
    float cellLuma = wearableSnapshotLuma(cellColor.rgb);
    float segmentNoise = wearableSnapshotHash(cell);
    float cellY = (cell.y + 0.5) / cellCount.y;
    float cellOrganic = wearableSnapshotOrganicNoise((cell + 0.5) * 0.42 + float2(p * 0.7, p * 1.1));
    float cellScanY = scanY + (cellOrganic - 0.5) * 0.07;
    float scanDistance = cellY - cellScanY;
    float cellScanWindow = exp(-scanDistance * scanDistance * 190.0);
    float cellMemory = smoothstep(-0.12, 0.18, scanY - cellY) * (1.0 - smoothstep(0.30, 0.80, scanY - cellY));
    float segmentSpeed = mix(0.58, 1.64, segmentNoise) * mix(0.86, 1.30, cellLuma);
    float segmentPhase = p * segmentSpeed + segmentNoise * 1.37 + cellLuma * 0.72;
    float segmentPulse = 0.5 + 0.5 * sin(segmentPhase * 6.28318);
    float segmentAmount = (cellScanWindow * 1.18 + cellMemory * 0.52) * morphEnvelope
        * mix(0.48, 1.44, cellLuma)
        * mix(0.70, 1.24, segmentPulse);

    float2 segmentVector = normalize(position - cellCenter + float2(0.001, 0.001));

    float pixelScanDistance = uv.y - scanY;
    float scanBand = exp(-pixelScanDistance * pixelScanDistance * 155.0) * morphEnvelope;
    float scanShelf = smoothstep(-0.18, 0.04, -pixelScanDistance) * (1.0 - smoothstep(0.30, 0.72, -pixelScanDistance));
    float scanTexture = 0.55
        + 0.22 * sin(position.x * 0.035 + p * 9.0 + organicField * 4.0)
        + 0.18 * sin(position.x * 0.088 + cellLuma * 8.0 + fineOrganicField * 5.0)
        + 0.20 * fineOrganicField;
    float understandingMask = max(scanBand * scanTexture, segmentAmount * 0.72);

    float edgeProbe = abs(cellColor.r - cellColor.g) + abs(cellColor.g - cellColor.b) + abs(cellColor.b - cellColor.r);
    float localContrast = clamp(edgeProbe * 2.2 + abs(cellLuma - baseLuma) * 1.6, 0.0, 1.0);
    float organicBlob = smoothstep(0.42, 0.86, organicField + localContrast * 0.16);
    float objectAttention = understandingMask * mix(0.52, 1.72, localContrast) * mix(0.78, 1.22, organicBlob);

    float ripple = sin(pixelScanDistance * 42.0 - p * 10.0 + organicField * 6.28318);
    float trailingRipple = sin((uv.x * 16.0 + uv.y * 10.0) - p * 8.0 + cellLuma * 5.0 + fineOrganicField * 4.0);
    float broadWave = sin((uv.x + organicField * 0.55) * 7.0 + p * 4.4);
    float morph = (scanBand * 15.0 + objectAttention * (ripple * 5.2 + trailingRipple * 2.2 + broadWave * 2.4)) * (0.42 + baseLuma * 0.86);
    float waveSlope = cos(uv.x * 8.6 + p * 4.1) * 0.30 + (fineOrganicField - 0.5) * 0.72;
    float2 waveNormal = normalize(float2(waveSlope, -1.0));
    float2 morphOffset = waveNormal * morph * 0.72 + segmentVector * morph * 0.55;

    float chromaRadius = (1.0 + 13.0 * scanBand + 8.5 * objectAttention + 3.0 * organicBlob) * morphEnvelope;
    float2 chromaDirection = normalize(waveNormal * 0.72 + segmentVector * 0.62 + float2((fineOrganicField - 0.5) * 0.45, 0.0) + float2(0.001, 0.001));
    float2 redPosition = position + morphOffset + chromaDirection * chromaRadius;
    float2 greenPosition = position + morphOffset * 0.28 - segmentVector * chromaRadius * 0.22;
    float2 bluePosition = position + morphOffset - chromaDirection * chromaRadius * 0.78;

    half4 redSample = layer.sample(clamp(redPosition, sampleMin, sampleMax));
    half4 greenSample = layer.sample(clamp(greenPosition, sampleMin, sampleMax));
    half4 blueSample = layer.sample(clamp(bluePosition, sampleMin, sampleMax));
    half3 channelSplit = half3(redSample.r, greenSample.g, blueSample.b);

    half4 blurred = base * half(0.36);
    blurred += layer.sample(clamp(position + float2(chromaRadius, 0.0), sampleMin, sampleMax)) * half(0.16);
    blurred += layer.sample(clamp(position - float2(chromaRadius, 0.0), sampleMin, sampleMax)) * half(0.16);
    blurred += layer.sample(clamp(position + float2(0.0, chromaRadius), sampleMin, sampleMax)) * half(0.16);
    blurred += layer.sample(clamp(position - float2(0.0, chromaRadius), sampleMin, sampleMax)) * half(0.16);

    float edgeGlow = max(scanBand, objectAttention * 0.66);
    half3 imageGlow = max(max(redSample.rgb, greenSample.rgb), max(blueSample.rgb, cellColor.rgb));
    half3 sourceReactiveGlow = imageGlow * half(0.16 + 0.72 * edgeGlow + 0.30 * cellLuma);
    half3 brightened = base.rgb * half(1.0 + scanShelf * 0.10 + edgeGlow * 0.30 + objectAttention * 0.12);
    half3 morphed = mix(blurred.rgb, channelSplit, half(clamp(0.40 + edgeGlow * 0.48, 0.0, 0.88)));
    half3 color = mix(brightened, morphed + sourceReactiveGlow, half(clamp(edgeGlow * 0.78, 0.0, 0.78)));

    float scanLine = exp(-pixelScanDistance * pixelScanDistance * 1500.0) * morphEnvelope;
    color += half3(max(baseLuma, cellLuma)) * half(scanLine * 0.24 + objectAttention * 0.10);

    return half4(min(color, half3(1.46)), base.a);
}
