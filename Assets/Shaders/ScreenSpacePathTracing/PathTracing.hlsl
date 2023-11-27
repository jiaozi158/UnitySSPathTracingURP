#ifndef URP_SCREEN_SPACE_PATH_TRACING_HLSL
#define URP_SCREEN_SPACE_PATH_TRACING_HLSL

#include "./PathTracingConfig.hlsl" // Screen Space Path Tracing Configuration
#include "./PathTracingInput.hlsl"
#include "./PathTracingFallback.hlsl" // Reflection Probes Sampling
#include "./PathTracingUtilities.hlsl"

// If no intersection, "rayHit.distance" will remain "REAL_EPS".
RayHit RayMarching(Ray ray, half insideObject, half dither, half sceneDistance = 0.0)
{
    RayHit rayHit = InitializeRayHit();

    // Use a small step size only when objects are close to the camera.
    half stepSize = STEP_SIZE * lerp(0.1, 1.0, sceneDistance * 0.02);
    half marchingThickness = MARCHING_THICKNESS;
    // (Safety Distance) Push the ray's marching origin to a position that is near the intersection when in first bounce.
    half accumulatedStep = 0.0;

    float lastDepthDiff = 0.0;
    //float2 lastRayPositionNDC = float2(0.0, 0.0);
    float3 lastRayPositionWS = float3(0.0, 0.0, 0.0);
    bool startBinarySearch = false;
    bool activeSampling = true;
    UNITY_LOOP
    for (uint i = 1; i <= MAX_STEP; i++)
    {
        if (i > MAX_SMALL_STEP && activeSampling)
        {
            activeSampling = false;
            stepSize = (startBinarySearch) ? stepSize : STEP_SIZE * lerp(0.3, 1.0, sceneDistance * 0.2);
        }

        accumulatedStep += stepSize + stepSize * dither;

        float3 rayPositionWS = ray.position + accumulatedStep * -ray.direction; // here we need viewDirectionWS

        float3 rayPositionNDC = ComputeNormalizedDeviceCoordinatesWithZ(rayPositionWS, GetWorldToHClipMatrix());

#if (UNITY_REVERSED_Z == 0) // OpenGL platforms
        rayPositionNDC.z = rayPositionNDC.z * 0.5 + 0.5; // -1..1 to 0..1
#endif

        // Stop marching the ray when outside screen space.
        bool isScreenSpace = rayPositionNDC.x > 0.0 && rayPositionNDC.y > 0.0 && rayPositionNDC.x < 1.0 && rayPositionNDC.y < 1.0 ? true : false;
        if (!isScreenSpace)
            break;

        float deviceDepth; // z buffer depth
        UNITY_BRANCH
        if (_BackDepthEnabled != 0.0)
        {
            if (insideObject == 1.0 && _SupportRefraction == 1.0)
                deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraBackDepthTexture, sampler_CameraBackDepthTexture, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r; // Transparent Depth Layer 2
            else if (insideObject == 2.0 && _SupportRefraction == 1.0)
                deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, sampler_CameraDepthTexture, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r; // Opaque Depth Layer
            else
                deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, sampler_CameraDepthAttachment, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r; // Transparent Depth Layer 1
        }
        else
        {
            if (insideObject != 0.0 && _SupportRefraction == 1.0)
                deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, sampler_CameraDepthTexture, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r; // Opaque Depth Layer
            else
                deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, sampler_CameraDepthAttachment, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r; // Transparent Depth Layer 1
        }
        float sceneDepth = -LinearEyeDepth(deviceDepth, _ZBufferParams);
        float hitDepth = LinearEyeDepth(rayPositionNDC.z, _ZBufferParams); // Non-GL (DirectX): rayPositionNDC.z is (near to far) 1..0

        float depthDiff = hitDepth - sceneDepth;

        float deviceBackDepth = 0.0;
        float sceneBackDepth = 0.0;
        float backDepthDiff = 0.0;
        bool backDepthValid = false; // Avoid infinite thickness for objects with no thickness (ex. Plane).
        UNITY_BRANCH
        if (_BackDepthEnabled != 0.0)
        {
            if (insideObject == 1.0 && _SupportRefraction == 1.0)
                deviceBackDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, sampler_CameraDepthTexture, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r;
            else
                deviceBackDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraBackDepthTexture, sampler_CameraBackDepthTexture, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r;
            sceneBackDepth = -LinearEyeDepth(deviceBackDepth, _ZBufferParams); // z buffer back depth

    #if (UNITY_REVERSED_Z == 1)
            backDepthValid = deviceBackDepth != 0.0 ? true : false;
    #else
            backDepthValid = deviceBackDepth != 1.0 ? true : false; // OpenGL Platforms.
    #endif

            if ((sceneBackDepth <= sceneDepth) && backDepthValid)
                backDepthDiff = sceneBackDepth - hitDepth; // -(hitDepth - sceneBackDepth)
            else
                backDepthDiff = depthDiff + marchingThickness;
        }

        // Sign is positive : ray is in front of the actual intersection.
        // Sign is negative : ray is behind the actual intersection.
        half Sign;
        if (hitDepth < sceneBackDepth)
            Sign = FastSign(backDepthDiff);
        else
            Sign = FastSign(depthDiff);
        startBinarySearch = startBinarySearch || (Sign == -1) ? true : false; // Start binary search when the ray is behind the actual intersection.

        // Half the step size each time when binary search starts.
        // If the ray passes through the intersection, we flip the sign of step size.
        if (startBinarySearch && sign(stepSize) != Sign)
        {
            stepSize = stepSize * Sign * 0.5;
        }

        bool isSky; // Do not reflect sky, the reflection probe fallback will provide better visuals.
    #if (UNITY_REVERSED_Z == 1)
        isSky = deviceDepth == 0.0 ? true : false;
    #else
        isSky = deviceDepth == 1.0 ? true : false; // OpenGL Platforms.
    #endif

        bool hitSuccessful;
        bool isBackHit = false;
        // 1. isScreenSpace
        // 2. hitDepth <= sceneDepth
        // 3. sceneDepth < hitDepth + MARCHING_THICKNESS
        // 4. hitDepth >= sceneBackDepth
        UNITY_BRANCH
        if (_BackDepthEnabled != 0.0)
        {
            // Ignore the incorrect "backDepthDiff" when objects (ex. Plane with front face only) has no thickness and blocks the backface depth rendering of objects behind it.
            if ((sceneBackDepth <= sceneDepth) && backDepthValid)
            {
                // It's difficult to find the intersection of thin objects in several steps with large step sizes, so we add a minimum thickness to all objects to make it visually better.
                hitSuccessful = (isScreenSpace && (depthDiff <= 0.0) && (hitDepth >= min(sceneBackDepth, sceneDepth - marchingThickness)) && !isSky) ? true : false;
                isBackHit = (hitDepth > sceneBackDepth && Sign > 0.0) ? true : false;
            }
            else
            {
                hitSuccessful = (isScreenSpace && (depthDiff <= 0.0) && (depthDiff >= -marchingThickness) && !isSky) ? true : false;
            }
        }
        else
        {
            hitSuccessful = (isScreenSpace && (depthDiff <= 0.0) && (depthDiff >= -marchingThickness) && !isSky) ? true : false;
        }

        if (hitSuccessful)
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
            if (Sign != FastSign(lastDepthDiff))
            {
                // Seems that interpolating screenUV is giving worse results, so do it for positionWS only.
                float interpDepthDiff = (hitDepth < sceneBackDepth) ? backDepthDiff : depthDiff;
                //rayPositionNDC.xy = lerp(lastRayPositionNDC, rayPositionNDC.xy, lastDepthDiff / (lastDepthDiff - interpDepthDiff));
                rayHit.position = lerp(lastRayPositionWS, rayHit.position, lastDepthDiff * rcp(lastDepthDiff - interpDepthDiff));
            }

            rayHit.insideObject = insideObject;
            HitSurfaceDataFromGBuffer(rayPositionNDC.xy, rayHit.albedo, rayHit.specular, rayHit.normal, rayHit.emission, rayHit.smoothness, rayHit.ior, rayHit.insideObject);
            
            // Reverse the normal direction since it's a back face.
            // Reuse the front face GBuffer to save performance.
            if (isBackHit && _BackDepthEnabled == 2.0)
            {
                half3 backNormal = SAMPLE_TEXTURE2D_X_LOD(_CameraBackNormalsTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).rgb;
                if (!any(backNormal))
                    rayHit.normal = -rayHit.normal;
                else
                    rayHit.normal = backNormal;
            }
            else if (isBackHit)
                rayHit.normal = -rayHit.normal;

            // Add position offset
            rayHit.position += rayHit.normal * RAY_BIAS;

            break;
        }
        // [Optimization] Exponentially increase the stepSize when the ray hasn't passed through the intersection.
        // From https://blog.voxagon.se/2018/01/03/screen-space-path-tracing-diffuse.html
        else if (!startBinarySearch)
        {
            // As the distance increases, the accuracy of ray intersection test becomes less important.
            half multiplier = lerp(1.0, 1.2, rayPositionNDC.z);
            stepSize = stepSize * multiplier + STEP_SIZE * 0.1 * multiplier;
            marchingThickness += MARCHING_THICKNESS * 0.25 * multiplier;
        }

        // Update last step's depth difference.
        lastDepthDiff = (hitDepth < sceneBackDepth) ? backDepthDiff : depthDiff;
        //lastRayPositionNDC = rayPositionNDC.xy;
        lastRayPositionWS = rayPositionWS.xyz;
    }
    return rayHit;
}

