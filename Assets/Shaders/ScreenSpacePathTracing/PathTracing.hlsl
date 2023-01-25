#ifndef URP_SCREEN_SPACE_PATH_TRACING_HLSL
#define URP_SCREEN_SPACE_PATH_TRACING_HLSL

// Screen space path tracing is a screen space effect. (is it possible to fallback to hardware ray tracing when not in screen space?)

// Can modify these quality presets according to your needs.
// The unit of float values below is Unity unit (meter by default).
//===================================================================================================================================
// MARCHING_THICKNESS : It's the "Thickness / Error Tolerance" in ray marching.
//                      Increasing this may improve performance but reduce the accuracy of ray intersection test.
// 
// STEP_SIZE          : The ray's marching step size.
//                      Increasing this may improve performance but reduce the accuracy of ray intersection test.
//
// MAX_STEP           : The maximum marching steps of each ray.
//                      Increasing this may decrease performance but allows the ray to travel further. (if not decreasing STEP_SIZE)
// 
// RAY_BIAS           : The bias applied to ray's hit position to avoid self-intersection with hit position.
//                      Usually no need to adjust it.
// 
// RAY_BOUNCE         : Should be at least 2, the first bounce is from camera to scene (stored in GBuffer in this case).
//                      Increasing this may decrease performance but is necessary for recursive reflections.
//
// RAY_COUNT          : The number of rays generated per pixel. (Samples Per Pixel)
//                      Increasing this may significantly decrease performance but will provide a more convergent result when moving camera. (less noise)
// 
//                      If you set this too high, the GPU Driver may restart and causing Unity to shut down. (swapchain error)
//                      In this case, consider using Temporal-AA (in URP 15, 2023.1.0a20+) or Accumulation Renderer Feature to denoise?
//===================================================================================================================================
#if defined(_RAY_MARCHING_MEDIUM)
    #define MARCHING_THICKNESS    0.1
    #define STEP_SIZE             0.35
    #define MAX_STEP              64
    #define RAY_BIAS              0.001
    #define RAY_BOUNCE            4
#elif defined(_RAY_MARCHING_HIGH)
    #define MARCHING_THICKNESS    0.05
    #define STEP_SIZE             0.2
    #define MAX_STEP              192
    #define RAY_BIAS              0.001
    #define RAY_BOUNCE            6
#else //defined(_RAY_MARCHING_LOW)
    #define MARCHING_THICKNESS    0.1
    #define STEP_SIZE             0.4
    #define MAX_STEP              32
    #define RAY_BIAS              0.001
    #define RAY_BOUNCE            4
#endif
// Global quality settings.
    #define RAY_COUNT             1
//===================================================================================================================================

// Do not change, from URP's GBuffer hlsl.
//===================================================================================================================================
// Light flags (can shader graph access stencil buffer?)
#define kLightingInvalid  -1  // No dynamic lighting: can aliase any other material type as they are skipped using stencil
#define kLightingLit       1  // lit shader
#define kLightingSimpleLit 2  // Simple lit shader
#define kLightFlagSubtractiveMixedLighting    4 // The light uses subtractive mixed lighting.

// Material flags (customize Lit shader to add new lighting model?)
#define kMaterialFlagReceiveShadowsOff        1 // Does not receive dynamic shadows
#define kMaterialFlagSpecularHighlightsOff    2 // Does not receivce specular
#define kMaterialFlagSubtractiveMixedLighting 4 // The geometry uses subtractive mixed lighting
#define kMaterialFlagSpecularSetup            8 // Lit material use specular setup instead of metallic setup

TEXTURE2D_X_HALF(_GBuffer0); // color.rgb + materialFlags.a
TEXTURE2D_X_HALF(_GBuffer1); // specular.rgb + oclusion.a
TEXTURE2D_X_HALF(_GBuffer2); // normalWS.rgb + smoothness.a
// _GBuffer3                 // indirectLighting.rgb (B10G11R11 / R16G16B16A16)

// GBuffer 3 is the current render target, which means inaccessible.
// It's also the Emission GBuffer when there's no lighting in scene.
TEXTURE2D_X(_BlitTexture);   // indirectLighting.rgb (B10G11R11 / R16G16B16A16)

