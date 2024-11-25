#ifndef URP_SCREEN_SPACE_PATH_TRACING_UTILITIES_HLSL
#define URP_SCREEN_SPACE_PATH_TRACING_UTILITIES_HLSL

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SpaceTransforms.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/BSDF.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/BRDF.hlsl"

#include "./PathTracingConfig.hlsl" // Screen Space Path Tracing Configuration
#include "./PathTracingInput.hlsl"
#include "./PathTracingFallback.hlsl" // Reflection Probes Sampling


#ifndef kDieletricSpec
#define kDieletricSpec half4(0.04, 0.04, 0.04, 1.0 - 0.04) // standard dielectric reflectivity coef at incident angle (= 4%)
#endif

#ifdef _SUPPORT_REFRACTION
#define _SupportRefraction true
#else
#define _SupportRefraction false
#endif

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
    half   ior;
    half   insideObject; // inside refraction object
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
    rayHit.ior = -1.0;
    rayHit.insideObject = 0.0;
    return rayHit;
}

uint UnpackMaterialFlags(float packedMaterialFlags)
{
    return uint((packedMaterialFlags * 255.0h) + 0.5h);
}

#if defined(_METHOD_BLUE_NOISE)
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
#endif

// Generate a random value according to the current noise method.
// Counter is built into the function. (_Seed)
float GenerateRandomValue(float2 screenUV)
{
    //float time = unity_DeltaTime.y * _Time.y;
    _Seed += 1.0;
#if defined(_METHOD_BLUE_NOISE)
    return GetBNDSequenceSample(uint2(screenUV * _ScreenSize.xy), _FrameIndex, _Seed);
#else
    return GenerateHashedRandomFloat(uint3(screenUV * _ScreenSize.xy, _FrameIndex + _Seed));
#endif
}

void HitSurfaceDataFromGBuffer(float2 screenUV, inout RayHit rayHit)
{
#if defined(_FOVEATED_RENDERING_NON_UNIFORM_RASTER)
    screenUV = (screenUV * 2.0 - 1.0) * _ScreenSize.zw;
#endif

    half4 transparentGBuffer1 = half4(0.0, 0.0, 0.0, 1.0);
    uint surfaceType = 0;
    bool isTransparentGBuffer = (rayHit.insideObject != 2.0 && _SupportRefraction);
    UNITY_BRANCH
    if (isTransparentGBuffer)
    {
        transparentGBuffer1 = SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer1, my_point_clamp_sampler, screenUV, 0);
        surfaceType = UnpackMaterialFlags(transparentGBuffer1.a);
    }
    UNITY_BRANCH
    if (surfaceType == kSurfaceTypeRefraction && isTransparentGBuffer)
    {
        half4 transparentGBuffer0 = SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer0, my_point_clamp_sampler, screenUV, 0);
        half4 transparentGBuffer2 = SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer2, my_point_clamp_sampler, screenUV, 0);
        rayHit.albedo = transparentGBuffer0.rgb;
        rayHit.specular = kDieletricSpec.rgb;
        rayHit.ior = transparentGBuffer1.r * 2.0h + 0.921875h;
        rayHit.normal = transparentGBuffer2.rgb;
        
    #if defined(_GBUFFER_NORMALS_OCT)
        half2 remappedOctNormalWS = half2(Unpack888ToFloat2(rayHit.normal));                // values between [ 0, +1]
        half2 octNormalWS = remappedOctNormalWS.xy * half(2.0) - half(1.0);                 // values between [-1, +1]
        rayHit.normal = half3(UnpackNormalOctQuadEncode(octNormalWS));                      // values between [-1, +1]
    #endif

        UNITY_BRANCH
        if (rayHit.insideObject == 1.0)
        {
            half3 backNormal = half3(0.0, 0.0, 0.0);
            UNITY_BRANCH
            if (_BackDepthEnabled == 2.0)
            {
                backNormal = SAMPLE_TEXTURE2D_X_LOD(_CameraBackNormalsTexture, my_point_clamp_sampler, screenUV, 0).rgb;
                if (any(backNormal))
                    rayHit.normal = -backNormal;
                else
                    rayHit.normal = -rayHit.normal;
            }
            else
                rayHit.normal = -rayHit.normal;
        }
        rayHit.smoothness = transparentGBuffer2.a;
        rayHit.emission = half3(0.0, 0.0, 0.0);

        // Enter and exit object
        rayHit.insideObject = (rayHit.insideObject == 2.0) ? 0.0 : rayHit.insideObject + 1.0;
    }
    else
    {
    #if _RENDER_PASS_ENABLED // Unused
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
        isForward = (gbuffer2.a == 0.0);
    #endif

        // URP does not clear color GBuffer (albedo & specular), only the depth & stencil.
        // This can cause smearing-like artifacts.
        rayHit.albedo = isForward ? half3(0.0, 0.0, 0.0) : gbuffer0.rgb;

        uint materialFlags = UnpackMaterialFlags(gbuffer0.a);
        UNITY_BRANCH
        if(isForward)
            rayHit.specular = half3(0.0, 0.0, 0.0);
        else // 0.04 is the "Dieletric Specular" (kDieletricSpec.rgb)
            rayHit.specular = (materialFlags == kMaterialFlagSpecularSetup) ? gbuffer1.rgb : lerp(kDieletricSpec.rgb, rayHit.albedo, gbuffer1.r); // Specular & Metallic setup conversion
        
        rayHit.normal = gbuffer2.rgb;
        
    #if defined(_GBUFFER_NORMALS_OCT)
        half2 remappedOctNormalWS = half2(Unpack888ToFloat2(rayHit.normal));                // values between [ 0, +1]
        half2 octNormalWS = remappedOctNormalWS.xy * half(2.0) - half(1.0);                 // values between [-1, +1]
        rayHit.normal = half3(UnpackNormalOctQuadEncode(octNormalWS));                      // values between [-1, +1]
    #endif     

        rayHit.emission = gbuffer3.rgb;
        rayHit.smoothness = gbuffer2.a;
        rayHit.ior = -1.0;
    }
}
//===================================================================================================================================