half3 EvaluateColor(inout Ray ray, RayHit rayHit, float3 random, half3 viewDirectionWS, float3 positionWS, float2 screenUV, bool isBackground = false)
{
    // If the ray intersects the scene.
    if (rayHit.distance > REAL_EPS)
    {
        // Calculate chances of refraction, diffuse and specular reflection.
        bool doRefraction = (rayHit.ior == -1.0) ? true : false;
        half refractChance = doRefraction ? 0.0 : ReflectivitySpecular(rayHit.albedo);
        half specChance = doRefraction ? ReflectivitySpecular(rayHit.specular) : 1.0 - refractChance;
        half diffChance = 1.0 - specChance - refractChance;

        // Roulette-select the ray's path.
        half roulette = random.z;

        // Fresnel effect
        half fresnel = F_Schlick(0.04, max(rayHit.smoothness, 0.04), saturate(dot(rayHit.normal, -ray.direction)));

        UNITY_BRANCH
        if (refractChance > 0.0 && roulette < refractChance)
        {
            // Refraction
            rayHit.ior = rayHit.insideObject == 1.0 ? rcp(rayHit.ior) : rayHit.ior; // (air / material) : (material / air)
            rayHit.normal = ImportanceSampleGGX(random.xy, rayHit.normal, rayHit.smoothness);
            half3 refractDir = refract(ray.direction, rayHit.normal, rayHit.ior);
            // Null vector check.
            if (any(refractDir) && roulette > fresnel)
            {
                ray.direction = refractDir;
            }
            // Total Internal Reflection && Specular Reflection
            else
            {
                ray.direction = reflect(ray.direction, rayHit.normal);
            }
            ray.position = rayHit.position;
            // Absorption
            if (rayHit.insideObject == 2.0) // Exit refractive object
                ray.energy *= rcp(refractChance) * exp(rayHit.albedo * max(rayHit.distance, 2.5)); // Artistic: add a minimum color absorption distance.
        }
        else if (specChance > 0.0 && roulette < specChance + fresnel)
        {
            // Specular reflection BRDF
            ray.direction = reflect(ray.direction, ImportanceSampleGGX(random.xy, rayHit.normal, rayHit.smoothness)); // Linear interpolation (lerp) doesn't match the actual specular lobes at all.
            ray.position = rayHit.position;
            // BRDF * cosTheta / PDF
            // [specular / dot(N, L)] * dot(N, L) / 1.0
            ray.energy *= rcp(specChance) * rayHit.specular;
        }
        else if (diffChance > 0.0 && roulette < diffChance + fresnel)
        {
            // Diffuse reflection BRDF
            ray.direction = SampleHemisphereCosine(random.x, random.y, rayHit.normal);
            ray.position = rayHit.position;
            // BRDF * cosTheta / PDF
            // (albedo / PI) * dot(N, L) / [1.0 / (2.0 * PI)]
            ray.energy *= rcp(diffChance) * rayHit.albedo * dot(ray.direction, rayHit.normal) * 2.0;
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
        // Reflection Probes Fallback
        color = SampleReflectionProbes(ray.direction, positionWS, 1.0h, screenUV);
    #else
        color = SAMPLE_TEXTURECUBE_LOD(_Static_Lighting_Sky, sampler_Static_Lighting_Sky, ray.direction, 0).rgb * _Exposure;
    #endif
        return color;

    }
}

// Shader Graph does not support passing custom structure.
void EvaluateColor_float(float3 cameraPositionWS, half3 viewDirectionWS, float2 screenUV, out half3 color)
{
    float depth;
    if (_SupportRefraction == 1.0)
        depth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, sampler_CameraDepthAttachment, UnityStereoTransformScreenSpaceTex(screenUV), 0).r;
    else
        depth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, sampler_CameraDepthTexture, UnityStereoTransformScreenSpaceTex(screenUV), 0).r;