SAMPLER(my_point_clamp_sampler);

#if _RENDER_PASS_ENABLED

#define GBUFFER0 0
#define GBUFFER1 1
#define GBUFFER2 2

FRAMEBUFFER_INPUT_HALF(GBUFFER0);
FRAMEBUFFER_INPUT_HALF(GBUFFER1);
FRAMEBUFFER_INPUT_HALF(GBUFFER2);
#endif
//===================================================================================================================================

// Helper functions
//===================================================================================================================================
uint UnpackMaterialFlags(float packedMaterialFlags)
{
    return uint((packedMaterialFlags * 255.0h) + 0.5h);
}

// Calculate the average value of a 3-component input.
half energy(half3 color)
{
    return dot(color, 1.0 / 3.0);
}

// From HDRP "RayTracingSampling.hlsl"
// This is an implementation of the method from the paper
// "A Low-Discrepancy Sampler that Distributes Monte Carlo Errors as a Blue Noise in Screen Space" by Heitz et al.
float GetBNDSequenceSample(uint2 pixelCoord, uint sampleIndex, uint sampleDimension)
{
    // wrap arguments
    pixelCoord = pixelCoord & 127;
    sampleIndex = sampleIndex & 255;
    sampleDimension = sampleDimension & 255;

    // xor index based on optimized ranking
    uint rankingIndex = (pixelCoord.x + pixelCoord.y * 128) * 8 + (sampleDimension & 7);
    uint rankedSampleIndex = sampleIndex ^ clamp((uint)(_RankingTileXSPP[uint2(rankingIndex & 127, rankingIndex / 128)] * 256.0), 0, 255);

    // fetch value in sequence
    uint value = clamp((uint)(_OwenScrambledTexture[uint2(sampleDimension, rankedSampleIndex.x)] * 256.0), 0, 255);

    // If the dimension is optimized, xor sequence value based on optimized scrambling
    uint scramblingIndex = (pixelCoord.x + pixelCoord.y * 128) * 8 + (sampleDimension & 7);
    float scramblingValue = min(_ScramblingTileXSPP[uint2(scramblingIndex & 127, scramblingIndex / 128)].x, 0.999);
    value = value ^ uint(scramblingValue * 256.0);

    // Convert to float (to avoid the same 1/256th quantization everywhere, we jitter by the pixel scramblingValue)
    return (scramblingValue + value) / 256.0;
}

// Generate a random value according to the current noise method.
// Counter is built into the function. (_Seed)
float GenerateRandomValue(float2 screenUV)
{
    float time = unity_DeltaTime.y * _Time.y;
    _Seed += 1.0;
#if defined(METHOD_BLUE_NOISE)
    return GetBNDSequenceSample(uint2(screenUV * _ScreenSize.xy), time, _Seed);
#else
    return GenerateHashedRandomFloat(uint3(screenUV * _ScreenSize.xy, time + _Seed));
#endif
}

void HitSurfaceDataFromGBuffer(float2 screenUV, inout half3 albedo, inout half3 specular, inout half3 normal, inout half3 emission, inout half smoothness)
{
#if defined(_FOVEATED_RENDERING_NON_UNIFORM_RASTER)
    screenUV = (screenUV * 2.0 - 1.0) * _ScreenSize.zw;
#endif

#if _RENDER_PASS_ENABLED
    half4 gbuffer0 = LOAD_FRAMEBUFFER_INPUT(GBUFFER0, screenUV);
    half4 gbuffer1 = LOAD_FRAMEBUFFER_INPUT(GBUFFER1, screenUV);
    half4 gbuffer2 = LOAD_FRAMEBUFFER_INPUT(GBUFFER2, screenUV);
#else
    // Using SAMPLE_TEXTURE2D is faster than using LOAD_TEXTURE2D on iOS platforms (5% faster shader).
    // Possible reason: HLSLcc upcasts Load() operation to float, which doesn't happen for Sample()?
    half4 gbuffer0 = SAMPLE_TEXTURE2D_X_LOD(_GBuffer0, my_point_clamp_sampler, screenUV, 0);
    half4 gbuffer1 = SAMPLE_TEXTURE2D_X_LOD(_GBuffer1, my_point_clamp_sampler, screenUV, 0);
    half4 gbuffer2 = SAMPLE_TEXTURE2D_X_LOD(_GBuffer2, my_point_clamp_sampler, screenUV, 0);
#endif
    half3 gbuffer3 = SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, my_point_clamp_sampler, screenUV, 0).rgb;

    bool isForward = false;
