#ifndef URP_SCREEN_SPACE_PATH_TRACING_DENOISE_HLSL
#define URP_SCREEN_SPACE_PATH_TRACING_DENOISE_HLSL

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
#include "./PathTracingUtilities.hlsl"
#include "./PathTracingConfig.hlsl"

half ComputeMaxReprojectionWorldRadius(float3 positionWS, half3 viewDirWS, half3 normalWS, half pixelSpreadAngleTangent, half maxDistance, half pixelTolerance)
{
    //const float3 viewWS = GetWorldSpaceNormalizeViewDir(positionWS);
    half parallelPixelFootPrint = pixelSpreadAngleTangent * length(positionWS);
    half realPixelFootPrint = parallelPixelFootPrint / max(abs(dot(normalWS, viewDirWS)), PROJECTION_EPSILON);
    return max(maxDistance, realPixelFootPrint * pixelTolerance);
}

half ComputeMaxReprojectionWorldRadius(float3 positionWS, half3 viewDirWS, half3 normalWS, half pixelSpreadAngleTangent)
{
    return ComputeMaxReprojectionWorldRadius(positionWS, viewDirWS, normalWS, pixelSpreadAngleTangent, MAX_REPROJECTION_DISTANCE, MAX_PIXEL_TOLERANCE);
}

// From Playdead's TAA
// (half version of HDRP impl)
half3 SampleColorPoint(Texture2D _BlitTexture, float2 uv, float2 texelOffset)
{
    return SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, my_point_clamp_sampler, uv + _BlitTexture_TexelSize.xy * texelOffset, 0).xyz;
}

void AdjustColorBox(inout half3 boxMin, inout half3 boxMax, inout half3 moment1, inout half3 moment2, float2 uv, half currX, half currY)
{
    half3 color = SampleColorPoint(_BlitTexture, uv, float2(currX, currY));
    boxMin = min(color, boxMin);
    boxMax = max(color, boxMax);
    moment1 += color;
    moment2 += color * color;
}

void AdjustHistoryColorBox(inout half3 boxMin, inout half3 boxMax, inout half3 moment1, inout half3 moment2, float2 uv, half currX, half currY)
{
    half3 color = SampleColorPoint(_PathTracingHistoryTexture, uv, float2(currX, currY));
    boxMin = min(color, boxMin);
    boxMax = max(color, boxMax);
    moment1 += color;
    moment2 += color * color;
}

half3 DirectClipToAABB(half3 history, half3 minimum, half3 maximum)
{
    // note: only clips towards aabb center (but fast!)
    half3 center = 0.5 * (maximum + minimum);
    half3 extents = 0.5 * (maximum - minimum);

    // This is actually `distance`, however the keyword is reserved
    half3 offset = history - center;
    half3 v_unit = offset.xyz / extents.xyz;
    half3 absUnit = abs(v_unit);
    half maxUnit = Max3(absUnit.x, absUnit.y, absUnit.z);
    if (maxUnit > 1.0)
        return center + (offset / maxUnit);
    else
        return history;
}

half ComputeParallax(half3 currentViewWS, float3 previousPositionWS)
{
    // Compute the previous view vector
    half3 previousViewWS = normalize(_PrevCameraPositionWS - previousPositionWS);

    // Compute the cosine between both angles
    half cosa = saturate(dot(currentViewWS, previousViewWS));

    // Evaluate the tangent of the angle
    return sqrt(1.0 - cosa * cosa) / max(cosa, 1e-6);
}

half GetSpecAccumSpeed(half linearRoughness, half NoV, half parallax)
{
    half acos01sq = 1.0 - NoV; // Approximation of acos^2 in normalized
    half a = pow(saturate(acos01sq), SPEC_ACCUM_CURVE);
    half b = 1.1 + linearRoughness * linearRoughness;
    half parallaxSensitivity = (b + a) / (b - a);
    half powerScale = 1.0 + parallax * parallaxSensitivity;
    half f = 1.0 - exp2(-200.0 * linearRoughness * linearRoughness);
    f *= pow(saturate(linearRoughness), SPEC_ACCUM_BASE_POWER * powerScale);
    return MAX_ACCUM_FRAME_NUM * f;
}

half GetSpecularDominantFactor(half NoV, half linearRoughness)
{
    half a = 0.298475 * log(39.4115 - 39.0029 * linearRoughness);
    half dominantFactor = pow(saturate(1.0 - NoV), 10.8649) * (1.0 - a) + a;
    return saturate(dominantFactor);
}

float3 GetVirtualPosition(float3 positionWS, half3 viewWS, half NoV, half roughness, half hitDist)
{
    half f = GetSpecularDominantFactor(NoV, roughness);
    return positionWS - viewWS * hitDist * f;
}

float2 EvaluateVirtualMotionUV(float3 virtualPositionWS)
{
    // Compute the previous frame's uv for reprojection
    float4 prevHClip = mul(_PrevViewProjMatrix, float4(virtualPositionWS, 1.0));
    prevHClip.xyz /= prevHClip.w;
#if UNITY_UV_STARTS_AT_TOP
    prevHClip.y *= -1.0;
#endif
    return prevHClip.xy * 0.5 + 0.5;
}

