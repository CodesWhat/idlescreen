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

struct IdleScreenProceduralUniforms {
    uint2 gridSize;
    uint2 sceneSize;
    uint2 sceneOrigin;
    uint patternIndex;
    uint glyphCount;
    float timestamp;
    float contrast;
    float sceneBrightness;
    float speed;
    float scale;
    float intensity;
    float trailing;
    float matrixTrailLength;
    float rainbowAmplitude;
    float fireDecay;
    float4 foreground;
};

static float gpuHash2D(float x, float y) {
    const float scaledX = isfinite(x) ? round(x * 4096.0) : 0.0;
    const float scaledY = isfinite(y) ? round(y * 4096.0) : 0.0;
    const uint quantizedX = as_type<uint>(int(clamp(
        isfinite(scaledX) ? scaledX : copysign(2147483520.0, x),
        -2147483520.0,
        2147483520.0
    )));
    const uint quantizedY = as_type<uint>(int(clamp(
        isfinite(scaledY) ? scaledY : copysign(2147483520.0, y),
        -2147483520.0,
        2147483520.0
    )));
    uint hash = quantizedX * 0x9E3779B1u;
    hash ^= quantizedY * 0x85EBCA77u;
    hash ^= hash >> 16;
    hash *= 0x7FEB352Du;
    hash ^= hash >> 15;
    hash *= 0x846CA68Bu;
    hash ^= hash >> 16;
    return float(hash & 0x00FFFFFFu) / 16777216.0;
}