#if defined(_IGNORE_FORWARD_OBJECTS)
    isForward = gbuffer2.a == 0.0 ? true : false;
#endif

    // URP does not clear color GBuffer (albedo & specular), only the depth & stencil.
    // This can cause smearing-like artifacts.
    albedo = isForward? half3(0.0, 0.0, 0.0) : gbuffer0.rgb;
    
    uint materialFlags = UnpackMaterialFlags(gbuffer0.a);
    // 0.04 is the "Dieletric Specular" (kDieletricSpec.rgb)
    specular = materialFlags == kMaterialFlagSpecularSetup ? gbuffer1.rgb : lerp(half3(0.04, 0.04, 0.04), albedo, gbuffer1.r); // Specular & Metallic setup conversion

#ifdef _GBUFFER_NORMALS_OCT
    half2 remappedOctNormalWS = half2(Unpack888ToFloat2(gbuffer2.rgb));          // values between [ 0, +1]
    half2 octNormalWS = remappedOctNormalWS.xy * half(2.0) - half(1.0);          // values between [-1, +1]
    normal = half3(UnpackNormalOctQuadEncode(octNormalWS));                      // values between [-1, +1]
#else
    normal = gbuffer2.rgb;
#endif

    emission = gbuffer3.rgb;
    smoothness = gbuffer2.a;
}
//===================================================================================================================================

// position  : world space ray origin
// direction : world space ray direction
// energy    : color of the ray (no more than 1.0)
struct Ray
{
    float3 position;
    half3  direction;
    half3  energy;
};

// position  : world space hit position
// distance  : distance that ray travels
// ...       : surfaceData of hit position
struct RayHit
{
    float3 position;
    float  distance;
    half3  albedo;
    half3  specular;
    half3  normal;
    half3  emission;
    half   smoothness;
};

// position : the intersection between Ray and Scene.
// distance : the distance from Ray's starting position to intersection.
// normal   : the normal direction of the intersection.
// ...      : material information from GBuffer.
RayHit InitializeRayHit()
{
    RayHit rayHit;
    rayHit.position = float3(0.0, 0.0, 0.0);
    rayHit.distance = REAL_EPS;
    rayHit.albedo = half3(0.0, 0.0, 0.0);
    rayHit.specular = half3(0.0, 0.0, 0.0);
    rayHit.normal = half3(0.0, 0.0, 0.0);
    rayHit.emission = half3(0.0, 0.0, 0.0);
    rayHit.smoothness = 0.0;
    return rayHit;
}