void accumulationFrag(Varyings input, out half4 denoiseOutput : SV_Target0, out half currentSample : SV_Target1)
{
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
    float2 screenUV = input.texcoord;

    half2 velocity = SAMPLE_TEXTURE2D_X_LOD(_MotionVectorTexture, sampler_LinearClamp, screenUV, 0).xy;
    float2 prevUV = screenUV - velocity;

    float deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, my_point_clamp_sampler, screenUV, 0).r;
    float prevDeviceDepth = SAMPLE_TEXTURE2D_X_LOD(_PathTracingHistoryDepthTexture, my_point_clamp_sampler, prevUV, 0).r;

#if defined(_SUPPORT_REFRACTION)
    uint surfaceType = UnpackMaterialFlags(SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer1, my_point_clamp_sampler, screenUV, 0).a);
    half4 normalSmoothness;
    UNITY_BRANCH
    if (surfaceType == 2)
        normalSmoothness = SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer2, my_point_clamp_sampler, screenUV, 0).xyzw;
    else
        normalSmoothness = SAMPLE_TEXTURE2D_X_LOD(_GBuffer2, my_point_clamp_sampler, screenUV, 0).xyzw;
#else
    half4 normalSmoothness = SAMPLE_TEXTURE2D_X_LOD(_GBuffer2, my_point_clamp_sampler, screenUV, 0).xyzw;
#endif

    // Fetch the current and history values and apply the exposition to it.
    half4 currentColor = SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, sampler_LinearClamp, screenUV, 0).rgba;

#if defined(_GBUFFER_NORMALS_OCT)
    half2 remappedOctNormalWS = half2(Unpack888ToFloat2(normalSmoothness.xyz));                // values between [ 0, +1]
    half2 octNormalWS = remappedOctNormalWS.xy * half(2.0) - half(1.0);                        // values between [-1, +1]
    normalSmoothness.xyz = half3(UnpackNormalOctQuadEncode(octNormalWS));                      // values between [-1, +1]