#if !UNITY_REVERSED_Z
    depth = lerp(UNITY_NEAR_CLIP_VALUE, 1, depth);
#endif
    float3 positionWS = ComputeWorldSpacePosition(screenUV, depth, UNITY_MATRIX_I_VP);

    bool isBackground;
#if (UNITY_REVERSED_Z == 1)
    isBackground = depth == 0.0 ? true : false;
#else
    isBackground = depth == 1.0 ? true : false; // OpenGL Platforms.
#endif

    half dither = 0.0;
    UNITY_BRANCH
    if (_Dithering)
    {
    #if defined(_RAY_MARCHING_VERY_LOW)
        // Double the dither intensity if ray marching quality is set to very low (large STEP_SIZE).
        dither = (GenerateRandomValue(screenUV) * 0.4 - 0.2) * _Dither_Intensity; // Range from -0.2 to 0.2 (assuming intensity is 1)
    #else
        dither = (GenerateRandomValue(screenUV) * 0.2 - 0.1) * _Dither_Intensity; // Range from -0.1 to 0.1 (assuming intensity is 1)
    #endif
    }

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

    // Avoid shader warning that the loop only iterates once.
#if RAY_COUNT > 1
    UNITY_LOOP
    for (uint i = 0; i < RAY_COUNT; i++)