// If no intersection, "rayHit.distance" will remain "REAL_EPS".
RayHit RayMarching(Ray ray, half dither, bool isFirstBounce = false, float2 screenUV = float2(0.5, 0.5), float3 positionWS = float3(1.0, 1.0, 1.0), float3 cameraPositionWS = float3(0.0, 0.0, 0.0))
{
    RayHit rayHit;

    half stepSize = STEP_SIZE;
    // (Safety Distance) Push the ray's marching origin to a position that is near the intersection when in first bounce.
    half accumulatedStep = isFirstBounce ? (length(positionWS - cameraPositionWS) - STEP_SIZE) : 0.0;

    float lastDepthDiff = 0.0;
    //float2 lastRayPositionNDC = float2(0.0, 0.0);
    float3 lastRayPositionWS = float3(0.0, 0.0, 0.0);
    bool startBinarySearch = false;
    UNITY_LOOP
    for (int i = 1; i <= MAX_STEP; i++)
    {
        float4 rayStartPositionCS = ComputeClipSpacePosition(ray.position + accumulatedStep * ray.direction, GetWorldToHClipMatrix());

        accumulatedStep += (stepSize + stepSize * dither);

        float3 rayPositionWS = ray.position + accumulatedStep * ray.direction;

        float3 rayPositionNDC = ComputeNormalizedDeviceCoordinatesWithZ(rayPositionWS, GetWorldToHClipMatrix());

        float sceneDepth = -LinearEyeDepth(SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, sampler_CameraDepthTexture, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r, _ZBufferParams); // sampledDepth is (near to far) 0..1

        float hitDepth = LinearEyeDepth(rayPositionNDC.z, _ZBufferParams); // rayPositionNDC.z is (near to far) 1..0

        float depthDiff = hitDepth - sceneDepth;

        // Sign is positive : ray is in front of the actual intersection.
        // Sign is negative : ray is behind the actual intersection.
        half Sign = sign(depthDiff);
        startBinarySearch = startBinarySearch || (Sign == -1) ? true : false; // Start binary search when the ray is behind the actual intersection.

        // Half the step size each time when binary search starts.
        // If the ray passes through the intersection, we flip the sign of step size.
        if (startBinarySearch && sign(stepSize) != Sign)
        {
            stepSize = stepSize * Sign * 0.5;
        }
        
        // Stop marching the ray when outside screen space.
        bool isScreenSpace = rayPositionNDC.x > 0.0 && rayPositionNDC.y > 0.0 && rayPositionNDC.x < 1.0 && rayPositionNDC.y < 1.0 ? true : false;
        if (!isScreenSpace)
            break;

        // 1. isScreenSpace
        // 2. hitDepth <= sceneDepth
        // 3. sceneDepth < hitDepth + MARCHING_THICKNESS
        if (isScreenSpace && abs(depthDiff) <= MARCHING_THICKNESS)
        {
            rayHit.position = rayPositionWS;
            rayHit.distance = length(rayPositionWS - ray.position);

            // Lerp the world space position according to depth difference.
            // From https://baddogzz.github.io/2020/03/06/Accurate-Hit/
            // 
            // x: position from last marching
            // y: current ray marching position (successfully hit the scene)
            //           |
            // Cam->--x--|-y
            //           |
            // Using the position between "x" and "y" is more accurate than using "y" directly.
            if (!isFirstBounce && Sign != sign(lastDepthDiff))
            {
                // Seems that interpolating screenUV is giving worse results, so do it for positionWS only.
                //rayPositionNDC.xy = lerp(lastRayPositionNDC, rayPositionNDC.xy, lastDepthDiff / (lastDepthDiff - depthDiff));
                rayHit.position = lerp(lastRayPositionWS, rayHit.position, lastDepthDiff / (lastDepthDiff - depthDiff));
            }

            HitSurfaceDataFromGBuffer(rayPositionNDC.xy, rayHit.albedo, rayHit.specular, rayHit.normal, rayHit.emission, rayHit.smoothness);
            break;
        }

        // Update last step's depth difference.
        lastDepthDiff = depthDiff;
        //lastRayPositionNDC = rayPositionNDC.xy;
        lastRayPositionWS = rayPositionWS.xyz;
    }
    return rayHit;
}