void SampleGGXNDF(float2   u,
    half3   V,
    half3x3 localToWorld,
    half    roughness,
    out half3   H,
    out half    NdotH,
    out half    VdotH,
    bool    VeqN = false)
{
    // GGX NDF sampling
    half cosTheta = sqrt(SafeDiv(1.0 - u.x, 1.0 + (roughness * roughness - 1.0) * u.x));
    half phi = TWO_PI * u.y;

    half3 localH = SphericalToCartesian(phi, cosTheta);

    NdotH = cosTheta;

    half3 localV;

    if (VeqN)
    {
        // localV == localN
        localV = half3(0.0, 0.0, 1.0);
        VdotH = NdotH;
    }
    else
    {
        localV = mul(V, transpose(localToWorld));
        VdotH = saturate(dot(localV, localH));
    }

    // Compute { localL = reflect(-localV, localH) }
    //half3 localL = -localV + 2.0 * VdotH * localH;
    //NdotL = localL.z;

    H = mul(localH, localToWorld);
    //L = mul(localL, localToWorld);
}

void ImportanceSampleGGX_PDF(float2   u,
    half3   V,
    half3x3 localToWorld,
    half    roughness,
    half    NdotV,
    out half3   L,
    out half    VdotH,
    out half    NdotL,
    out half    weightOverPdf)
{
    half NdotH;
    SampleGGXDir(u, V, localToWorld, roughness, L, NdotL, NdotH, VdotH);

    // TODO: should we generate a new sample if NdotL is negative?
    NdotL = saturate(NdotL);

    // Importance sampling weight for each sample
    // pdf = D(H) * (N.H) / (4 * (L.H))
    // weight = fr * (N.L) with fr = F(H) * G(V, L) * D(H) / (4 * (N.L) * (N.V))
    // weight over pdf is:
    // weightOverPdf = F(H) * G(V, L) * (L.H) / ((N.H) * (N.V))
    // weightOverPdf = F(H) * 4 * (N.L) * V(V, L) * (L.H) / (N.H) with V(V, L) = G(V, L) / (4 * (N.L) * (N.V))
    // Remind (L.H) == (V.H)
    // F is apply outside the function

    half Vis = V_SmithJointGGX(NdotL, NdotV, roughness);
    weightOverPdf = (roughness > 0.001 && NdotH > 0.0) ? 4.0 * Vis * NdotL * VdotH / NdotH : 1.0;
}

#endif