#endif
    {
        RayHit rayHit = InitializeRayHit(); // should be reinitialized for each sample.
        roughnessBias = 0.0;
        Ray ray;
        ray.position = cameraPositionWS;
        ray.direction = -viewDirectionWS; // viewDirectionWS points to the camera.
        ray.energy = half3(1.0, 1.0, 1.0);

        // For rays from camera to scene (first bounce), add an initial distance according to the world position reconstructed from depth.
        // This allows ray marching to consider distant objects without increasing the maximum number of steps.
        {
            rayHit.distance = length(cameraPositionWS - positionWS);
            rayHit.position = cameraPositionWS + rayHit.distance * viewDirectionWS;

            HitSurfaceDataFromGBuffer(screenUV, rayHit.albedo, rayHit.specular, rayHit.normal, rayHit.emission, rayHit.smoothness, rayHit.ior, rayHit.insideObject);

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
                // Firefly reduction
                // From https://twitter.com/YuriyODonnell/status/1199253959086612480
                // Seems to be no difference, need to dig deeper later.
                half oldRoughness = (1.0 - rayHit.smoothness) * (1.0 - rayHit.smoothness);
                half modifiedRoughness = min(1.0, oldRoughness + roughnessBias);
                rayHit.smoothness = 1.0 - sqrt(modifiedRoughness);
                roughnessBias += oldRoughness * 0.75;

                // energy * emission * SPP accumulation factor
                color += ray.energy * EvaluateColor(ray, rayHit, random, viewDirectionWS, positionWS, screenUV, isBackground) * rcp(RAY_COUNT);
            }
        }

        // Other bounces.
        UNITY_LOOP
        for (int j = 0; j < RAY_BOUNCE; j++)
        {
            half sceneDistance = (j == 0) ? rayHit.distance : 0.0;
            rayHit = RayMarching(ray, rayHit.insideObject, dither, sceneDistance);

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

            color += ray.energy * EvaluateColor(ray, rayHit, random, viewDirectionWS, positionWS, screenUV) * rcp(RAY_COUNT);

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
            ray.energy *= rcp(maxRayEnergy);
        }
    }
    // Filter out negative color pixels here.
    // There shouldn't be negative values since the smallest is 0.
    // [To Be Confirmed] But the "URP Rendering Debugger" reported that the effect is outputting slightly negative values.
    color = max(color, half3(0.001, 0.001, 0.001));
}

// Override for half precision graph.
void EvaluateColor_half(float3 cameraPositionWS, half3 viewDirectionWS, float2 screenUV, out half3 color)
{
    EvaluateColor_float(cameraPositionWS, viewDirectionWS, screenUV, color);
}

#endif