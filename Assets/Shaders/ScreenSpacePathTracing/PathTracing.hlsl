#ifndef URP_SCREEN_SPACE_PATH_TRACING_HLSL
#define URP_SCREEN_SPACE_PATH_TRACING_HLSL

#include "./PathTracingUtilities.hlsl"

// If no intersection, "rayHit.distance" will remain "REAL_EPS".
RayHit RayMarching(Ray ray, half insideObject, half dither, half3 viewDirectionWS, half sceneDistance = 0.0)
{
    RayHit rayHit = InitializeRayHit();

    // True:  The ray points to the scene objects.
    // False: The ray points to the camera plane.
    bool isFrontRay = (dot(ray.direction, viewDirectionWS) <= 0.0) ? true : false;

    // Store a frequently used material property
    half stepSize = STEP_SIZE;

    // Initialize small step ray marching settings
    half thickness = MARCHING_THICKNESS_SMALL_STEP;
    half currStepSize = SMALL_STEP_SIZE;

    // Minimum thickness of scene objects without backface depth
    half marchingThickness = MARCHING_THICKNESS;

    // Initialize current ray position.
    float3 rayPositionWS = ray.position;

    // Interpolate the intersecting position using the depth difference.
    float lastDepthDiff = 0.0;
    //float2 lastRayPositionNDC = float2(0.0, 0.0);
    float3 lastRayPositionWS = ray.position; // avoid using 0 for the first interpolation

    bool startBinarySearch = false;

    // Adaptive Ray Marching
    // Near: Use smaller step size to improve accuracy.
    // Far:  Use larger step size to fill the scene.
    bool activeSamplingSmall = true;
    bool activeSamplingMedium = true;

    UNITY_LOOP
    for (int i = 1; i <= MAX_STEP; i++)
    {
        if (i > MAX_SMALL_STEP && i <= MAX_MEDIUM_STEP && activeSamplingSmall)
        {
            activeSamplingSmall = false;
            currStepSize = (startBinarySearch) ? currStepSize : MEDIUM_STEP_SIZE;
            thickness = (startBinarySearch) ? thickness : MARCHING_THICKNESS_MEDIUM_STEP;
            marchingThickness = MARCHING_THICKNESS;
        }
        else if (i > MAX_MEDIUM_STEP && !activeSamplingSmall && activeSamplingMedium)
        {
            activeSamplingMedium = false;
            // [Far] Use a small step size only when objects are close to the camera.
            currStepSize = (startBinarySearch) ? currStepSize : lerp(stepSize, 20.0, sceneDistance * 0.001);
            thickness = (startBinarySearch) ? thickness : MARCHING_THICKNESS;
            marchingThickness = MARCHING_THICKNESS;
        }

        // Update current ray position.
        rayPositionWS += (currStepSize + currStepSize * dither) * ray.direction;

        float3 rayPositionNDC = ComputeNormalizedDeviceCoordinatesWithZ(rayPositionWS, GetWorldToHClipMatrix());
        float3 lastRayPositionNDC = ComputeNormalizedDeviceCoordinatesWithZ(lastRayPositionWS, GetWorldToHClipMatrix());

        // Move to the next step if the current ray moves less than 1 pixel across the screen.
        if (i <= MAX_MEDIUM_STEP && abs(rayPositionNDC.x - lastRayPositionNDC.x) < _BlitTexture_TexelSize.x && abs(rayPositionNDC.y - lastRayPositionNDC.y) < _BlitTexture_TexelSize.y)
            continue;

    #if (UNITY_REVERSED_Z == 0) // OpenGL platforms
        rayPositionNDC.z = rayPositionNDC.z * 0.5 + 0.5; // -1..1 to 0..1
    #endif

        // Stop marching the ray when outside screen space.
        bool isScreenSpace = rayPositionNDC.x > 0.0 && rayPositionNDC.y > 0.0 && rayPositionNDC.x < 1.0 && rayPositionNDC.y < 1.0 ? true : false;
        if (!isScreenSpace)
            break;

        // Sample the 3-layer depth
        float deviceDepth; // z buffer (front) depth
    #if defined(_BACKFACE_TEXTURES)
        if (insideObject == 1.0 && _SupportRefraction)
            // Transparent Depth Layer 2
            deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraBackDepthTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
        else if (insideObject == 2.0 && _SupportRefraction)
            // Opaque Depth Layer
            deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
        else
            // Transparent Depth Layer 1
            deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
    #else
        if (insideObject != 0.0 && _SupportRefraction)
            // Opaque Depth Layer
            deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
        else
            // Transparent Depth Layer 1
            deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
    #endif

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
    #if defined(_BACKFACE_TEXTURES)
        if (insideObject == 1.0 && _SupportRefraction)
            deviceBackDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
        else
            deviceBackDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraBackDepthTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
        sceneBackDepth = LinearEyeDepth(deviceBackDepth, _ZBufferParams);

        backDepthValid = (deviceBackDepth != UNITY_RAW_FAR_CLIP_VALUE) && (sceneBackDepth >= sceneDepth);

        if (backDepthValid)
            backDepthDiff = hitDepth - sceneBackDepth;
        else
            backDepthDiff = depthDiff - marchingThickness;
    #endif

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
        if (startBinarySearch)
        {
            currStepSize *= 0.5;
            currStepSize = (FastSign(currStepSize) == Sign) ? currStepSize : -currStepSize;
        }

        // Do not reflect sky, use reflection probe fallback.
        bool isSky = sceneDepth == UNITY_RAW_FAR_CLIP_VALUE ? true : false;

        // [No minimum step limit] The current implementation focuses on performance, so the ray will stop marching once it hits something.
        // Rules of ray hit:
        // 1. Ray is behind the front-faces of object. (sceneDepth <= hitDepth)
        // 2. Ray is in front of back-faces of object. (sceneBackDepth >= hitDepth) or (sceneDepth + marchingThickness >= hitDepth)
        // 3. Ray does not hit sky. (!isSky)
        bool hitSuccessful;
        bool isBackHit = false;

        // Ignore the incorrect "backDepthDiff" when objects (ex. Plane with front face only) has no thickness and blocks the backface depth rendering of objects behind it.
    #if defined(_BACKFACE_TEXTURES)
        UNITY_BRANCH
        if (backDepthValid)
        {
            // It's difficult to find the intersection of thin objects in several steps with large step sizes, so we add a minimum thickness to all objects to make it visually better.
            hitSuccessful = ((depthDiff <= 0.0) && (hitDepth <= max(sceneBackDepth, sceneDepth + currStepSize)) && !isSky) ? true : false;
            //hitSuccessful = !isSky && (isFrontRay && (depthDiff <= 0.1 && depthDiff >= -0.1) || !isFrontRay && (hitDepth <= max(sceneBackDepth , sceneDepth + MARCHING_THICKNESS) + 0.1 && hitDepth >= max(sceneBackDepth, sceneDepth + MARCHING_THICKNESS) - 0.1)) ? true : false;
            isBackHit = hitDepth > sceneBackDepth && Sign > 0.0;
        }
        else
    #endif
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
            HitSurfaceDataFromGBuffer(rayPositionNDC.xy, rayHit);
            
            // Reverse the normal direction since it's a back face.
            // Reuse the front face GBuffer to save performance.
        #if defined(_BACKFACE_TEXTURES)
            if (isBackHit && _BackDepthEnabled == 2.0)
            {
                half3 backNormal = SAMPLE_TEXTURE2D_X_LOD(_CameraBackNormalsTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).rgb;
                if (any(backNormal))
                    rayHit.normal = -backNormal; // Accurate (refraction)
                else
                    rayHit.normal = -rayHit.normal; // Approximate
            }
            else if (isBackHit)
                rayHit.normal = -rayHit.normal; // Approximate
        #endif

            // Add position offset to avoid self-intersection, we don't know the next ray direction yet.
            rayHit.position += rayHit.normal * RAY_BIAS;

            break;
        }
        // [Optimization] Exponentially increase the stepSize when the ray hasn't passed through the intersection.
        // From https://blog.voxagon.se/2018/01/03/screen-space-path-tracing-diffuse.html
        else if (!startBinarySearch)
        {
            // As the distance increases, the accuracy of ray intersection test becomes less important.
            currStepSize += currStepSize * 0.1;
            marchingThickness += MARCHING_THICKNESS * 0.25;
        }

        // Update last step's depth difference.
        lastDepthDiff = (isBackSearch) ? backDepthDiff : depthDiff;
        //lastRayPositionNDC = rayPositionNDC.xy;
        lastRayPositionWS = rayPositionWS.xyz;
    }
    return rayHit;
}

