#include <metal_stdlib>
using namespace metal;

struct IdleScreenCharacterVertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
    float brightness;
    float4 foreground;
};

struct IdleScreenCharacterInstance {
    float4 gridBrightnessGlyph;
    float4 foreground;
};

struct IdleScreenCameraUniforms {
    uint2 gridSize;
    uint2 cameraSize;
    float contrast;
    uint glyphCount;
    uint mirrored;
    uint usesCameraColor;
    float4 paletteForeground;
};

struct IdleScreenPixelMaterialsUniforms {
    uint2 gridSize;
    uint2 worldSize;
    float4 viewport;
    uint glyphCount;
    float sceneBrightness;
    float4 rockColor;
    float4 soilColor;
    float4 sandColor;
    float4 waterColor;
};

kernel void idleScreenCameraInstances(
    const device uchar *luminance [[buffer(0)]],
    const device uchar *interleavedRGB [[buffer(1)]],
    device IdleScreenCharacterInstance *instances [[buffer(2)]],
    constant IdleScreenCameraUniforms &uniforms [[buffer(3)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= uniforms.gridSize.x
        || position.y >= uniforms.gridSize.y
        || uniforms.cameraSize.x == 0
        || uniforms.cameraSize.y == 0
        || uniforms.glyphCount == 0) {
        return;
    }

    uint sourceX = min(
        uniforms.cameraSize.x - 1,
        position.x * uniforms.cameraSize.x / uniforms.gridSize.x
    );
    if (uniforms.mirrored != 0) {
        sourceX = uniforms.cameraSize.x - 1 - sourceX;
    }
    const uint sourceY = min(
        uniforms.cameraSize.y - 1,
        position.y * uniforms.cameraSize.y / uniforms.gridSize.y
    );
    const uint sampleIndex = sourceY * uniforms.cameraSize.x + sourceX;
    float brightness = float(luminance[sampleIndex]) / 255.0;
    brightness = clamp(
        (brightness - 0.5) * uniforms.contrast + 0.5,
        0.0,
        1.0
    );
    const uint glyphIndex = min(
        uniforms.glyphCount - 1,
        uint(brightness * float(uniforms.glyphCount))
    );
    const uint rgbIndex = sampleIndex * 3;
    const float4 cameraForeground = float4(
        float(interleavedRGB[rgbIndex]) / 255.0,
        float(interleavedRGB[rgbIndex + 1]) / 255.0,
        float(interleavedRGB[rgbIndex + 2]) / 255.0,
        1.0
    );
    const uint instanceIndex = position.y * uniforms.gridSize.x + position.x;
    instances[instanceIndex].gridBrightnessGlyph = float4(
        float(position.x),
        float(position.y),
        brightness,
        float(glyphIndex)
    );
    instances[instanceIndex].foreground = uniforms.usesCameraColor != 0
        ? cameraForeground
        : uniforms.paletteForeground;
}

kernel void idleScreenPixelMaterialInstances(
    const device uint *state [[buffer(0)]],
    device IdleScreenCharacterInstance *instances [[buffer(1)]],
    constant IdleScreenPixelMaterialsUniforms &uniforms [[buffer(2)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= uniforms.gridSize.x
        || position.y >= uniforms.gridSize.y
        || uniforms.worldSize.x == 0
        || uniforms.worldSize.y == 0
        || uniforms.glyphCount == 0) {
        return;
    }
    const float localU = (float(position.x) + 0.5)
        / float(uniforms.gridSize.x);
    const float localTopV = (float(position.y) + 0.5)
        / float(uniforms.gridSize.y);
    const float worldU = uniforms.viewport.x
        + localU * uniforms.viewport.z;
    const float worldTopV = 1.0 - uniforms.viewport.y
        - uniforms.viewport.w + localTopV * uniforms.viewport.w;
    const uint sourceX = min(
        uniforms.worldSize.x - 1,
        uint(clamp(worldU, 0.0, 0.999999) * float(uniforms.worldSize.x))
    );
    const uint sourceY = min(
        uniforms.worldSize.y - 1,
        uint(clamp(worldTopV, 0.0, 0.999999) * float(uniforms.worldSize.y))
    );
    const uint encoded = state[sourceY * uniforms.worldSize.x + sourceX];
    const uint terrain = encoded & 0xff;
    const uint sand = (encoded >> 8) & 0xff;
    const uint water = (encoded >> 16) & 0xff;

    float brightness = 0.0;
    uint glyphIndex = 0;
    float4 foreground = uniforms.soilColor;
    if (water > 0) {
        brightness = 0.55 + 0.45 * min(1.0, float(water) / 8.0);
        glyphIndex = min(uniforms.glyphCount - 1, 6u);
        foreground = uniforms.waterColor;
    } else if (sand > 0) {
        brightness = 0.92;
        glyphIndex = min(uniforms.glyphCount - 1, 8u);
        foreground = uniforms.sandColor;
    } else if (terrain == 2) {
        brightness = 0.58;
        glyphIndex = min(uniforms.glyphCount - 1, 8u);
        foreground = uniforms.rockColor;
    } else if (terrain == 1) {
        brightness = 0.68;
        glyphIndex = min(uniforms.glyphCount - 1, 7u);
        foreground = uniforms.soilColor;
    }
    brightness *= uniforms.sceneBrightness;
    foreground.rgb *= uniforms.sceneBrightness;
    const uint instanceIndex = position.y * uniforms.gridSize.x + position.x;
    instances[instanceIndex].gridBrightnessGlyph = float4(
        float(position.x),
        float(position.y),
        brightness,
        float(glyphIndex)
    );
    instances[instanceIndex].foreground = foreground;
}

vertex IdleScreenCharacterVertexOut idleScreenCharacterVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant float4 &geometry [[buffer(0)]],
    constant IdleScreenCharacterInstance *instances [[buffer(1)]],
    constant float4 *glyphRects [[buffer(2)]]
) {
    const float2 vertices[6] = {
        float2(0, 0),
        float2(1, 0),
        float2(0, 1),
        float2(0, 1),
        float2(1, 0),
        float2(1, 1),
    };

    const IdleScreenCharacterInstance instance = instances[instanceID];
    const float4 gridBrightnessGlyph = instance.gridBrightnessGlyph;
    const float2 quadVertex = vertices[vertexID];
    const uint glyphIndex = uint(gridBrightnessGlyph.w + 0.5);
    const float4 glyphRect = glyphRects[glyphIndex];

    const float2 gridPosition = gridBrightnessGlyph.xy + quadVertex;
    const float ndcX = gridPosition.x * geometry.z * 2.0 - 1.0;
    const float ndcY = 1.0 - gridPosition.y * geometry.w * 2.0;

    IdleScreenCharacterVertexOut output;
    output.position = float4(ndcX, ndcY, 0, 1);
    output.textureCoordinate = glyphRect.xy + quadVertex * glyphRect.zw;
    output.brightness = gridBrightnessGlyph.z;
    output.foreground = instance.foreground;
    return output;
}

fragment float4 idleScreenCharacterFragment(
    IdleScreenCharacterVertexOut input [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler atlasSampler(filter::linear, address::clamp_to_edge);
    const float alpha = atlas.sample(atlasSampler, input.textureCoordinate).a;
    const float intensity = mix(0.12, 1.0, input.brightness);
    return float4(input.foreground.rgb * intensity, alpha * input.brightness);
}
