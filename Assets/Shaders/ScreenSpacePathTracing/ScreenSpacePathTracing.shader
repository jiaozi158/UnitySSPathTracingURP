Shader "Hidden/Universal Render Pipeline/Screen Space Path Tracing"
{
    Properties
    {
        [HideInInspector] _Seed("Private: Random Seed", Float) = 0.0
        [HideInInspector] [IntRange] _MaxSteps("Maximum Steps", Range(24, 64)) = 32
        [HideInInspector] _StepSize("Step Size", Range(0.01, 1)) = 0.3
        [HideInInspector] [IntRange] _MaxBounce("Maximum Bounces", Range(1, 16)) = 4
        [HideInInspector] [IntRange] _RayCount("Samples Per Pixel", Range(1, 16)) = 1
        [HideInInspector] _MaxBrightness("Maximum Brightness", Float) = 10

        [Toggle] _Dithering("Dithering", Float) = 1
        _Dither_Intensity("Intensity", Range(0.01, 2)) = 1.5
        [Toggle(_IGNORE_FORWARD_OBJECTS)]_IGNORE_FORWARD_OBJECTS("Ignore Deferred 0 smoothness", Float) = 0

        [NoScaleOffset] _OwenScrambledTexture("Owen Scrambled Texture", 2D) = "black" {}
        [NoScaleOffset] _ScramblingTileXSPP("Scrambling Tile XSPP", 2D) = "black" {}
        [NoScaleOffset] _RankingTileXSPP("Ranking Tile XSPP", 2D) = "black" {}
        
        [HideInInspector] _TemporalIntensity("Private: Temporal Intensity", Float) = 0.93
        [HideInInspector] _Sample("Current Sample", Float) = 0.0
        [HideInInspector] _MaxSample("Maximum Sample", Float) = 64.0
    }

    SubShader
    {
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            Name "Screen Space Path Tracing"
            Tags { "LightMode" = "Screen Space Path Tracing" "PreviewType" = "None" }

            Blend One Zero
			
            HLSLPROGRAM
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            // The Blit.hlsl file provides the vertex shader (Vert),
            // input structure (Attributes) and output strucutre (Varyings)
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
			
            #pragma vertex Vert
            #pragma fragment frag

            #pragma target 3.5

            #pragma multi_compile_local_fragment _ _TEMPORAL_ACCUMULATION
            #pragma multi_compile_local_fragment _METHOD_HASHED_RANDOM _METHOD_BLUE_NOISE
            #pragma multi_compile_local_fragment _ _FP_REFL_PROBE_ATLAS
            #pragma multi_compile_local_fragment _ _SUPPORT_REFRACTION
            #pragma multi_compile_local_fragment _ _BACKFACE_TEXTURES

            #pragma shader_feature_local_fragment _ _IGNORE_FORWARD_OBJECTS

            #pragma multi_compile_fragment _ _GBUFFER_NORMALS_OCT

            CBUFFER_START(UnityPerMaterial)
            half _MaxSteps;
            half _StepSize;
            half _MaxBounce;
            half _RayCount;
            half _Dither_Intensity;
            half _Dithering;
            float _Seed;
            half _TemporalIntensity;
            half _Sample;
            half _MaxSample;
            half _MaxBrightness;
            CBUFFER_END

        #ifdef _METHOD_BLUE_NOISE
            TEXTURE2D(_OwenScrambledTexture);
            //SAMPLER(sampler_OwenScrambledTexture);
            TEXTURE2D(_ScramblingTileXSPP);
            //SAMPLER(sampler_ScramblingTileXSPP);
            TEXTURE2D(_RankingTileXSPP);
            //SAMPLER(sampler_RankingTileXSPP);
            float4 _OwenScrambledTexture_TexelSize;
            float4 _ScramblingTileXSPP_TexelSize;
            float4 _RankingTileXSPP_TexelSize;
        #endif
            
        #ifndef _FP_REFL_PROBE_ATLAS
            TEXTURECUBE(_SpecCube0);
            SAMPLER(sampler_SpecCube0);
            float4 _SpecCube0_ProbePosition;
            float3 _SpecCube0_BoxMin;
            float3 _SpecCube0_BoxMax;
            half4 _SpecCube0_HDR;
            TEXTURECUBE(_SpecCube1);
            SAMPLER(sampler_SpecCube1);
            float4 _SpecCube1_ProbePosition;
            float3 _SpecCube1_BoxMin;
            float3 _SpecCube1_BoxMax;
            half4 _SpecCube1_HDR;
            half _ProbeWeight;
            half _ProbeSet;
        #endif

            half _BackDepthEnabled;
            half _IsProbeCamera;

            half _FrameIndex;

            // URP pre-defined the following variable on 2023.2+.
        #if UNITY_VERSION < 202320
            float4 _BlitTexture_TexelSize;
        #endif

            TEXTURE2D_X(_PathTracingSampleTexture);

            #include "./PathTracing.hlsl"
            
            half4 frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                float2 screenUV = input.texcoord;

			#if defined(_SUPPORT_REFRACTION)
				float depth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, my_point_clamp_sampler, screenUV, 0).r;
			#else
				float depth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, my_point_clamp_sampler, screenUV, 0).r;
			#endif
                // If the current pixel is sky
				bool isBackground = depth == UNITY_RAW_FAR_CLIP_VALUE ? true : false;

				if (isBackground)
					discard;

            #if !UNITY_REVERSED_Z
                depth = lerp(UNITY_NEAR_CLIP_VALUE, 1, depth);
            #endif

                float3 positionWS = ComputeWorldSpacePosition(screenUV, depth, UNITY_MATRIX_I_VP);
                float3 camPositionWS = GetCameraPositionWS();
                half3 viewDirWS = normalize(camPositionWS - positionWS);

                half3 result = half3(0.0, 0.0, 0.0);
                ScreenSpacePathTracing(depth, positionWS, camPositionWS, viewDirWS, screenUV, result.rgb);

				// Reduce noise and fireflies by limiting the maximum brightness
				result = RgbToHsv(result);
				result.z = clamp(result.z, 0.0, _MaxBrightness);
				result = HsvToRgb(result);

                return half4(result.rgb, 1.0);
            }
            ENDHLSL
        }

        Pass
        {
            Name "Temporal Accumulation"
			Tags { "LightMode" = "Screen Space Path Tracing" }

            Blend One Zero
			
			HLSLPROGRAM
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			// The Blit.hlsl file provides the vertex shader (Vert),
			// input structure (Attributes) and output strucutre (Varyings)
			#include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
			
			#pragma vertex Vert
			#pragma fragment accumulationFrag

            #pragma target 3.5

            #pragma multi_compile_fragment _ _GBUFFER_NORMALS_OCT
			#pragma multi_compile_local_fragment _ _SUPPORT_REFRACTION

            CBUFFER_START(UnityPerMaterial)
            half _MaxSteps;
            half _StepSize;
            half _MaxBounce;
            half _RayCount;
            half _Dither_Intensity;
            half _Dithering;
            float _Seed;
            half _TemporalIntensity;
            half _Sample;
            half _MaxSample;
			half _MaxBrightness;
            CBUFFER_END
        
            
        #ifndef _FP_REFL_PROBE_ATLAS
            TEXTURECUBE(_SpecCube0);
            SAMPLER(sampler_SpecCube0);
            float4 _SpecCube0_ProbePosition;
            float3 _SpecCube0_BoxMin;
            float3 _SpecCube0_BoxMax;
            half4 _SpecCube0_HDR;
            TEXTURECUBE(_SpecCube1);
            SAMPLER(sampler_SpecCube1);
            float4 _SpecCube1_ProbePosition;
            float3 _SpecCube1_BoxMin;
            float3 _SpecCube1_BoxMax;
            half4 _SpecCube1_HDR;
            half _ProbeWeight;
            half _ProbeSet;
        #endif

            half _BackDepthEnabled;
            half _IsProbeCamera;

            half _FrameIndex;

            float4x4 _PrevInvViewProjMatrix;
            float3 _PrevCameraPositionWS;
            half _PixelSpreadAngleTangent;

            // URP pre-defined the following variable on 2023.2+.
        #if UNITY_VERSION < 202320
            float4 _BlitTexture_TexelSize;
        #endif

            // Camera or Per Object motion vectors.
            TEXTURE2D_X(_MotionVectorTexture);
            float4 _MotionVectorTexture_TexelSize;

            TEXTURE2D_X(_PathTracingHistorySampleTexture);

            TEXTURE2D_X(_PathTracingHistoryTexture);
            TEXTURE2D_X_FLOAT(_PathTracingHistoryDepthTexture);

            TEXTURE2D_X(_PathTracingEmissionTexture);
            TEXTURE2D_X(_PathTracingHistoryEmissionTexture);

            #include "./PathTracingDenoise.hlsl"
            
            ENDHLSL
        }

        Pass
        {
            Name "Copy History Depth"
			Tags { "LightMode" = "Screen Space Path Tracing" }

            Blend One Zero
			
			HLSLPROGRAM
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			// The Blit.hlsl file provides the vertex shader (Vert),
			// input structure (Attributes) and output strucutre (Varyings)
			#include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
			
			#pragma vertex Vert
			#pragma fragment frag

            #pragma target 3.5

            CBUFFER_START(UnityPerMaterial)
            half _MaxSteps;
            half _StepSize;
            half _MaxBounce;
            half _RayCount;
            half _Dither_Intensity;
            half _Dithering;
            float _Seed;
            half _TemporalIntensity;
            half _Sample;
            half _MaxSample;
			half _MaxBrightness;
            CBUFFER_END

            // URP pre-defined the following variable on 2023.2+.
        #if UNITY_VERSION < 202320
            float4 _BlitTexture_TexelSize;
        #endif

            TEXTURE2D_X_FLOAT(_CameraDepthAttachment);
			SAMPLER(my_point_clamp_sampler);
            
            float frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                float2 screenUV = input.texcoord;

                float depth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, my_point_clamp_sampler, screenUV, 0).r;

                return depth;
            }
            ENDHLSL
        }

        Pass
		{
			Name "Offline Accumulation"
		    Tags { "LightMode" = "Screen Space Path Tracing" }

            Blend SrcAlpha OneMinusSrcAlpha

			HLSLPROGRAM
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			// The Blit.hlsl file provides the vertex shader (Vert),
			// input structure (Attributes) and output strucutre (Varyings)
			#include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

			#pragma vertex Vert
			#pragma fragment frag

			#pragma target 3.5

			SAMPLER(my_point_clamp_sampler);

			CBUFFER_START(UnityPerMaterial)
			half _MaxSteps;
            half _StepSize;
            half _MaxBounce;
            half _RayCount;
            half _Dither_Intensity;
            half _Dithering;
            float _Seed;
            half _TemporalIntensity;
            half _Sample;
            half _MaxSample;
			half _MaxBrightness;
			CBUFFER_END

			half _IsAccumulationPaused;

			half4 frag(Varyings input) : SV_Target
			{
				UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
				float2 screenUV = input.texcoord;

				half3 color = SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, my_point_clamp_sampler, screenUV, 0).rgb;

				// When object or camera moves, we should re-accumulate the pixel.
				bool restartAccumulation = (_Sample == 0.0) ? true : false;

				// Do not accumulate when reaching maximum samples allowed.
				bool pauseAccumulation = (_Sample >= _MaxSample || _IsAccumulationPaused) ? true : false;

				half finalAlpha = 1.0 / (_Sample + 1.0);

				finalAlpha = restartAccumulation ? 1.0 : finalAlpha;
				finalAlpha = pauseAccumulation ? 0.0 : finalAlpha;

				return half4(color, finalAlpha);
			}
			ENDHLSL
		}

		Pass
		{
			Name "Offline Accumulation Blit"
			Tags { "LightMode" = "Screen Space Path Tracing" }

			Blend One Zero

			HLSLPROGRAM
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			// The Blit.hlsl file provides the vertex shader (Vert),
			// input structure (Attributes) and output strucutre (Varyings)
			#include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

			#pragma vertex Vert
			#pragma fragment frag

			#pragma target 3.5

			SAMPLER(my_point_clamp_sampler);

			CBUFFER_START(UnityPerMaterial)
            half _MaxSteps;
            half _StepSize;
            half _MaxBounce;
            half _RayCount;
            half _Dither_Intensity;
            half _Dithering;
            float _Seed;
            half _TemporalIntensity;
            half _Sample;
            half _MaxSample;
			half _MaxBrightness;
            CBUFFER_END

			// From HDRP's "./Runtime/RenderPipeline/Accumulation/Shaders/Accumulation.compute"
			void AddConvergenceCue(float2 screenUV, half currentSample, inout half3 color)
			{
				// If we reached 100%, do not display the bar anymore
				if (currentSample >= _MaxSample)
					return;

				float width = _ScreenSize.x;
				float height = _ScreenSize.y;

				// Define progress bar height as 0.5% of the resolution (and at least 4 pixels high)
				float barHeight = max(4.0, ceil(height * 0.005)) * _ScreenSize.w;

				// Change color only in a region corresponding to a progress bar, at the bottom of the screen
				if (screenUV.y < barHeight && screenUV.x <= currentSample * rcp(_MaxSample))
				{
					half lum = Luminance(color);

					if (lum > 1.0)
					{
						color *= rcp(lum);
						lum = 1.0;
					}

					// Make dark color brighter, and vice versa
					color += lum > 0.5 ? -0.5 * lum : 0.05 + 0.5 * lum;
				}
			}

			half4 frag(Varyings input) : SV_Target
			{
				UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
				float2 screenUV = input.texcoord;

				half3 color = SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, my_point_clamp_sampler, screenUV, 0).rgb;
				AddConvergenceCue(screenUV, _Sample, color);
				return half4(color, 1.0);
			}
			ENDHLSL
		}

        Pass
		{
			Name "Edge-Avoiding Spatial Denoise"
			Tags { "LightMode" = "Screen Space Path Tracing" }

			Blend One Zero

			HLSLPROGRAM
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			// The Blit.hlsl file provides the vertex shader (Vert),
			// input structure (Attributes) and output strucutre (Varyings)
			#include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
			#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonLighting.hlsl"

			#include "./PathTracingConfig.hlsl"

			#pragma vertex Vert
			#pragma fragment frag

			#pragma multi_compile_local_fragment _ _SUPPORT_REFRACTION // _TRANSPARENT_GBUFFERS

			TEXTURE2D_X_FLOAT(_CameraDepthAttachment);

			TEXTURE2D_X_HALF(_GBuffer0);
			TEXTURE2D_X_HALF(_GBuffer2);

			TEXTURE2D_X_HALF(_TransparentGBuffer0);
			TEXTURE2D_X_HALF(_TransparentGBuffer1);
			TEXTURE2D_X_HALF(_TransparentGBuffer2);
			SAMPLER(my_point_clamp_sampler);

			TEXTURE2D_X(_PathTracingEmissionTexture);
			TEXTURE2D_X(_PathTracingSampleTexture);
		
			CBUFFER_START(UnityPerMaterial)
            half _MaxSteps;
            half _StepSize;
            half _MaxBounce;
            half _RayCount;
            half _Dither_Intensity;
            half _Dithering;
            float _Seed;
            half _TemporalIntensity;
            half _Sample;
            half _MaxSample;
			half _MaxBrightness;
            CBUFFER_END

			// URP pre-defined the following variable on 2023.2+.
        #if UNITY_VERSION < 202320
            float4 _BlitTexture_TexelSize;
        #endif

			float GetSpecularDominantFactor(float NoV, float linearRoughness)
			{
				float a = 0.298475 * log(39.4115 - 39.0029 * linearRoughness);
				float dominantFactor = pow(saturate(1.0 - NoV), 10.8649) * (1.0 - a) + a;
				return saturate(dominantFactor);
			}

			half4 frag(Varyings input) : SV_Target
			{
				// Edge-Avoiding A-TrousWavelet Transform for denoising
				// Modified from "https://www.shadertoy.com/view/ldKBzG"
				// feel free to use it

				UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
				float2 screenUV = input.texcoord;

				// Dynamic dilation rate
				// This reduces repetitive artifacts of A-Trous filtering.
				
				half blurAmount = 1.0 - saturate(min(SAMPLE_TEXTURE2D_X_LOD(_PathTracingSampleTexture, my_point_clamp_sampler, screenUV, 0).r / MAX_ACCUM_FRAME_NUM, MAX_ACCUM_FRAME_NUM) - rcp(MAX_ACCUM_FRAME_NUM));
				if (blurAmount == 0.0)
					discard;
				
				half intensity = floor(lerp(3.0, 9.0, GenerateHashedRandomFloat(uint3(screenUV * _ScreenSize.xy, 1))));
				//intensity *= (1.0 - historySample);
				// 3x3 gaussian kernel texel offset
				const half2 offset[9] =
				{
					half2(-1.0, -1.0), half2(0.0, -1.0), half2(1.0, -1.0),  // offset[0]..[2]
					half2(-1.0, 0.0), half2(0.0, 0.0), half2(1.0, 0.0),     // offset[3]..[5]
					half2(-1.0, 1.0), half2(0.0, 1.0), half2(1.0, 1.0)      // offset[6]..[8]
				};

				// 3x3 approximate gaussian kernel
				const half kernel[9] =
				{
					half(0.0625), half(0.125), half(0.0625),  // kernel[0]..[2]
					half(0.125), half(0.25), half(0.125),     // kernel[3]..[5]
					half(0.0625), half(0.125), half(0.0625)   // kernel[6]..[8]
				};

				// URP doesn't clear color targets of GBuffers, only depth and stencil.
				float deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, my_point_clamp_sampler, screenUV, 0).r;
				bool isSky;
				#if (UNITY_REVERSED_Z == 1)
					isSky = deviceDepth == 0.0;
				#else
					isSky = deviceDepth == 1.0; // OpenGL Platforms.
				#endif

				UNITY_BRANCH
				if (isSky)
				{
					return SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, my_point_clamp_sampler, screenUV, 0);
				}
				else
				{
					bool transparentGBuffers = false;
				#if defined(_SUPPORT_REFRACTION)
					uint surfaceType = uint((SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer1, my_point_clamp_sampler, screenUV, 0).a * 255.0h) + 0.5h);
					transparentGBuffers = surfaceType == 2;
				#endif

					half3 centerColor = SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, my_point_clamp_sampler, screenUV, 0).rgb;
					half3 centerEmission = half3(0.0, 0.0, 0.0);
					UNITY_BRANCH
					if (!transparentGBuffers)
						centerEmission = SAMPLE_TEXTURE2D_X_LOD(_PathTracingEmissionTexture, my_point_clamp_sampler, screenUV, 0).rgb;

					half4 normalSmoothness;
					half3 centerNormal;
					half3 centerAlbedo;
					UNITY_BRANCH
					if (transparentGBuffers)
					{
						normalSmoothness = SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer2, my_point_clamp_sampler, screenUV, 0).rgba;
						if (!any(normalSmoothness.rgb))
							normalSmoothness = SAMPLE_TEXTURE2D_X_LOD(_GBuffer2, my_point_clamp_sampler, screenUV, 0).rgba;
						centerAlbedo = SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer0, my_point_clamp_sampler, screenUV, 0).rgb;
						if (!any(centerAlbedo))
							centerAlbedo = SAMPLE_TEXTURE2D_X_LOD(_GBuffer0, my_point_clamp_sampler, screenUV, 0).rgb;
					}
					else
					{
						normalSmoothness = SAMPLE_TEXTURE2D_X_LOD(_GBuffer2, my_point_clamp_sampler, screenUV, 0).rgba;
						centerAlbedo = SAMPLE_TEXTURE2D_X_LOD(_GBuffer0, my_point_clamp_sampler, screenUV, 0).rgb;
					}

					centerNormal = normalSmoothness.rgb;

					float3 positionWS = ComputeWorldSpacePosition(screenUV, deviceDepth, UNITY_MATRIX_I_VP);

					half3 viewDirWS = normalize(GetCameraPositionWS() - positionWS);

					// Convert both directions to view space
					half NdotV = abs(dot(normalSmoothness.xyz, viewDirWS));
					float amount = GetSpecularDominantFactor(NdotV, 1.0 - normalSmoothness.w);

					half3 sumColor = half3(0.0, 0.0, 0.0);
					half sumWeight = half(0.0);
					for (uint i = 0; i < 9; i++)
					{
						float2 uv = clamp(screenUV + offset[i] * intensity * _BlitTexture_TexelSize.xy, float2(0.0, 0.0), _BlitTexture_TexelSize.zw);

						half3 color = SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, my_point_clamp_sampler, uv, 0).rgb;
						half3 diff = centerColor - color;
						half distance = dot(diff, diff);
						half colorWeight = min(exp(-distance * 1.1), 1.0); // rcp(0.9)

						half emissionWeight = half(1.0);
						UNITY_BRANCH
						if (!transparentGBuffers)
						{
							half3 emission = SAMPLE_TEXTURE2D_X_LOD(_PathTracingEmissionTexture, my_point_clamp_sampler, uv, 0).rgb;
							diff = centerEmission - emission;
							distance = dot(diff, diff);
							emissionWeight = min(exp(-distance * 2000.0), 1.0); // rcp(0.0005)
						}

						half3 normal;
						UNITY_BRANCH
						if (transparentGBuffers)
						{
							normal = SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer2, my_point_clamp_sampler, uv, 0).rgb;
							if (!any(normal))
								normal = SAMPLE_TEXTURE2D_X_LOD(_GBuffer2, my_point_clamp_sampler, uv, 0).rgb;
						}
						else
							normal = SAMPLE_TEXTURE2D_X_LOD(_GBuffer2, my_point_clamp_sampler, uv, 0).rgb;

						diff = centerNormal - normal;
						distance = max(dot(diff, diff), 0.0);
						half normalWeight = min(exp(-distance * 20.0), 1.0); // rcp(0.05)

						half3 albedo;
						UNITY_BRANCH
						if (transparentGBuffers)
						{ 
							albedo = SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer0, my_point_clamp_sampler, uv, 0).rgb;
							if (!any(albedo))
								albedo = SAMPLE_TEXTURE2D_X_LOD(_GBuffer0, my_point_clamp_sampler, uv, 0).rgb;
						}
						else
							albedo = SAMPLE_TEXTURE2D_X_LOD(_GBuffer0, my_point_clamp_sampler, uv, 0).rgb;

						diff = sqrt(centerAlbedo) - sqrt(albedo);
						distance = dot(diff, diff);
						half albedoWeight = min(exp(-distance * 400.0), 1.0); // rcp(0.0025)

						half weight = colorWeight * emissionWeight * normalWeight * albedoWeight * kernel[i];

						sumColor += color * weight;
						sumWeight += weight;
					}

					blurAmount = 1.0 - blurAmount;
					blurAmount *= blurAmount;
					blurAmount *= blurAmount;
					blurAmount = 1.0 - blurAmount;
					//return half4(lerp(centerColor, sumColor * rcp(sumWeight), blurAmount * (1.0 - amount)), 1.0);
					return half4(lerp(centerColor, sumColor * rcp(sumWeight), blurAmount), 1.0);
					//return blurAmount.xxxx;
				}
			}
			ENDHLSL
		}

		Pass
		{
			Name "Copy History Emission"
			Tags { "LightMode" = "Screen Space Path Tracing" }

			Blend One Zero

			HLSLPROGRAM
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			// The Blit.hlsl file provides the vertex shader (Vert),
			// input structure (Attributes) and output strucutre (Varyings)
			#include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

			#pragma vertex Vert
			#pragma fragment frag

			#pragma target 3.5

			TEXTURE2D_X(_PathTracingEmissionTexture);
			SAMPLER(my_point_clamp_sampler);

			CBUFFER_START(UnityPerMaterial)
            half _MaxSteps;
            half _StepSize;
            half _MaxBounce;
            half _RayCount;
            half _Dither_Intensity;
            half _Dithering;
            float _Seed;
            half _TemporalIntensity;
            half _Sample;
            half _MaxSample;
			half _MaxBrightness;
            CBUFFER_END

			half4 frag(Varyings input) : SV_Target
			{
				UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
				float2 screenUV = input.texcoord;

				return SAMPLE_TEXTURE2D_X_LOD(_PathTracingEmissionTexture, my_point_clamp_sampler, screenUV, 0).rgba;
			}
			ENDHLSL
		}
    }
}
