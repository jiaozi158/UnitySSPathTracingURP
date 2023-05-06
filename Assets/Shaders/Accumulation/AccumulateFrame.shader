Shader "Hidden/AccumulateFrame"
{
	Properties
	{
		[HideInInspector] _MainTex("_MainTex", 2D) = "white" {}
		[HideInInspector] _Sample("Total Sample", Float) = 0.0
		[HideInInspector] _MaxSample("Maximum Sample", Float) = 64.0
		[HideInInspector] _DenoiserIntensity("Denoiser Intensity", Float) = 0.5
		[HideInInspector] _TransparentGBuffers("Additional Lighting Models", Float) = 0.0
		[HideInInspector] _UseOpaqueTexture("Denoiser Use Opaque Texture", Float) = 0.0
	}

	SubShader
	{
		// No culling or depth
		Cull Off ZWrite Off ZTest Always
		Blend SrcAlpha OneMinusSrcAlpha

		Pass
		{
			Name "Offline Accumulation"
		    Tags { "LightMode" = "Offline Accumulation" }

			HLSLPROGRAM
			#pragma vertex vert
			#pragma fragment frag

			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

			TEXTURE2D(_MainTex);
			SAMPLER(my_point_clamp_sampler);

			CBUFFER_START(UnityPerMaterial)
			half _Sample;
			half _MaxSample;
			half _DenoiserIntensity;
			half _TransparentGBuffers;
			half _UseOpaqueTexture;
			float4 _MainTex_TexelSize;
			CBUFFER_END

			struct Attributes
			{
				float4 positionOS : POSITION;
				float2 uv : TEXCOORD0;
			};

			struct Varyings
			{
				float4 positionCS : SV_POSITION;
				float2 uv : TEXCOORD0;
			};

			Varyings vert(Attributes input)
			{
				Varyings output;
				output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
				output.uv = input.uv;
				return output;
			}

			half4 frag(Varyings input) : SV_Target
			{
				half3 color = SAMPLE_TEXTURE2D_LOD(_MainTex, my_point_clamp_sampler, input.uv, 0).rgb;

				// When object or camera moves, we should re-accumulate the pixel.
				bool reAccumulate = (_Sample == 0.0) ? true : false;

				if (reAccumulate)
					return half4(color, 1.0);
				else if (_Sample >= _MaxSample) // Do not accumulate when reaching maximum samples allowed.
					return half4(color, 0.0);
				else
					return half4(color, (1.0 / (_Sample + 1.0)));
			}
			ENDHLSL
		}

		Pass
		{
			Name "Accumulation Blit"
			Tags { "LightMode" = "Accumulation Blit" }

			Blend One Zero

			HLSLPROGRAM
			#pragma vertex vert
			#pragma fragment frag

			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"

			TEXTURE2D(_MainTex);
			SAMPLER(my_point_clamp_sampler);

			CBUFFER_START(UnityPerMaterial)
			half _Sample;
			half _MaxSample;
			half _DenoiserIntensity;
			half _TransparentGBuffers;
			half _UseOpaqueTexture;
			float4 _MainTex_TexelSize;
			CBUFFER_END

			struct Attributes
			{
				float4 positionOS : POSITION;
				float2 uv : TEXCOORD0;
			};

			struct Varyings
			{
				float4 positionCS : SV_POSITION;
				float2 uv : TEXCOORD0;
			};

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

			Varyings vert(Attributes input)
			{
				Varyings output;
				output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
				output.uv = input.uv;
				return output;
			}

			half4 frag(Varyings input) : SV_Target
			{
				half3 color = SAMPLE_TEXTURE2D_LOD(_MainTex, my_point_clamp_sampler, input.uv, 0).rgb;
				AddConvergenceCue(input.uv, _Sample, color);
				return half4(color, 1.0);
			}
			ENDHLSL
		}

		Pass
		{
			Name "Real-time Accumulation"
		    Tags { "LightMode" = "Real-time Accumulation" }

			// No culling or depth
			Cull Off ZWrite Off ZTest Always
			Blend SrcAlpha OneMinusSrcAlpha

			HLSLPROGRAM
			#pragma vertex vert
			#pragma fragment frag

			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"

			CBUFFER_START(UnityPerMaterial)
			half _Sample;
			half _MaxSample;
			half _DenoiserIntensity;
			half _TransparentGBuffers;
			half _UseOpaqueTexture;
			float4 _MainTex_TexelSize;
			CBUFFER_END

			TEXTURE2D(_MainTex);

			TEXTURE2D(_CameraDepthTexture);
			SAMPLER(sampler_CameraDepthTexture);

			TEXTURE2D(_CameraDepthAttachment);
			SAMPLER(sampler_CameraDepthAttachment);

			TEXTURE2D(_PathTracingHistoryTexture);
			SAMPLER(my_point_clamp_sampler);

			// Camera or Per Object motion vectors.
			TEXTURE2D(_MotionVectorTexture);
			SAMPLER(sampler_LinearClamp);
			float4 _MotionVectorTexture_TexelSize;

			#include "./TemporalAccumulation.hlsl"

			struct Attributes
			{
				float4 positionOS : POSITION;
				float2 uv : TEXCOORD0;
			};

			struct Varyings
			{
				float4 positionCS : SV_POSITION;
				float2 uv : TEXCOORD0;
			};

			Varyings vert(Attributes input)
			{
				Varyings output;
				output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
				output.uv = input.uv;
				return output;
			}

			half4 frag(Varyings input) : SV_Target
			{
				// TODO: Generate a history texture to store "_Sample" for each pixel, so that the accumulation will be usable for real-time rendering.

				// Unity motion vectors are forward motion vectors in screen UV space
				half2 motion = SAMPLE_TEXTURE2D_X_LOD(_MotionVectorTexture, sampler_LinearClamp, input.uv, 0).xy;
				float2 prevUV = input.uv - motion;

				float deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, sampler_CameraDepthAttachment, UnityStereoTransformScreenSpaceTex(input.uv), 0).r;
				float prevDeviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, sampler_CameraDepthAttachment, UnityStereoTransformScreenSpaceTex(prevUV), 0).r;
				bool isSky;
				#if (UNITY_REVERSED_Z == 1)
					isSky = deviceDepth == 0.0 || prevDeviceDepth == 0.0 ? true : false;
				#else
					isSky = deviceDepth == 1.0 || prevDeviceDepth == 1.0 ? true : false; // OpenGL Platforms.
				#endif

				if (isSky || prevUV.x > 1.0 || prevUV.x < 0.0 || prevUV.y > 1.0 || prevUV.y < 0.0)
				{
					// return 0 alpha to keep the color in render target.
					return half4(0.0, 0.0, 0.0, 0.0);
				}
				else
				{
					// Performance cost here can be reduced by removing less important operations.

					// Color Variance
					half3 colorCenter = SampleColorPoint(input.uv, float2(0.0, 0.0)).xyz;  // Point == Linear as uv == input pixel center.

					half3 boxMax = colorCenter;
					half3 boxMin = colorCenter;
					half3 moment1 = colorCenter;
					half3 moment2 = colorCenter * colorCenter;

					// adjacent pixels
					AdjustColorBox(boxMin, boxMax, moment1, moment2, input.uv, 0.0, -1.0);
					AdjustColorBox(boxMin, boxMax, moment1, moment2, input.uv, -1.0, 0.0);
					AdjustColorBox(boxMin, boxMax, moment1, moment2, input.uv, 1.0, 0.0);
					AdjustColorBox(boxMin, boxMax, moment1, moment2, input.uv, 0.0, 1.0);

					/*
					// remaining pixels in a 9x9 square (excluding center)
					AdjustColorBox(boxMin, boxMax, moment1, moment2, input.uv, -1.0, -1.0);
					AdjustColorBox(boxMin, boxMax, moment1, moment2, input.uv, 1.0, -1.0);
					AdjustColorBox(boxMin, boxMax, moment1, moment2, input.uv, -1.0, 1.0);
					AdjustColorBox(boxMin, boxMax, moment1, moment2, input.uv, 1.0, 1.0);
					*/
					
					// Motion Vectors
					half bestOffsetX = 0.0;
					half bestOffsetY = 0.0;
					half bestDepth = 1.0;

					// adjacent pixels (including center)
					AdjustBestDepthOffset(bestDepth, bestOffsetX, bestOffsetY, input.uv, 0.0, 0.0);
					AdjustBestDepthOffset(bestDepth, bestOffsetX, bestOffsetY, input.uv, 1.0, 0.0);
					AdjustBestDepthOffset(bestDepth, bestOffsetX, bestOffsetY, input.uv, 0.0, -1.0);
					AdjustBestDepthOffset(bestDepth, bestOffsetX, bestOffsetY, input.uv, -1.0, 0.0);
					AdjustBestDepthOffset(bestDepth, bestOffsetX, bestOffsetY, input.uv, 0.0, 1.0);

					/*
					// remaining pixels in a 9x9 square
					AdjustBestDepthOffset(bestDepth, bestOffsetX, bestOffsetY, input.uv, -1.0, -1.0);
					AdjustBestDepthOffset(bestDepth, bestOffsetX, bestOffsetY, input.uv, 1.0, -1.0);
					AdjustBestDepthOffset(bestDepth, bestOffsetX, bestOffsetY, input.uv, -1.0, 1.0);
					AdjustBestDepthOffset(bestDepth, bestOffsetX, bestOffsetY, input.uv, 1.0, 1.0);
					*/

					half2 depthOffsetUv = half2(bestOffsetX, bestOffsetY);
					half2 velocity = GetVelocityWithOffset(input.uv, depthOffsetUv);

					prevUV = input.uv + velocity;

					// Re-projected color from last frame.
					half3 prevColor = SAMPLE_TEXTURE2D_LOD(_PathTracingHistoryTexture, sampler_LinearClamp, prevUV, 0).rgb;

					// Can be replace by clamp() to reduce performance cost.
					prevColor = ClipToAABBCenter(prevColor, boxMin, boxMax);

					half intensity = saturate(min(_DenoiserIntensity - (abs(velocity.x)) * _DenoiserIntensity, _DenoiserIntensity - (abs(velocity.y)) * _DenoiserIntensity));

					return half4(prevColor, intensity);
				}
			}
			ENDHLSL
		}

		Pass
		{
			Name "Edge-Avoiding Spatial Denoise"
			Tags { "LightMode" = "Spatial Accumulation" }

			// No culling or depth
			Cull Off ZWrite Off ZTest Always
			Blend One Zero

			HLSLPROGRAM
			#pragma vertex vert
			#pragma fragment frag

			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

			TEXTURE2D_X(_MainTex);
			TEXTURE2D_X(_CameraDepthAttachment);

			TEXTURE2D_X_HALF(_GBuffer0);
			TEXTURE2D_X_HALF(_GBuffer2);

			TEXTURE2D_X_HALF(_TransparentGBuffer0);
			TEXTURE2D_X_HALF(_TransparentGBuffer1);
			TEXTURE2D_X_HALF(_TransparentGBuffer2);
			SAMPLER(my_point_clamp_sampler);

			TEXTURE2D_X(_CameraOpaqueTexture);
			SAMPLER(sampler_CameraOpaqueTexture);
		
			CBUFFER_START(UnityPerMaterial)
			half _Sample;
			half _MaxSample;
			half _DenoiserIntensity;
			half _TransparentGBuffers;
			half _UseOpaqueTexture;
			float4 _MainTex_TexelSize;
			CBUFFER_END
			
			struct Attributes
			{
				float4 positionOS : POSITION;
				float2 uv : TEXCOORD0;
			};

			struct Varyings
			{
				float4 positionCS : SV_POSITION;
				float2 uv : TEXCOORD1;
			};

			Varyings vert(Attributes input)
			{
				Varyings output;
				output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
				output.uv = input.uv;
				return output;
			}

			half4 frag(Varyings input) : SV_Target
			{
				// Edge-Avoiding A-TrousWavelet Transform for denoising
				// Modified from "https://www.shadertoy.com/view/ldKBzG"
				// feel free to use it

				// Dynamic dilation rate
				// This reduces repetitive artifacts of A-Trous filtering.
				half intensity = floor(lerp(3.0, 16.0, GenerateHashedRandomFloat(uint3(input.uv * _ScreenSize.xy, 1))));
				
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
				float deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, my_point_clamp_sampler, UnityStereoTransformScreenSpaceTex(input.uv), 0).r;
				bool isSky;
				#if (UNITY_REVERSED_Z == 1)
					isSky = deviceDepth == 0.0;
				#else
					isSky = deviceDepth == 1.0; // OpenGL Platforms.
				#endif

				UNITY_BRANCH
				if (isSky)
				{
					return SAMPLE_TEXTURE2D_X_LOD(_MainTex, my_point_clamp_sampler, UnityStereoTransformScreenSpaceTex(input.uv), 0);
				}
				else
				{
					bool transparentGBuffers = false;
					UNITY_BRANCH
					if (_TransparentGBuffers == 1.0)
					{
						uint surfaceType = uint((SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer1, my_point_clamp_sampler, UnityStereoTransformScreenSpaceTex(input.uv), 0).a * 255.0h) + 0.5h);
						transparentGBuffers = surfaceType == 2;
					}

					half3 centerColor = SAMPLE_TEXTURE2D_X_LOD(_MainTex, my_point_clamp_sampler, UnityStereoTransformScreenSpaceTex(input.uv), 0).rgb;
					half3 centerEmission = half3(0.0, 0.0, 0.0);
					UNITY_BRANCH
					if (_UseOpaqueTexture == 1.0 && !transparentGBuffers)
						centerEmission = SAMPLE_TEXTURE2D_X_LOD(_CameraOpaqueTexture, sampler_CameraOpaqueTexture, UnityStereoTransformScreenSpaceTex(input.uv), 0).rgb;

					half3 centerNormal;
					half3 centerAlbedo;
					UNITY_BRANCH
					if (transparentGBuffers)
					{
						centerNormal = SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer2, my_point_clamp_sampler, UnityStereoTransformScreenSpaceTex(input.uv), 0).rgb;
						if (!any(centerNormal))
							centerNormal = SAMPLE_TEXTURE2D_X_LOD(_GBuffer2, my_point_clamp_sampler, UnityStereoTransformScreenSpaceTex(input.uv), 0).rgb;
						centerAlbedo = SAMPLE_TEXTURE2D_X_LOD(_TransparentGBuffer0, my_point_clamp_sampler, UnityStereoTransformScreenSpaceTex(input.uv), 0).rgb;
						if (!any(centerAlbedo))
							centerAlbedo = SAMPLE_TEXTURE2D_X_LOD(_GBuffer0, my_point_clamp_sampler, UnityStereoTransformScreenSpaceTex(input.uv), 0).rgb;
					}
					else
					{
						centerNormal = SAMPLE_TEXTURE2D_X_LOD(_GBuffer2, my_point_clamp_sampler, UnityStereoTransformScreenSpaceTex(input.uv), 0).rgb;
						centerAlbedo = SAMPLE_TEXTURE2D_X_LOD(_GBuffer0, my_point_clamp_sampler, UnityStereoTransformScreenSpaceTex(input.uv), 0).rgb;
					}

					half3 sumColor = half3(0.0, 0.0, 0.0);
					half sumWeight = half(0.0);
					for (uint i = 0; i < 9; i++)
					{
						float2 uv = UnityStereoTransformScreenSpaceTex(input.uv + offset[i] * intensity * _MainTex_TexelSize.xy);

						half3 color = SAMPLE_TEXTURE2D_X_LOD(_MainTex, my_point_clamp_sampler, uv, 0).rgb;
						half3 diff = centerColor - color;
						half distance = dot(diff, diff);
						half colorWeight = min(exp(-distance * 1.1), 1.0); // rcp(0.9)

						half emissionWeight = half(1.0);
						UNITY_BRANCH
						if (_UseOpaqueTexture == 1.0 && !transparentGBuffers)
						{
							half3 emission = SAMPLE_TEXTURE2D_X_LOD(_CameraOpaqueTexture, sampler_CameraOpaqueTexture, uv, 0).rgb;
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

					return half4(sumColor * rcp(sumWeight), 1.0);
				}
			}
			ENDHLSL
		}
	}
}