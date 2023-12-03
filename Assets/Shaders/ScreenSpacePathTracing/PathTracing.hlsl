#ifndef URP_SCREEN_SPACE_PATH_TRACING_HLSL
#define URP_SCREEN_SPACE_PATH_TRACING_HLSL

#include "./PathTracingConfig.hlsl" // Screen Space Path Tracing Configuration
#include "./PathTracingInput.hlsl"
#include "./PathTracingFallback.hlsl" // Reflection Probes Sampling
#include "./PathTracingUtilities.hlsl"

// If no intersection, "rayHit.distance" will remain "REAL_EPS".
RayHit RayMarching(Ray ray, half insideObject, half dither, half3 viewDirectionWS, half sceneDistance = 0.0)
{
    RayHit rayHit = InitializeRayHit();

    // True:  The ray points to the scene objects.
    // False: The ray points to the camera plane.
    bool isFrontRay = (dot(ray.direction, viewDirectionWS) <= 0.0) ? true : false;

    // [Near] Use a small step size only when objects are close to the camera.
    half stepSize = STEP_SIZE * lerp(0.05, 1.0, sceneDistance);
    half marchingThickness = MARCHING_THICKNESS;
    half accumulatedStep = 0.0;

    // Interpolate the intersecting position using the depth difference.
    float lastDepthDiff = 0.0;
    //float2 lastRayPositionNDC = float2(0.0, 0.0);
    float3 lastRayPositionWS = ray.position; // avoid using 0 for the first interpolation

    bool startBinarySearch = false;

    // Adaptive Ray Marching
    // Near: Use smaller step size to improve accuracy.
    // Far:  Use larger step size to fill the scene.
    bool activeSampling = true;

    UNITY_LOOP
    for (uint i = 1; i <= MAX_STEP; i++)
    {
        if (i > MAX_SMALL_STEP && activeSampling)
        {
            activeSampling = false;
            // [Far] Use a small step size only when objects are close to the camera.
            stepSize = (startBinarySearch) ? stepSize : STEP_SIZE * lerp(0.5, 5.0, sceneDistance);
        }

        // Add or subtract from the total step size.
        accumulatedStep += stepSize + stepSize * dither;

        // Calculate current ray position.
        float3 rayPositionWS = ray.position + accumulatedStep * ray.direction;
        float3 rayPositionNDC = ComputeNormalizedDeviceCoordinatesWithZ(rayPositionWS, GetWorldToHClipMatrix());

#if (UNITY_REVERSED_Z == 0) // OpenGL platforms
        rayPositionNDC.z = rayPositionNDC.z * 0.5 + 0.5; // -1..1 to 0..1
#endif

        // Stop marching the ray when outside screen space.
        bool isScreenSpace = rayPositionNDC.x > 0.0 && rayPositionNDC.y > 0.0 && rayPositionNDC.x < 1.0 && rayPositionNDC.y < 1.0 ? true : false;
        if (!isScreenSpace)
            break;

        // Sample the 3-layer depth
        float deviceDepth; // z buffer (front) depth
        UNITY_BRANCH
        if (_BackDepthEnabled != 0.0)
        {
            if (insideObject == 1.0 && _SupportRefraction == 1.0)
                // Transparent Depth Layer 2
                deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraBackDepthTexture, sampler_CameraBackDepthTexture, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r;
            else if (insideObject == 2.0 && _SupportRefraction == 1.0)
                // Opaque Depth Layer
                deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, sampler_CameraDepthTexture, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r;
            else
                // Transparent Depth Layer 1
                deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, sampler_CameraDepthAttachment, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r;
        }
        else
        {
            if (insideObject != 0.0 && _SupportRefraction == 1.0)
                // Opaque Depth Layer
                deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, sampler_CameraDepthTexture, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r;
            else
                // Transparent Depth Layer 1
                deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, sampler_CameraDepthAttachment, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r;
        }

        // Convert Z-Depth to Linear Eye Depth
        // Value Range: Camera Near Plane -> Camera Far Plane
        float sceneDepth = LinearEyeDepth(deviceDepth, _ZBufferParams);
        float hitDepth = LinearEyeDepth(rayPositionNDC.z, _ZBufferParams); // Non-GL (DirectX): rayPositionNDC.z is (near to far) 1..0

        // Calculate (front) depth difference
        // Positive: ray is in front of the front-faces of object.
        // Negative: ray is behind the front-faces of object.
        float depthDiff = sceneDepth - hitDepth;

        // Initialize variables
        float deviceBackDepth = 0.0; // z buffer (back) depth
        float sceneBackDepth = 0.0;

        // Calculate (back) depth difference
        // Positive: ray is in front of the back-faces of object.
        // Negative: ray is behind the back-faces of object.
        float backDepthDiff = 0.0;

        // Avoid infinite thickness for objects with no thickness (ex. Plane).
        // 1. Back-face depth value is not from sky
        // 2. Back-faces should behind Front-faces.
        bool backDepthValid = false; 
        UNITY_BRANCH
        if (_BackDepthEnabled != 0.0)
        {
            if (insideObject == 1.0 && _SupportRefraction == 1.0)
                deviceBackDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, sampler_CameraDepthTexture, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r;
            else
                deviceBackDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraBackDepthTexture, sampler_CameraBackDepthTexture, UnityStereoTransformScreenSpaceTex(rayPositionNDC.xy), 0).r;
            sceneBackDepth = LinearEyeDepth(deviceBackDepth, _ZBufferParams);

    #if (UNITY_REVERSED_Z == 1)
            backDepthValid = deviceBackDepth != 0.0 ? true : false;
    #else
            backDepthValid = deviceBackDepth != 1.0 ? true : false; // OpenGL Platforms.
    #endif
            backDepthValid = backDepthValid && (sceneBackDepth >= sceneDepth);

            if (backDepthValid)
                backDepthDiff = hitDepth - sceneBackDepth;
            else
                backDepthDiff = depthDiff - marchingThickness;
        }

        // Binary Search Sign is used to flip the ray marching direction.
        // Sign is positive : ray is in front of the actual intersection.
        // Sign is negative : ray is behind the actual intersection.
        half Sign;
        bool isBackSearch = (!isFrontRay && hitDepth > sceneBackDepth && backDepthValid);
        if (isBackSearch)
            Sign = FastSign(backDepthDiff);
        else
            Sign = FastSign(depthDiff);

        // Disable binary search:
        // 1. The ray points to the camera plane, but is in front of all objects.
        // 2. The ray leaves the camera plane, but is behind all objects.
        // 3. The ray is an outgoing (refracted) ray. (we only have 3-layer depth)
        bool cannotBinarySearch = (insideObject != 2.0) && !startBinarySearch && (isFrontRay ? hitDepth > sceneBackDepth : hitDepth < sceneDepth);

        // Start binary search when the ray is behind the actual intersection.
        startBinarySearch = !cannotBinarySearch && (startBinarySearch || (Sign == -1)) ? true : false;

        // Half the step size each time when binary search starts.
        // If the ray passes through the intersection, we flip the sign of step size.
        if (startBinarySearch && FastSign(stepSize) != Sign)
        {
            stepSize = stepSize * Sign * 0.5;
        }

        // Do not reflect sky, use reflection probe fallback.
        bool isSky; 
    #if (UNITY_REVERSED_Z == 1)
        isSky = deviceDepth == 0.0 ? true : false;
    #else
        isSky = deviceDepth == 1.0 ? true : false; // OpenGL Platforms.
    #endif

        // [No minimum step limit] The current implementation focuses on performance, so the ray will stop marching once it hits something.
        // Rules of ray hit:
        // 1. Ray is behind the front-faces of object. (sceneDepth <= hitDepth)
        // 2. Ray is in front of back-faces of object. (sceneBackDepth >= hitDepth) or (sceneDepth + marchingThickness >= hitDepth)
        // 3. Ray does not hit sky. (!isSky)
        bool hitSuccessful;
        bool isBackHit = false;

        // Ignore the incorrect "backDepthDiff" when objects (ex. Plane with front face only) has no thickness and blocks the backface depth rendering of objects behind it.
        UNITY_BRANCH
        if (_BackDepthEnabled != 0.0 && backDepthValid)
        {
            // It's difficult to find the intersection of thin objects in several steps with large step sizes, so we add a minimum thickness to all objects to make it visually better.
            hitSuccessful = ((depthDiff <= 0.0) && (hitDepth <= max(sceneBackDepth, sceneDepth + MARCHING_THICKNESS)) && !isSky) ? true : false;
            isBackHit = hitDepth > sceneBackDepth && Sign > 0.0;
        }
        else
        {
            hitSuccessful = ((depthDiff <= 0.0) && (depthDiff >= -marchingThickness) && !isSky) ? true : false;
        }

        // If we find the intersection.
        if (hitSuccessful)
        {
            rayHit.position = rayPositionWS;
            rayHit.distance = length(rayPositionWS - ray.position);
            rayHit.insideObject = insideObject;

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
                float interpDepthDiff = (isBackSearch) ? backDepthDiff : depthDiff;
                //rayPositionNDC.xy = lerp(lastRayPositionNDC, rayPositionNDC.xy, lastDepthDiff * rcp(lastDepthDiff - interpDepthDiff));
                rayHit.position = lerp(lastRayPositionWS, rayHit.position, lastDepthDiff * rcp(lastDepthDiff - interpDepthDiff));
            }
            
            // Get the material data of the hit position.
            HitSurfaceDataFromGBuffer(rayPositionNDC.xy, rayHit.albedo, rayHit.specular, rayHit.normal, rayHit.emission, rayHit.smoothness, rayHit.ior, rayHit.insideObject);
            
            // Reverse the normal direction since it's a back face.
            // Reuse the front face GBuffer to save performance.
            if (isBackHit && _BackDepthEnabled == 2.0)
            {
                half3 backNormal = SAMPLE_TEXTURE2D_X_LOD(_CameraBackNormalsTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).rgb;
                if (!any(backNormal))
                    rayHit.normal = -rayHit.normal; // Approximate
                else
                    rayHit.normal = backNormal; // Accurate (refraction)
            }
            else if (isBackHit)
                rayHit.normal = -rayHit.normal; // Approximate

            // Add position offset to avoid self-intersection, we don't know the next ray direction yet.
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
        lastDepthDiff = (isBackSearch) ? backDepthDiff : depthDiff;
        //lastRayPositionNDC = rayPositionNDC.xy;
        lastRayPositionWS = rayPositionWS.xyz;
    }
    return rayHit;
}

