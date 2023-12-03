#ifndef URP_SCREEN_SPACE_PATH_TRACING_UTILITIES_HLSL
#define URP_SCREEN_SPACE_PATH_TRACING_UTILITIES_HLSL

// Helper functions
//===================================================================================================================================
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/BRDF.hlsl"

#ifndef kDielectricSpec
#define kDielectricSpec half4(0.04, 0.04, 0.04, 1.0 - 0.04) // standard dielectric reflectivity coef at incident angle (= 4%)
#endif

uint UnpackMaterialFlags(float packedMaterialFlags)
{
    return uint((packedMaterialFlags * 255.0h) + 0.5h);
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
#if defined(_METHOD_BLUE_NOISE)
    return GetBNDSequenceSample(uint2(screenUV * _ScreenSize.xy), time, _Seed);
#else
    return GenerateHashedRandomFloat(uint3(screenUV * _ScreenSize.xy, time + _Seed));
#endif
}

void HitSurfaceDataFromGBuffer(float2 screenUV, inout half3 albedo, inout half3 specular, inout half3 normal, inout half3 emission, inout half smoothness, inout half ior, inout half insideObject)
{
#if defined(_FOVEATED_RENDERING_NON_UNIFORM_RASTER)
    screenUV = (screenUV * 2.0 - 1.0) * _ScreenSize.zw;
#endif

    half4 transparentGBuffer1 = half4(0.0, 0.0, 0.0, 1.0);
    uint surfaceType = 0;
    bool isTransparentGBuffer = (insideObject != 2.0 && _SupportRefraction == 1.0);
    UNITY_BRANCH
    if (isTransparentGBuffer)
    {
        transparentGBuffer1 = SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer1, my_point_clamp_sampler, screenUV, 0);
        surfaceType = UnpackMaterialFlags(transparentGBuffer1.a);
    }
    UNITY_BRANCH
    if (surfaceType == 2 && isTransparentGBuffer)
    {
        half4 transparentGBuffer0 = SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer0, my_point_clamp_sampler, screenUV, 0);
        half4 transparentGBuffer2 = SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer2, my_point_clamp_sampler, screenUV, 0);
        albedo = transparentGBuffer0.rgb;
        specular = kDieletricSpec.rgb;
        ior = transparentGBuffer1.r * 2.0h + 0.921875h;
        normal = transparentGBuffer2.rgb;
        UNITY_BRANCH
        if (_GBUFFER_NORMALS_OCT_ON == true)
        {
            half2 remappedOctNormalWS = half2(Unpack888ToFloat2(normal));                // values between [ 0, +1]
            half2 octNormalWS = remappedOctNormalWS.xy * half(2.0) - half(1.0);          // values between [-1, +1]
            normal = half3(UnpackNormalOctQuadEncode(octNormalWS));                      // values between [-1, +1]
        }
        UNITY_BRANCH
        if (insideObject == 1.0)
        {
            half3 backNormal = half3(0.0, 0.0, 0.0);
            UNITY_BRANCH
            if (_BackDepthEnabled == 2.0)
            {
                backNormal = SAMPLE_TEXTURE2D_X_LOD(_CameraBackNormalsTexture, my_point_clamp_sampler, screenUV, 0).rgb;
                if (any(backNormal))
                    normal = -backNormal;
            }
            else
                normal = -normal;
        }
        smoothness = transparentGBuffer2.a;
        emission = half3(0.0, 0.0, 0.0);

        // Enter and exit object
        insideObject = (insideObject == 2.0) ? 0.0 : insideObject + 1.0;
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
        albedo = isForward ? half3(0.0, 0.0, 0.0) : gbuffer0.rgb;

        uint materialFlags = UnpackMaterialFlags(gbuffer0.a);
        UNITY_BRANCH
        if(isForward)
            specular = half3(0.0, 0.0, 0.0);
        else // 0.04 is the "Dieletric Specular" (kDieletricSpec.rgb)
            specular = (materialFlags == kMaterialFlagSpecularSetup) ? gbuffer1.rgb : lerp(kDieletricSpec.rgb, max(albedo, kDieletricSpec.rgb), gbuffer1.r); // Specular & Metallic setup conversion
        
        normal = gbuffer2.rgb;
        UNITY_BRANCH
        if (_GBUFFER_NORMALS_OCT_ON == true)
        {
            half2 remappedOctNormalWS = half2(Unpack888ToFloat2(gbuffer2.rgb));          // values between [ 0, +1]
            half2 octNormalWS = remappedOctNormalWS.xy * half(2.0) - half(1.0);          // values between [-1, +1]
            normal = half3(UnpackNormalOctQuadEncode(octNormalWS));                      // values between [-1, +1]
        }       

        emission = gbuffer3.rgb;
        smoothness = gbuffer2.a;
        ior = -1.0;
    }
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