#endif 

    bool isSky = deviceDepth == UNITY_RAW_FAR_CLIP_VALUE? true : false;

    bool canBeReprojected = true;
    if (isSky || prevUV.x > 1.0 || prevUV.x < 0.0 || prevUV.y > 1.0 || prevUV.y < 0.0)
    {
        canBeReprojected = false;
    }

    float3 positionWS = ComputeWorldSpacePosition(screenUV, deviceDepth, UNITY_MATRIX_I_VP);
    float3 prevPositionWS = ComputeWorldSpacePosition(prevUV, prevDeviceDepth, _PrevInvViewProjMatrix); //UNITY_MATRIX_PREV_I_VP);

    half3 viewDirWS = normalize(GetCameraPositionWS() - positionWS);

    // Convert both directions to view space
    half NdotV = abs(dot(normalSmoothness.xyz, viewDirWS));

    // Evaluate the parallax
    half paralax = ComputeParallax(viewDirWS, prevPositionWS);

    // Compute the previous virtual position
    float3 virtualPositionWS = GetVirtualPosition(positionWS, viewDirWS, NdotV, 1.0 - normalSmoothness.w, length(positionWS));

    // Compute the previous frame's uv for reprojection
    float2 historyVirtualUV = EvaluateVirtualMotionUV(virtualPositionWS);

    // Re-projected color from last frame.
    half historySample = SAMPLE_TEXTURE2D_X_LOD(_PathTracingHistorySampleTexture, sampler_LinearClamp, prevUV, 0).r;

    // Compute the max world radius that we consider acceptable for history reprojection
    half maxRadius = ComputeMaxReprojectionWorldRadius(positionWS, viewDirWS, normalSmoothness.xyz, _PixelSpreadAngleTangent);
    half radius = length(prevPositionWS - positionWS) / maxRadius;

    // Is it too far from the current position?
    if (radius > 1.0)
    {
        canBeReprojected = false;
    }

    half emissionDiff = 1.0;
    if (canBeReprojected)
    {
        half3 emission = SAMPLE_TEXTURE2D_X_LOD(_PathTracingEmissionTexture, my_point_clamp_sampler, screenUV, 0).rgb;
        
        half3 prevEmission = SAMPLE_TEXTURE2D_X_LOD(_PathTracingHistoryEmissionTexture, my_point_clamp_sampler, prevUV, 0).rgb;
        half3 emissionDifference = emission - prevEmission;

        half emissionLuma = Luminance(emission);
        half prevEmissionLuma = Luminance(prevEmission);
        emissionDiff = 1.0 - abs(emissionLuma - prevEmissionLuma) / Max3(emissionLuma, prevEmissionLuma, 0.2);
        emissionDiff *= emissionDiff;

    }
    if (emissionDiff < 0.5)
        canBeReprojected = false;

    // Depending on the roughness of the surface run one or the other temporal reprojection
    half3 result;
    if ((1.0 - normalSmoothness.w) > ROUGHNESS_ACCUMULATION_THRESHOLD && emissionDiff > 0.5)
    {
        half sampleCount = historySample;

        if (canBeReprojected && sampleCount != 0.0)
        {
            // Color Variance
            half3 boxMax = currentColor.rgb;
            half3 boxMin = currentColor.rgb;
            half3 moment1 = currentColor.rgb;
            half3 moment2 = currentColor.rgb * currentColor.rgb;

            // adjacent pixels
            AdjustColorBox(boxMin, boxMax, moment1, moment2, screenUV, 0.0, -1.0);
            AdjustColorBox(boxMin, boxMax, moment1, moment2, screenUV, -1.0, 0.0);
            AdjustColorBox(boxMin, boxMax, moment1, moment2, screenUV, 1.0, 0.0);
            AdjustColorBox(boxMin, boxMax, moment1, moment2, screenUV, 0.0, 1.0);
            
            // Compute amount of virtual motion.
            half amount = GetSpecularDominantFactor(NdotV, 1.0 - normalSmoothness.w);
            // Clip history samples
            half aggressivelyClampedHistoryLuma = 0.0;

            half4 prevColor = SAMPLE_TEXTURE2D_X_LOD(_PathTracingHistoryTexture, sampler_LinearClamp, prevUV, 0).rgba;

            half accumulationFactor = (sampleCount >= MAX_ACCUM_FRAME_NUM ? _TemporalIntensity : (sampleCount / (sampleCount + 1.0))) * max(emissionDiff, 0.1) * (1.0 - radius);
            result = (currentColor.rgb * (1.0 - accumulationFactor) + prevColor.rgb * accumulationFactor);

            sampleCount = clamp(sampleCount + 1.0, 0.0, MAX_ACCUM_FRAME_NUM);
        }
        else
        {
            result = currentColor.rgb;
            sampleCount = 1.0;
        }

        // Update the sample count
        historySample = sampleCount;
    }
    else
    {
        float2 offsetUV = _BlitTexture_TexelSize.xy;
        half3 topLeft = SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, sampler_LinearClamp, clamp(screenUV - offsetUV, float2(0.0, 0.0), _BlitTexture_TexelSize.zw), 0).rgb;
        half3 bottomRight = SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, sampler_LinearClamp, clamp(screenUV + offsetUV, float2(0.0, 0.0), _BlitTexture_TexelSize.zw), 0).rgb;

        half3 corners = 4.0 * (topLeft + bottomRight) - 2.0 * currentColor.rgb;

        half3 color = clamp(currentColor.rgb, 0.0, CLAMP_MAX);

        half3 average = (corners + color) / 7.0;

        half colorLuma = Luminance(color);
        half averageLuma = Luminance(average);
        half velocityLength = length(velocity);
        half nudge = lerp(4.0, 0.25, saturate(velocityLength * 100.0)) * abs(averageLuma - colorLuma);

        half3 minimum = min(bottomRight, topLeft) - nudge;
        half3 maximum = max(topLeft, bottomRight) + nudge;

        // Compute the previous virtual position
        float3 virtualPositionWS = GetVirtualPosition(positionWS, viewDirWS, NdotV, 1.0 - normalSmoothness.w, length(positionWS));

        // Compute the previous frame's uv for reprojection
        float2 historyVirtualUV = EvaluateVirtualMotionUV(virtualPositionWS);

        half4 prevColor = SAMPLE_TEXTURE2D_X_LOD(_PathTracingHistoryTexture, sampler_LinearClamp, historyVirtualUV, 0).rgba;

        // Clip history samples
        prevColor.rgb = DirectClipToAABB(prevColor.rgb, minimum, maximum);

        // Blend color & history
        // Feedback weight from unbiased luminance diff (Timothy Lottes)
        half historyLuma = Luminance(prevColor.rgb);
        half diff = abs(colorLuma - historyLuma) / Max3(colorLuma, historyLuma, 0.2);
        half weight = 1.0 - diff;
        const half feedbackMin = 0.96;
        const half feedbackMax = 0.91;
        half feedback = lerp(feedbackMin, feedbackMax, weight * weight);

        // Evaluate the theorical accumulation speed
        half accumulationFactor = GetSpecAccumSpeed(lerp(max(1.0 - normalSmoothness.w, 0.06), 0.0, weight * weight), NdotV, paralax);

        // Cap the accumulation factor with the history one
        accumulationFactor = (historySample + 1.0) >= MAX_ACCUM_FRAME_NUM ? _TemporalIntensity : saturate(min(min(accumulationFactor, (historySample + 1.0) / MAX_ACCUM_FRAME_NUM), MAX_ACCUM_FRAME_NUM));
        color = lerp(color, prevColor.rgb, accumulationFactor);

        result = canBeReprojected ? clamp(color, 0.0, CLAMP_MAX) : currentColor.rgb;
        historySample = canBeReprojected ? clamp(historySample + 1.0, 0.0, MAX_ACCUM_FRAME_NUM) : 1.0;
    }

    denoiseOutput = half4(result, currentColor.a);
    //denoiseOutput = half4(historySample.xxx * rcp(MAX_ACCUM_FRAME_NUM) - rcp(MAX_ACCUM_FRAME_NUM), currentColor.a); // Debug sample count
    currentSample = historySample;
    return;
}

#endif