half3 EvaluateColor(inout Ray ray, RayHit rayHit, half3 viewDirectionWS, float3 positionWS, float2 screenUV, bool isBackground = false)
{
    // If the ray intersects the scene.
    if (rayHit.distance > REAL_EPS)
    {
        // Calculate chances of refraction, diffuse and specular reflection.
        bool doRefraction = (rayHit.ior == -1.0) ? false : true;
        half refractChance = doRefraction ? ReflectivitySpecular(rayHit.albedo) : 0.0;
        half specChance = doRefraction ? 1.0 - refractChance : ReflectivitySpecular(rayHit.specular);
        half diffChance = 1.0 - specChance - refractChance;

        // Roulette-select the ray's path.
        half roulette = GenerateRandomValue(screenUV);

        // Fresnel effect
        half fresnel = F_Schlick(0.04, max(rayHit.smoothness, 0.04), saturate(dot(rayHit.normal, -ray.direction)));

        UNITY_BRANCH
        if (refractChance > 0.0 && roulette < refractChance)
        {
            // Refraction
            rayHit.ior = rayHit.insideObject == 1.0 ? rcp(rayHit.ior) : rayHit.ior; // (air / material) : (material / air)
            float2 random;
            random.x = GenerateRandomValue(screenUV);
            random.y = GenerateRandomValue(screenUV);
            rayHit.normal = ImportanceSampleGGX(random, rayHit.normal, rayHit.smoothness);
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
            GGX ggx = ImportanceSampleGGX_PDF(screenUV, rayHit.normal, -ray.direction, rayHit.smoothness);
            ray.direction = ggx.direction;
            ray.position = rayHit.position;
            // BRDF * cosTheta / PDF
            // [specular / dot(N, L)] * dot(N, L) / 1.0
            ray.energy *= rcp(specChance) * rayHit.specular; //* ggx.weight;
        }
        else if (diffChance > 0.0 && roulette < diffChance + fresnel)
        {
            float2 random;
            random.x = GenerateRandomValue(screenUV);
            random.y = GenerateRandomValue(screenUV);
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

        // Forward or Deferred:
        // URP won't set correct reflection probe for a full screen blit mesh. (issue ID: UUM-2631)
        // The reflection probe(s) is set by a C# script attached to the Camera.
        // The script won't get the correct probe for scene camera, it'll use game camera's instead.

        // Forward+:
        // Sample the reflection probe atlas.

        half3 color = half3(0.0, 0.0, 0.0);
    #ifdef _USE_REFLECTION_PROBE
        // Reflection Probes Fallback
        color = SampleReflectionProbes(ray.direction, positionWS, 0.99h, screenUV);
    #else
        // Not suggested
        color = SAMPLE_TEXTURECUBE_LOD(_Static_Lighting_Sky, sampler_Static_Lighting_Sky, ray.direction, 0).rgb * _Exposure;
    #endif
        return color;
    }
}

// Shader Graph does not support passing custom structure.
void EvaluateColor_float(float3 cameraPositionWS, half3 viewDirectionWS, float2 screenUV, out half3 color)
{
    // Reconstruct world position
    float depth;
    if (_SupportRefraction == 1.0)
        depth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, sampler_CameraDepthAttachment, UnityStereoTransformScreenSpaceTex(screenUV), 0).r;
    else
        depth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, sampler_CameraDepthTexture, UnityStereoTransformScreenSpaceTex(screenUV), 0).r;