// [Under easiest license] Modified from "https://github.com/tuxalin/vulkanri/blob/master/examples/pbr_ibl/shaders/importanceSampleGGX.glsl".
// GGX NDF via importance sampling
// 
// It modifies the normal direction based on surface smoothness.
half3 ImportanceSampleGGX(float2 random, half3 normal, half smoothness)
{
    half roughness = (1.0 - smoothness); // This requires perceptual roughness, not roughness [(1.0 - smoothness) * (1.0 - smoothness)].
    half alpha = roughness * roughness;
    half alpha2 = alpha * alpha;

    half phi = TWO_PI * random.x;
    half cosTheta = sqrt((1.0 - random.y) / (1.0 + (alpha2 - 1.0) * random.y));
    half sinTheta = sqrt(1.0 - cosTheta * cosTheta);

    // from spherical coordinates to cartesian coordinates
    half3 H;
    H.x = cos(phi) * sinTheta;
    H.y = sin(phi) * sinTheta;
    H.z = cosTheta;

    // from tangent-space vector to world-space sample vector
    half3 up = abs(normal.z) < 0.999 ? half3(0.0, 0.0, 1.0) : half3(1.0, 0.0, 0.0);
    half3 tangent = normalize(cross(up, normal));
    half3 bitangent = cross(normal, tangent);

    half3 sampleVec = tangent * H.x + bitangent * H.y + normal * H.z;
    return normalize(sampleVec);
}

struct GGX
{
    half3 direction;
    half  weight;
};

// From HDRP
GGX ImportanceSampleGGX_PDF(float2 screenUV, half3 normalWS, half3 viewDirWS, half smoothness)
{
    GGX ggx;

    half roughness = (1.0 - smoothness);
    roughness = roughness * roughness;

    half3x3 localToWorld = GetLocalFrame(normalWS);

    half3 sampleDir = half3(0.0, 0.0, 0.0);
    half NdotL, NdotH, VdotH;
    float2 random;

    random.x = GenerateRandomValue(screenUV);
    random.y = GenerateRandomValue(screenUV);

    SampleGGXDir(random, viewDirWS, localToWorld, roughness, ggx.direction, NdotL, NdotH, VdotH);

    // Try generating a new one if it's under the surface
    for (int i = 1; i < 4; ++i)
    {
        if (dot(ggx.direction, normalWS) >= 0.0)
            break;

        random.x = GenerateRandomValue(screenUV);
        random.y = GenerateRandomValue(screenUV);

        SampleGGXDir(random, viewDirWS, localToWorld, roughness, ggx.direction, NdotL, NdotH, VdotH);
    }

    //half NdotV = dot(normalWS, viewDirWS);
    //half Vis = V_SmithJointGGX(NdotL, NdotV, roughness);
    //ggx.weight = roughness > 0.001 ? 4.0 * Vis * NdotL * VdotH / NdotH : 1.0;
    ggx.weight = 1.0;
    
    return ggx;
}

#endif