half3 EvaluateColor(inout Ray ray, RayHit rayHit, half dither, float3 random, half3 viewDirectionWS, float3 positionWS, bool isBackground = false)
{
    // If the ray intersects the scene.
    if (rayHit.distance > REAL_EPS)
    {
        // Calculate chances of diffuse and specular reflection.
        half specChance = energy(rayHit.specular);
        half diffChance = energy(rayHit.albedo);

        // Roulette-select the ray's path.
        half roulette = random.z;

        // Fresnel effect
        half fresnel = F_Schlick(0.04, max(rayHit.smoothness, 0.04), saturate(dot(rayHit.normal, ray.direction)));

        if (specChance > 0 && roulette < specChance + fresnel)
        {
            // Specular reflection
            rayHit.specular = lerp(rayHit.albedo, rayHit.specular, rayHit.specular.r);
            ray.direction = normalize(lerp(SampleHemisphereCosine(random.x, random.y, reflect(ray.direction, rayHit.normal)), reflect(ray.direction, rayHit.normal), rayHit.smoothness));
            // If the random direction is pointing below the surface, try re-generating it with swapped values.
            ray.direction = (dot(rayHit.normal, -ray.direction) >= 0.0) ? ray.direction : normalize(lerp(SampleHemisphereCosine(random.y, random.x, reflect(ray.direction, rayHit.normal)), reflect(ray.direction, rayHit.normal), rayHit.smoothness));
            ray.position = rayHit.position + ray.direction * RAY_BIAS;
            ray.energy *= (1.0 / specChance) * rayHit.specular;
        }
        else if (diffChance > 0 && roulette < specChance + diffChance)
        {
            // Diffuse reflection
            ray.direction = SampleHemisphereCosine(random.x, random.y, rayHit.normal);
            ray.position = rayHit.position + ray.direction * RAY_BIAS;
            ray.energy *= (1.0 / diffChance) * rayHit.albedo;
        }
        else
        {
            // Terminate ray
            ray.energy = 0.0;
        }

        return rayHit.emission;
    }
    // If no intersection from ray marching.
    else
    {
        // Erase the ray's energy - the sky doesn't reflect anything.
        ray.energy = 0.0;

        // URP won't set correct reflection probe for a full screen blit mesh. (issue ID: UUM-2631)
        // The reflection probe(s) is set by a C# script attached to the Camera.
        // The script won't get the correct probe for scene camera, it'll use game camera's instead.

        half3 color = half3(0.0, 0.0, 0.0);
    #ifdef _USE_REFLECTION_PROBE
        // Check if the reflection probes are correctly set.
        if (_ProbeSet == 1.0)
        {
            UNITY_BRANCH
            if (_SpecCube0_ProbePosition.w > 0) // Box Projection Probe
            {
                float3 factors = ((-ray.direction > 0 ? _SpecCube0_BoxMax.xyz : _SpecCube0_BoxMin.xyz) - positionWS) / -ray.direction;
                float scalar = min(min(factors.x, factors.y), factors.z);
                float3 uvw = -ray.direction * scalar + (positionWS - _SpecCube0_ProbePosition.xyz);
                color = DecodeHDREnvironment(SAMPLE_TEXTURECUBE_LOD(_SpecCube0, sampler_SpecCube0, uvw, 1), _SpecCube0_HDR).rgb * _Exposure; // "mip level 1" will provide a less noisy result.
            }
            else
            {
                color = DecodeHDREnvironment(SAMPLE_TEXTURECUBE_LOD(_SpecCube0, sampler_SpecCube0, -ray.direction, 1), _SpecCube0_HDR).rgb * _Exposure;
            }

            UNITY_BRANCH
            if (_ProbeWeight > 0.0) // Probe Blending Enabled
            {
                half3 probe2Color = half3(0.0, 0.0, 0.0);
                UNITY_BRANCH
                if (_SpecCube1_ProbePosition.w > 0) // Box Projection Probe
                {
                    float3 factors = ((-ray.direction > 0 ? _SpecCube1_BoxMax.xyz : _SpecCube1_BoxMin.xyz) - positionWS) / -ray.direction;
                    float scalar = min(min(factors.x, factors.y), factors.z);
                    float3 uvw = -ray.direction * scalar + (positionWS - _SpecCube1_ProbePosition.xyz);
                    probe2Color = DecodeHDREnvironment(SAMPLE_TEXTURECUBE_LOD(_SpecCube1, sampler_SpecCube1, uvw, 1), _SpecCube1_HDR).rgb * _Exposure;
                }
                else
                {
                    probe2Color = DecodeHDREnvironment(SAMPLE_TEXTURECUBE_LOD(_SpecCube1, sampler_SpecCube1, -ray.direction, 1), _SpecCube1_HDR).rgb * _Exposure;
                }
                // Blend the probes if necessary.
                color = lerp(color, probe2Color, _ProbeWeight).rgb;
            }
        }
        
    #else
        color = SAMPLE_TEXTURECUBE_LOD(_Static_Lighting_Sky, sampler_Static_Lighting_Sky, -ray.direction, 0).rgb * _Exposure;
    #endif
        return color;

    }
}