/// Smoother step interpolation (5th degree polynomial)
static float gpuSmootherStep(float x) {
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

/// 2D smooth noise using hash-based approach
static float gpuSmoothNoise2D(float x, float y) {
    float xi = floor(x);
    float yi = floor(y);
    float xf = x - xi;
    float yf = y - yi;

    float n00 = gpuHash2D(xi, yi);
    float n10 = gpuHash2D(xi + 1.0, yi);
    float n01 = gpuHash2D(xi, yi + 1.0);
    float n11 = gpuHash2D(xi + 1.0, yi + 1.0);

    float xSmooth = gpuSmootherStep(xf);
    float ySmooth = gpuSmootherStep(yf);

    float nx0 = mix(n00, n10, xSmooth);
    float nx1 = mix(n01, n11, xSmooth);
    return mix(nx0, nx1, ySmooth);
}

/// GPU smoothstep helper
static float gpuSmoothstep(float edge0, float edge1, float x) {
    float t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Generate pattern (characterIndex, brightness) for a grid cell on GPU.
/// patternIndex: 0=perlin, 1=plasma, 2=sweep, 3=matrixRain, 4=rainbowCycle, 5=fireEffect,
///               6=ripple, 7=voronoi, 8=warp, 9=staticNoise, 10=pulse, 11=dvdBounce
static float2 generatePattern(uint col, uint row, uint columns, uint rows,
                               uint patternIndex, float timestamp, uint characterCount,
                               constant IdleScreenProceduralUniforms &params) {
    float brightness = 0.0;

    // Normalize grid position to [0,1] so patterns look the same at any grid size
    float u = float(col) / float(columns);
    float v = float(row) / float(rows);

    float speed = params.speed;
    float scale = params.scale;
    float effectiveIntensity = params.intensity;

    if (patternIndex == 0) {
        // Perlin noise: intensity controls octave count, trailing controls contrast
        int octaves = min(1 + int(effectiveIntensity * 3.0), 4); // 1-4 octaves
        float contrast = 0.5 + params.trailing * 1.5;  // 0.5-2.0
        float x = u * (10.0 * scale) + timestamp * (0.3 * speed);
        float y = v * (10.0 * scale) + timestamp * (0.3 * speed);
        float noise = 0.0;
        float amp = 1.0;
        float freq = 1.0;
        float totalAmp = 0.0;
        for (int o = 0; o < octaves; o++) {
            noise += amp * gpuSmoothNoise2D(x * freq, y * freq);
            totalAmp += amp;
            amp *= 0.5;
            freq *= 2.0;
        }
        noise /= totalAmp;
        // Apply contrast curve
        brightness = clamp(pow(noise, 1.0 / contrast), 0.0, 1.0);
    } else if (patternIndex == 1) {
        // Plasma: intensity controls wave count, trailing controls amplitude
        int waveCount = min(3 + int(effectiveIntensity * 5.0), 8); // 3-8 waves
        float amplitude = 0.3 + params.trailing * 0.7;    // 0.3-1.0
        float x = u * (10.0 * scale);
        float y = v * (10.0 * scale);
        float t = timestamp * speed;
        float sum = 0.0;
        for (int w = 0; w < waveCount; w++) {
            float wx = sin(x * (1.0 + float(w) * 0.3) + t * (1.0 + float(w) * 0.2));
            float wy = sin(y * (1.0 + float(w) * 0.2) + t * (1.3 + float(w) * 0.15));
            float wxy = sin((x + y) * (0.7 + float(w) * 0.1) + t * (0.7 + float(w) * 0.3));
            sum += (wx + wy + wxy) * amplitude;
        }
        brightness = clamp(sum / float(waveCount * 3) * 0.5 + 0.5, 0.0, 1.0);
    } else if (patternIndex == 2) {
        // Diagonal sweep: intensity controls band count, trailing controls softness
        int bandCount = min(1 + int(effectiveIntensity * 5.0), 6); // 1-6 bands
        float softness = 0.1 + params.trailing * 0.9;    // 0.1-1.0 (hard to soft)
        float diagonal = (u + v) * (float(bandCount) * scale) + timestamp * (0.2 * speed);
        float sweep = fmod(diagonal, 1.0);
        if (sweep < 0.0) sweep += 1.0;
        brightness = gpuSmoothstep(0.0, softness, sweep);
    } else if (patternIndex == 3) {
        // Matrix rain: intensity controls drops per column
        float trailLength = 2.0 + params.matrixTrailLength * 18.0;
        int dropCount = min(1 + int(effectiveIntensity * 5.0), 6); // 1-6 drops
        float colSeed = float(col);
        float rowF = float(row);
        float totalHeight = float(rows) + trailLength;
        brightness = 0.0;

        for (int drop = 0; drop < dropCount; drop++) {
            float dropSeed = colSeed * 1.71 + float(drop) * 13.37;
            float dropSpeed = 0.3 + gpuHash2D(dropSeed, 0.0) * 1.2;
            dropSpeed *= speed;
            float dropOffset = gpuHash2D(dropSeed * 2.93, 1.0 + float(drop)) * totalHeight;
            float headPos = fmod(timestamp * dropSpeed + dropOffset, totalHeight);
            float dist = headPos - rowF;
            if (dist < 0) dist += totalHeight;
            if (dist <= trailLength) {
                float t = dist / trailLength;
                float dropBright = exp(-3.0 * t);
                brightness = max(brightness, dropBright);
            }
        }
    } else if (patternIndex == 4) {
        // Rainbow cycle: intensity controls wave layers, trailing boosts contrast
        float amplitude = 0.05 + params.rainbowAmplitude * 0.45;
        int layers = min(1 + int(effectiveIntensity * 3.0), 4); // 1-4 layers
        float contrastBoost = 0.5 + params.trailing * 1.5;
        float sum = 0.0;
        for (int l = 0; l < layers; l++) {
            float freq = 1.0 + float(l) * 0.7;
            float phase = float(l) * 0.5;
            float hue = fmod((u + v) * scale * freq + timestamp * (0.3 * speed) + phase, 1.0);
            sum += 0.5 + amplitude * sin(hue * 2.0 * M_PI_F);
        }
        brightness = clamp(pow(sum / float(layers), contrastBoost), 0.0, 1.0);
    } else if (patternIndex == 5) {
        // Fire effect: intensity controls turbulence, trailing controls spread width
        // Decay mapped to give visible flames: 0.92-0.995
        float decay = 0.92 + params.fireDecay * 0.075;
        float turbulence = 0.5 + effectiveIntensity * 1.5;
        float spreadWidth = 10.0 + params.trailing * 30.0;
        // Multiple noise octaves for richer flame shape
        float baseHeat = gpuSmoothNoise2D(u * (spreadWidth * scale) + timestamp * (2.0 * speed), 0.0);
        float turb1 = gpuSmoothNoise2D(u * (spreadWidth * 2.0 * scale) + timestamp * (3.0 * speed),
                                        v * 5.0 + timestamp * speed);
        float turb2 = gpuSmoothNoise2D(u * (spreadWidth * 3.0 * scale) + timestamp * (4.0 * speed) + 7.0,
                                        v * 8.0 - timestamp * speed * 0.5);
        float combinedHeat = clamp(baseHeat * 0.5 + turb1 * 0.3 * turbulence + turb2 * 0.2 * turbulence, 0.0, 1.0);
        // Boost base heat so flames are actually bright
        float boostedHeat = 0.4 + combinedHeat * 0.6;
        float rowFromBottom = float(rows - 1 - row);
        float heat = boostedHeat * pow(decay, rowFromBottom);
        // Apply S-curve to spread values across the full gradient range
        heat = heat * heat * (3.0 - 2.0 * heat);
        float jitterRange = 0.05 + turbulence * 0.15;
        float jitter = (1.0 - jitterRange) + jitterRange * gpuHash2D(float(col) * 7.13, float(row) * 11.37 + timestamp * (3.0 * speed));
        heat *= jitter;
        brightness = clamp(heat, 0.0, 1.0);
    } else if (patternIndex == 6) {
        // Ripple: concentric rings from variable random wave sources with interference
        int sourceCount = min(2 + int(effectiveIntensity * 6.0), 8); // 2-8 sources
        float waveWidth = 4.0 + params.trailing * 12.0;    // 4-16 spatial frequency
        float sum = 0.0;
        for (int i = 0; i < sourceCount; i++) {
            float cx = gpuHash2D(float(i) * 7.13, 1.0);
            float cy = gpuHash2D(float(i) * 3.71, 2.0);
            float dist = length(float2(u - cx, v - cy));
            sum += sin(dist * waveWidth * scale - timestamp * speed);
        }
        brightness = (sum / float(sourceCount)) * 0.5 + 0.5;
    } else if (patternIndex == 7) {
        // Voronoi: distance to nearest of variable moving seed points
        int seedCount = min(3 + int(effectiveIntensity * 13.0), 16); // 3-16 seeds
        float minDist2 = 1e10;
        for (int i = 0; i < seedCount; i++) {
            float bx = gpuHash2D(float(i) * 5.17, 3.0);
            float by = gpuHash2D(float(i) * 9.31, 4.0);
            float ddx = gpuHash2D(float(i) * 2.53, 5.0) - 0.5;
            float ddy = gpuHash2D(float(i) * 6.79, 6.0) - 0.5;
            float sx = bx + ddx * sin(timestamp * speed * 0.3 + float(i));
            float sy = by + ddy * cos(timestamp * speed * 0.4 + float(i) * 1.3);
            float dx2 = (u - sx) * scale;
            float dy2 = (v - sy) * scale;
            float dist2 = dx2 * dx2 + dy2 * dy2;
            minDist2 = min(minDist2, dist2);
        }
        float minDist = sqrt(minDist2);
        // Trailing controls edge sharpness: low = sharp cell boundaries, high = soft glow
        float edgeFactor = 2.0 + (1.0 - params.trailing) * 4.0; // 2-6
        brightness = clamp(1.0 - minDist * edgeFactor, 0.0, 1.0);
    } else if (patternIndex == 8) {
        // Warp: intensity controls angular frequency (spiral arms), trailing controls distortion depth
        float angularFreq = 1.0 + effectiveIntensity * 7.0;  // 1-8 spiral arms
        float distortion = 5.0 + params.trailing * 15.0;   // 5-20 radial frequency
        float2 center = float2(0.5, 0.5);
        float2 delta = float2(u - center.x, v - center.y);
        float radius = length(delta) + 0.001;
        float angle = atan2(delta.y, delta.x);
        brightness = sin(log(radius) * distortion * scale - timestamp * speed + angle * angularFreq) * 0.5 + 0.5;
    } else if (patternIndex == 9) {
        // Static: intensity controls glitch rate, trailing controls band size
        float glitchRate = 3.0 + effectiveIntensity * 27.0;   // 3-30 updates/sec
        float bandSize = 1.0 + params.trailing * 4.0;       // 1-5 row grouping
        float quantizedRow = floor(float(row) / bandSize) * bandSize;
        float bandOffset = gpuHash2D(quantizedRow + floor(timestamp * glitchRate * speed), 0.0);
        float noise = gpuHash2D(float(col) + bandOffset * float(columns), quantizedRow + floor(timestamp * (glitchRate * 2.0) * speed));
        brightness = noise;
    } else if (patternIndex == 10) {
        // Pulse: expanding sonar rings from center with trailing glow
        int ringCount = min(2 + int(effectiveIntensity * 6.0), 8);   // 2-8 rings
        float ringWidth = 0.02 + params.trailing * 0.13;   // 0.02-0.15 thickness
        float2 center = float2(0.5, 0.5);
        float dist = length(float2((u - center.x) * scale, (v - center.y) * scale));
        float maxRadius = 1.5 * scale;
        float ringSpacing = maxRadius / float(ringCount);
        float sum = 0.0;
        for (int i = 0; i < ringCount; i++) {
            float ringPos = fmod(timestamp * speed * 0.5 + float(i) * ringSpacing, maxRadius);
            float ringDist = abs(dist - ringPos);
            // Smooth falloff from ring center gives depth instead of razor-thin edges
            float ringBright = gpuSmoothstep(ringWidth, 0.0, ringDist);
            // Fade ring as it expands outward
            float ageFade = 1.0 - (ringPos / maxRadius);
            sum += ringBright * ageFade;
        }
        brightness = clamp(sum, 0.0, 1.0);
    } else if (patternIndex == 11) {
        // DVD Bounce: bright region bouncing off edges
        float logoW = 0.15 / scale;
        float logoH = 0.10 / scale;
        float vx = 0.31;
        float vy = 0.23;
        // Bounce position via triangle wave (ping-pong)
        float rangeX = 1.0 - logoW;
        float rangeY = 1.0 - logoH;
        float px = fmod(timestamp * speed * vx, rangeX * 2.0);
        float py = fmod(timestamp * speed * vy, rangeY * 2.0);
        if (px > rangeX) px = rangeX * 2.0 - px;
        if (py > rangeY) py = rangeY * 2.0 - py;
        // Distance from pixel to logo rectangle
        float dx = max(0.0, max(px - u, u - (px + logoW)));
        float dy = max(0.0, max(py - v, v - (py + logoH)));
        float dist = length(float2(dx, dy));
        // Glow falloff controlled by trailing
        float glowRadius = 0.02 + params.trailing * 0.08;
        float logoBright = gpuSmoothstep(glowRadius, 0.0, dist);
        // Subtle ambient glow so the screen isn't fully black
        float ambient = 0.03;
        brightness = clamp(logoBright + ambient, 0.0, 1.0);
    } else if (patternIndex == 12) {
        // Metaballs: merging liquid blobs via sum of inverse-squared distances
        int blobCount = min(3 + int(effectiveIntensity * 7.0), 10); // 3-10 blobs
        float field = 0.0;
        for (int i = 0; i < blobCount; i++) {
            float bx = gpuHash2D(float(i) * 5.17, 3.0);
            float by = gpuHash2D(float(i) * 9.31, 4.0);
            float ox = 0.3 * sin(timestamp * speed * 0.4 + float(i) * 2.1);
            float oy = 0.3 * cos(timestamp * speed * 0.3 + float(i) * 1.7);
            float cx = bx + ox;
            float cy = by + oy;
            float dx = (u - cx) * scale;
            float dy = (v - cy) * scale;
            float dist2 = dx * dx + dy * dy + 0.001;
            // Blob radius controlled by trailing: larger trailing = fatter blobs
            float radius = 0.005 + params.trailing * 0.02;
            field += radius / dist2;
        }
        brightness = clamp(field, 0.0, 1.0);
    } else if (patternIndex == 13) {
        // Starfield: stars flying outward from center
        float starBright = 0.0;
        int starLayers = min(3 + int(effectiveIntensity * 5.0), 8); // 3-8 layers
        for (int layer = 0; layer < starLayers; layer++) {
            float layerSpeed = (0.3 + float(layer) * 0.2) * speed;
            float layerDepth = 1.0 + float(layer) * 0.5;
            // Tile the UV space to create a grid of stars
            float tileSize = 0.08 / (scale * layerDepth);
            float offsetT = timestamp * layerSpeed * 0.1;
            float su = fmod(u + offsetT * 0.3 + float(layer) * 0.13, 1.0);
            float sv = fmod(v + offsetT * 0.2 + float(layer) * 0.17, 1.0);
            float cellX = floor(su / tileSize);
            float cellY = floor(sv / tileSize);
            float localU = fmod(su, tileSize) / tileSize;
            float localV = fmod(sv, tileSize) / tileSize;
            // Star position within cell
            float starU = gpuHash2D(cellX * 7.13 + float(layer) * 31.0, cellY * 11.37);
            float starV = gpuHash2D(cellX * 3.71 + float(layer) * 47.0, cellY * 13.91);
            float dist = length(float2(localU - starU, localV - starV));
            // Twinkle
            float twinkle = 0.6 + 0.4 * sin(timestamp * speed * 2.0 + cellX * 5.0 + cellY * 7.0);
            float glowSize = 0.15 + params.trailing * 0.25;
            float star = gpuSmoothstep(glowSize, 0.0, dist) * twinkle;
            starBright = max(starBright, star / layerDepth);
        }
        brightness = clamp(starBright, 0.0, 1.0);
    } else if (patternIndex == 14) {
        // Spiral Galaxy: rotating logarithmic spiral arms with bright core
        float2 center = float2(0.5, 0.5);
        float dx = (u - center.x) * scale;
        float dy = (v - center.y) * scale;
        float radius = length(float2(dx, dy)) + 0.001;
        float angle = atan2(dy, dx);
        // Core glow
        float core = 0.3 / (radius * 8.0 + 0.1);
        // Spiral arms use log spiral: angle = a + b*ln(r)
        float spiralTightness = 3.0 + params.trailing * 4.0;
        float armCount = 2.0 + floor(effectiveIntensity * 4.0); // 2-6 arms
        float spiralAngle = angle - spiralTightness * log(radius + 0.01) + timestamp * speed * 0.2;
        float armBright = pow(0.5 + 0.5 * cos(spiralAngle * armCount), 4.0);
        // Fade arms at large radius
        float armFade = exp(-radius * 3.0);
        // Add noise for texture
        float noise = gpuSmoothNoise2D(u * 20.0 * scale + timestamp * 0.1, v * 20.0 * scale);
        float arms = armBright * armFade * (0.7 + 0.3 * noise);
        brightness = clamp(core + arms, 0.0, 1.0);
    } else if (patternIndex == 15) {
        // Terrain: animated topographic contour lines from layered noise
        float nx = u * 6.0 * scale + timestamp * speed * 0.05;
        float ny = v * 6.0 * scale + timestamp * speed * 0.03;
        // Multi-octave noise for terrain height
        float height = gpuSmoothNoise2D(nx, ny) * 0.6
                      + gpuSmoothNoise2D(nx * 2.0 + 5.0, ny * 2.0 + 5.0) * 0.3
                      + gpuSmoothNoise2D(nx * 4.0 + 10.0, ny * 4.0 + 10.0) * 0.1;
        // Contour line count is controlled by intensity
        float contourCount = 5.0 + effectiveIntensity * 15.0; // 5-20 contour lines
        float contourPhase = fmod(height * contourCount, 1.0);
        // Line width controlled by trailing
        float lineWidth = 0.05 + params.trailing * 0.35;
        float contour = gpuSmoothstep(lineWidth, 0.0, contourPhase)
                       + gpuSmoothstep(lineWidth, 0.0, 1.0 - contourPhase);
        // Subtle elevation shading behind contours
        float elevation = height * 0.15;
        brightness = clamp(contour * 0.85 + elevation, 0.0, 1.0);
    } else if (patternIndex == 16) {
        // Rain on Glass: vertical water streaks running down
        float streakBright = 0.0;
        int streakCount = min(5 + int(effectiveIntensity * 10.0), 15); // 5-15 streaks
        for (int i = 0; i < streakCount; i++) {
            // Each streak has a random X position, width, speed
            float streakX = gpuHash2D(float(i) * 7.13, 1.0);
            float streakWidth = 0.01 + gpuHash2D(float(i) * 3.71, 2.0) * 0.03;
            float streakSpeed = 0.1 + gpuHash2D(float(i) * 11.37, 3.0) * 0.3;
            // Wobble the streak horizontally
            float wobble = 0.01 * sin(v * 20.0 * scale + timestamp * speed + float(i) * 5.0);
            float xDist = abs(u - streakX - wobble);
            if (xDist < streakWidth) {
                // The streak head moves down vertically
                float headY = fmod(timestamp * speed * streakSpeed + gpuHash2D(float(i) * 5.0, 4.0), 1.3);
                float trailLen = 0.1 + params.trailing * 0.4;
                float yDist = headY - v;
                if (yDist > 0.0 && yDist < trailLen) {
                    float xFade = 1.0 - xDist / streakWidth;
                    float yFade = 1.0 - yDist / trailLen;
                    // Brighter at head, fading trail
                    float dropBright = xFade * yFade * yFade;
                    streakBright = max(streakBright, dropBright);
                }
            }
        }
        // Ambient wetness
        float wetness = 0.02 + 0.03 * gpuSmoothNoise2D(u * 30.0, v * 30.0 + timestamp * 0.5);
        brightness = clamp(streakBright + wetness, 0.0, 1.0);
    } else if (patternIndex == 17) {
        // Aurora: shimmering northern lights curtains
        float auroraSum = 0.0;
        int curtainCount = min(2 + int(effectiveIntensity * 4.0), 6); // 2-6 curtains
        for (int i = 0; i < curtainCount; i++) {
            float baseY = 0.3 + float(i) * 0.12;
            float waveSpeed = (0.5 + float(i) * 0.3) * speed;
            // Horizontal wave creating curtain shape
            float wave = baseY
                        + 0.08 * sin(u * 8.0 * scale + timestamp * waveSpeed + float(i) * 2.0)
                        + 0.04 * sin(u * 15.0 * scale - timestamp * waveSpeed * 0.7 + float(i) * 5.0)
                        + 0.02 * sin(u * 25.0 * scale + timestamp * waveSpeed * 1.3);
            // Vertical falloff from curtain center
            float dist = abs(v - wave);
            float curtainWidth = 0.03 + params.trailing * 0.08;
            float curtainBright = gpuSmoothstep(curtainWidth, 0.0, dist);
            // Shimmer
            float shimmer = 0.7 + 0.3 * sin(u * 40.0 * scale + timestamp * speed * 3.0 + float(i) * 11.0);
            auroraSum += curtainBright * shimmer * (0.6 + 0.4 / float(i + 1));
        }
        brightness = clamp(auroraSum, 0.0, 1.0);
    }

    uint charIndex = uint(brightness * float(characterCount - 1));
    charIndex = min(charIndex, characterCount - 1);
    return float2(float(charIndex), brightness);
}

kernel void idleScreenProceduralInstances(
    device IdleScreenCharacterInstance *instances [[buffer(0)]],
    constant IdleScreenProceduralUniforms &uniforms [[buffer(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= uniforms.gridSize.x
        || position.y >= uniforms.gridSize.y
        || uniforms.sceneSize.x == 0
        || uniforms.sceneSize.y == 0
        || uniforms.glyphCount == 0) {
        return;
    }

    const uint sceneColumn = (uniforms.sceneOrigin.x + position.x)
        % uniforms.sceneSize.x;
    const uint sceneRow = (uniforms.sceneOrigin.y + position.y)
        % uniforms.sceneSize.y;
    const float2 sample = generatePattern(
        sceneColumn,
        sceneRow,
        uniforms.sceneSize.x,
        uniforms.sceneSize.y,
        uniforms.patternIndex,
        uniforms.timestamp,
        uniforms.glyphCount,
        uniforms
    );
    const float sourceBrightness = clamp(sample.y, 0.0, 1.0);
    uint glyphIndex = uint(sample.x);
    if (uniforms.patternIndex == 3) {
        const float shuffleRate = sourceBrightness > 0.01 ? 6.0 : 0.5;
        const float tick = floor(uniforms.timestamp * shuffleRate);
        const float signal = gpuHash2D(
            float(sceneColumn) * 3.17 + tick,
            float(sceneRow) * 5.23
        );
        glyphIndex = uint(signal * float(uniforms.glyphCount - 1));
    }
    glyphIndex = min(glyphIndex, uniforms.glyphCount - 1);

    float brightness = clamp(
        (sourceBrightness - 0.5) * uniforms.contrast + 0.5,
        0.0,
        1.0
    );
    brightness *= uniforms.sceneBrightness;
    const uint instanceIndex = position.y * uniforms.gridSize.x + position.x;
    instances[instanceIndex].gridBrightnessGlyph = float4(
        float(position.x),
        float(position.y),
        brightness,
        float(glyphIndex)
    );
    instances[instanceIndex].foreground = uniforms.foreground;
}

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