#if !UNITY_REVERSED_Z
    depth = lerp(UNITY_NEAR_CLIP_VALUE, 1, depth);
#endif
    float3 positionWS = ComputeWorldSpacePosition(screenUV, depth, UNITY_MATRIX_I_VP);

    // Skip if sky
    bool isBackground;
#if (UNITY_REVERSED_Z == 1)
    isBackground = depth == 0.0 ? true : false;
#else
    isBackground = depth == 1.0 ? true : false; // OpenGL Platforms.
#endif

    // Dither the step size to reduce banding artifacts.
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
    bool isForwardOnly = false;

    // Avoid shader warning that the loop only iterates once.
#if RAY_COUNT > 1
    UNITY_LOOP
    for (uint i = 0; i < RAY_COUNT; i++)
#endif
    {
        RayHit rayHit = InitializeRayHit(); // should be reinitialized for each sample.
        half roughnessBias = 0.0;
        Ray ray;
        ray.position = cameraPositionWS;
        ray.direction = -viewDirectionWS; // viewDirectionWS points to the camera.
        ray.energy = half3(1.0, 1.0, 1.0);

        // [No ray marching needed] We already know the result of first hit, since it goes from the camera to scene.
        {
            rayHit.distance = length(cameraPositionWS - positionWS);
            rayHit.position = positionWS;

            HitSurfaceDataFromGBuffer(screenUV, rayHit.albedo, rayHit.specular, rayHit.normal, rayHit.emission, rayHit.smoothness, rayHit.ior, rayHit.insideObject);

        #if defined(_IGNORE_FORWARD_OBJECTS)
            isForwardOnly = rayHit.smoothness == 0.0 ? true : false;
        #endif
            if (isForwardOnly && !isBackground)
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
                half oldRoughness = (1.0 - rayHit.smoothness);
                oldRoughness = oldRoughness * oldRoughness;
                half modifiedRoughness = min(1.0, oldRoughness + roughnessBias);
                rayHit.smoothness = 1.0 - sqrt(modifiedRoughness);
                roughnessBias += oldRoughness * 0.75;

                // energy * emission * SPP accumulation factor
                color += ray.energy * EvaluateColor(ray, rayHit, viewDirectionWS, positionWS, screenUV, isBackground) * rcp(RAY_COUNT);
            }
        }

        // Other bounces.
        UNITY_LOOP
        for (int j = 0; j < RAY_BOUNCE; j++)
        {
            half sceneDistance = rayHit.distance * 0.1;
            rayHit = RayMarching(ray, rayHit.insideObject, dither, viewDirectionWS, sceneDistance);

            // Firefly reduction
            // From https://twitter.com/YuriyODonnell/status/1199253959086612480
            // Seems to be no difference, need to dig deeper later.
            half oldRoughness = (1.0 - rayHit.smoothness);
            oldRoughness = oldRoughness * oldRoughness;
            half modifiedRoughness = min(1.0, oldRoughness + roughnessBias);
            rayHit.smoothness = 1.0 - sqrt(modifiedRoughness);
            roughnessBias += oldRoughness * 0.75;

            color += ray.energy * EvaluateColor(ray, rayHit, viewDirectionWS, positionWS, screenUV) * rcp(RAY_COUNT);

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