// Shader Graph does not support passing custom structure.
void EvaluateColor_float(float3 cameraPositionWS, half3 viewDirectionWS, float2 screenUV, float3 positionWS, bool isBackground, half dither, out half3 color)
{
    // Avoid shader warning of using unintialized value.
    color = half3(0.0, 0.0, 0.0);
    if (isBackground)
    {
        // Blit texture (_BlitTexture) contains Skybox color.
        color = SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, my_point_clamp_sampler, UnityStereoTransformScreenSpaceTex(screenUV), 0).rgb;
        return;
    }

    // Ignore ForwardOnly objects, the GBuffer MaterialFlags cannot help distinguish them.
    // Current solution is to assume objects with 0 smoothness are ForwardOnly. (DepthNormalsOnly pass will output 0 to gbuffer2.a)
    // Which means Deferred objects should have at least 0.01 smoothness.
    bool isForward = false;

    float3 random;
    half roughnessBias = 0.0;
    RayHit rayHit = InitializeRayHit();

    // Avoid shader warning that the loop only iterates once.
#if RAY_COUNT > 1
    UNITY_LOOP
    for (int i = 0; i < RAY_COUNT; i++)
#endif
    {
        Ray ray;
        ray.position = cameraPositionWS;
        ray.direction = viewDirectionWS;
        ray.energy = half3(1.0, 1.0, 1.0);

        float time = unity_DeltaTime.y * _Time.y;

        // For rays from camera to scene (first bounce), add an initial distance according to the world position reconstructed from depth.
        // This allows ray marching to consider distant objects without increasing the maximum number of steps.
        {
            rayHit = RayMarching(ray, dither, true, screenUV, positionWS, cameraPositionWS);

            random.x = GenerateRandomValue(screenUV);
            random.y = GenerateRandomValue(screenUV);
            random.z = GenerateRandomValue(screenUV);

#if defined(_IGNORE_FORWARD_OBJECTS)
            isForward = rayHit.smoothness == 0.0 ? true : false;
#endif
            if (isForward && !isBackground)
            {
                color = rayHit.emission;
            #if RAY_COUNT > 1
                break;
            #endif
            }
            else
            {
                // energy * emission * SPP accumulation factor
                color += ray.energy * EvaluateColor(ray, rayHit, dither, random, viewDirectionWS, positionWS, isBackground) * rcp(RAY_COUNT);
            }
        }

        // Other bounces.
        for (int j = 1; j < RAY_BOUNCE; j++)
        {
            rayHit = RayMarching(ray, dither);

            // Firefly reduction
            // From https://twitter.com/YuriyODonnell/status/1199253959086612480
            // Seems to be no difference, need to dig deeper later.
            half oldRoughness = (1.0 - rayHit.smoothness) * (1.0 - rayHit.smoothness);
            half modifiedRoughness = min(1.0, oldRoughness + roughnessBias);
            rayHit.smoothness = 1.0 - sqrt(modifiedRoughness);
            roughnessBias += oldRoughness * 0.75;

            random.x = GenerateRandomValue(screenUV);
            random.y = GenerateRandomValue(screenUV);
            random.z = GenerateRandomValue(screenUV);
            
            color += ray.energy * EvaluateColor(ray, rayHit, dither, random, viewDirectionWS, positionWS) * rcp(RAY_COUNT);

            if (!any(ray.energy))
                break;

            // Russian Roulette - Randomly terminate rays.
            // From https://blog.demofox.org/2020/06/06/casual-shadertoy-path-tracing-2-image-improvement-and-glossy-reflections/
            // As the throughput gets smaller, the ray is more likely to get terminated early.
            // Survivors have their value boosted to make up for fewer samples being in the average.
            half stopRayEnergy = GenerateRandomValue(screenUV);

            half maxRayEnergy = max(max(ray.energy.r, ray.energy.g), ray.energy.b);

            if (maxRayEnergy < stopRayEnergy)
                break;

            // Add the energy we 'lose' by randomly terminating paths.
            ray.energy *= 1.0 / maxRayEnergy;

        }
    }
}

#endif