Shader "Hidden/AccumulateFrame"
{
	Properties
	{
		[HideInInspector] _MainTex("_MainTex", 2D) = "white" {}
		[HideInInspector] _Sample("Total Sample", Float) = 0.0
		[HideInInspector] _MaxSample("Maximum Sample", Float) = 64.0
		[HideInInspector] _DenoiserIntensity("Denoiser Intensity", Float) = 0.5
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

					// remaining pixels in a 9x9 square (excluding center)
					AdjustColorBox(boxMin, boxMax, moment1, moment2, input.uv, -1.0, -1.0);
					AdjustColorBox(boxMin, boxMax, moment1, moment2, input.uv, 1.0, -1.0);
					AdjustColorBox(boxMin, boxMax, moment1, moment2, input.uv, -1.0, 1.0);
					AdjustColorBox(boxMin, boxMax, moment1, moment2, input.uv, 1.0, 1.0);
					
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

					// remaining pixels in a 9x9 square
					AdjustBestDepthOffset(bestDepth, bestOffsetX, bestOffsetY, input.uv, -1.0, -1.0);
					AdjustBestDepthOffset(bestDepth, bestOffsetX, bestOffsetY, input.uv, 1.0, -1.0);
					AdjustBestDepthOffset(bestDepth, bestOffsetX, bestOffsetY, input.uv, -1.0, 1.0);
					AdjustBestDepthOffset(bestDepth, bestOffsetX, bestOffsetY, input.uv, 1.0, 1.0);

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
	}
}