half3 EvaluateBRDF(inout Ray ray, RayHit rayHit, float3 positionWS, float2 screenUV)
{
    // If the ray intersects the scene.
    if (rayHit.distance > REAL_EPS)
    {
        // Incoming Ray Direction
        half3 viewDirectionWS = -ray.direction;
        half NdotV = ClampNdotV(dot(rayHit.normal, viewDirectionWS));

        // Probabilities of each lobe
        bool doRefraction = (rayHit.ior == -1.0) ? false : true;
        half refractProbability = doRefraction ? ReflectivitySpecular(rayHit.albedo) : 0.0;
        half specProbability = doRefraction ? 1.0 - refractProbability : ReflectivitySpecular(max(rayHit.specular, kDieletricSpec.rgb));
        half diffProbability = (1.0 - specProbability - refractProbability);

        half perceptualRoughness = 1.0 - rayHit.smoothness;
        half roughness = perceptualRoughness * perceptualRoughness;

        float2 random = float2(GenerateRandomValue(screenUV), GenerateRandomValue(screenUV));
        half3x3 localToWorld = GetLocalFrame(rayHit.normal);

        // Roulette-select the ray's path.
        half roulette = GenerateRandomValue(screenUV);

        // TODO: reimplement the refraction to match Disney BSDF
        UNITY_BRANCH
        if (refractProbability > 0.0 && roulette < refractProbability)
        {
            // Refraction
            rayHit.ior = rayHit.insideObject == 1.0 ? rcp(rayHit.ior) : rayHit.ior; // (air / material) : (material / air)

            half VdotH;
            half NdotH;
            SampleGGXNDF(random, viewDirectionWS, localToWorld, roughness, rayHit.normal, NdotH, VdotH);

            half fresnel = F_Schlick(0.04, max(rayHit.smoothness, 0.04), VdotH);

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
                ray.energy *= rcp(max(refractProbability, 0.001)) * exp(rayHit.albedo * max(rayHit.distance, 2.5)); // Artistic: add a minimum color absorption distance.
            else if (rayHit.insideObject == 1.0) // apply the tint here if the ray needs to fall back to reflection probe
                ray.energy *= rcp(max(refractProbability, 0.001)) * rayHit.albedo;
        }
        else if (specProbability > 0.0 && roulette < specProbability)
        {
            // Note: H is the microfacet normal direction

            half VdotH;
            half NdotL;
            half3 L;
            half weightOverPdf;

            ImportanceSampleGGX_PDF(random, viewDirectionWS, localToWorld, roughness, NdotV, L, VdotH, NdotL, weightOverPdf);

            half3 F = F_Schlick(rayHit.specular, VdotH);

            // Outgoing Ray Direction
            ray.direction = L;
            ray.position = rayHit.position;

            half3 brdf = F;

            // Fresnel component is apply here as describe in ImportanceSampleGGX function
            ray.energy *= rcp(specProbability) * brdf * weightOverPdf;
        }
        else if (diffProbability > 0.0 && roulette < diffProbability)
        {
            half3 L;
            half NdotL;
            half weightOverPdf;

            // for Disney we still use a Cosine importance sampling, true Disney importance sampling imply a look up table
            ImportanceSampleLambert(random, localToWorld, L, NdotL, weightOverPdf);
            
            // Outgoing Ray Direction
            ray.direction = L;
            ray.position = rayHit.position;

            // For fixed luminance lighting units in URP, we don't need to do the PI division
        #if USE_DISNEY_DIFFUSE
            half LdotV = saturate(dot(ray.direction, viewDirectionWS));

            half3 brdf = rayHit.albedo * DisneyDiffuseNoPI(NdotV, NdotL, LdotV, perceptualRoughness);
        #else
            half3 brdf = rayHit.albedo * LambertNoPI(); // "LambertNoPI()" is "1.0"
        #endif
            
            ray.energy *= rcp(diffProbability) * brdf * weightOverPdf;
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

        // Reflection Probes Fallback
        half3 color = SampleReflectionProbes(ray.direction, positionWS, 1.0h, screenUV);
        return color;
    }
}

void ScreenSpacePathTracing(float depth, float3 positionWS, float3 cameraPositionWS, half3 viewDirectionWS, float2 screenUV, out half3 color)
{
    // Skip if sky
    bool isBackground = depth == UNITY_RAW_FAR_CLIP_VALUE ? true : false;

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

    // Ignore ForwardOnly objects, the GBuffer MaterialFlags cannot help distinguish them.
    // Current solution is to assume objects with 0 smoothness are ForwardOnly. (DepthNormalsOnly pass will output 0 to gbuffer2.a)
    // Which means Deferred objects should have at least 0.01 smoothness.
    bool isForwardOnly = false;

#if defined(_TEMPORAL_ACCUMULATION)
    half historySample = SAMPLE_TEXTURE2D_X_LOD(_PathTracingSampleTexture, my_point_clamp_sampler, screenUV, 0).r;
#endif
    half rayCount = RAY_COUNT;

    UNITY_LOOP
    for (int i = 0; i < rayCount; i++)
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

            HitSurfaceDataFromGBuffer(screenUV, rayHit);

        #if defined(_TEMPORAL_ACCUMULATION)
            if (rayHit.smoothness > 0.5 || historySample == 1.0)
                rayCount = max(RAY_COUNT_LOW_SAMPLE, RAY_COUNT); // Cast more rays if the history sample is low.
        #endif

        #if defined(_IGNORE_FORWARD_OBJECTS)
            isForwardOnly = rayHit.smoothness == 0.0 ? true : false;
        #endif
            if (isForwardOnly && !isBackground)
            {
                color = rayHit.emission;
                break;
            }
            else
            {
                // Firefly reduction
                // From https://twitter.com/YuriyODonnell/status/1199253959086612480
                // Seems to be no difference, need to dig deeper later.
                half oldRoughness = (1.0 - rayHit.smoothness);
                oldRoughness = oldRoughness * oldRoughness;
                half modifiedRoughness = min(1.0, oldRoughness + roughnessBias);
                //rayHit.smoothness = 1.0 - sqrt(modifiedRoughness);
                roughnessBias += oldRoughness * 0.75;

                // energy * emission * SPP accumulation factor
                color += ray.energy * EvaluateBRDF(ray, rayHit, positionWS, screenUV) * rcp(rayCount);
            }
        }

        // Other bounces.
        UNITY_LOOP
        for (int j = 0; j < RAY_BOUNCE; j++)
        {
            half sceneDistance = rayHit.distance * 0.1;
            depth = LinearEyeDepth(depth, _ZBufferParams);
            rayHit = RayMarching(ray, rayHit.insideObject, dither, viewDirectionWS, depth);

            // Firefly reduction
            // From https://twitter.com/YuriyODonnell/status/1199253959086612480
            // Seems to be no difference, need to dig deeper later.
            half oldRoughness = (1.0 - rayHit.smoothness);
            oldRoughness = oldRoughness * oldRoughness;
            half modifiedRoughness = min(1.0, oldRoughness + roughnessBias);
            //rayHit.smoothness = 1.0 - sqrt(modifiedRoughness);
            roughnessBias += oldRoughness * 0.75;

            color += ray.energy * EvaluateBRDF(ray, rayHit, positionWS, screenUV) * rcp(rayCount);

            if (!any(ray.energy))
                break;

            // Russian Roulette - Randomly terminate rays.
            // From https://blog.demofox.org/2020/06/06/casual-shadertoy-path-tracing-2-image-improvement-and-glossy-reflections/
            // As the throughput gets smaller, the ray is more likely to get terminated early.
            // Survivors have their value boosted to make up for fewer samples being in the average.
            half stopRayEnergy = GenerateRandomValue(screenUV);

            half maxRayEnergy = Max3(ray.energy.r, ray.energy.g, ray.energy.b);

            if (maxRayEnergy < stopRayEnergy)
                break;

            // Add the energy we 'lose' by randomly terminating paths.
            ray.energy *= rcp(maxRayEnergy);
        }
    }
}

#endif