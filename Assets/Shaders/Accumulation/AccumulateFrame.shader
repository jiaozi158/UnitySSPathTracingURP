Shader "Hidden/AccumulateFrame"
{
	Properties
	{
		[HideInInspector] _MainTex("_MainTex", 2D) = "white" {}
		[HideInInspector] _Sample("Total Sample", Float) = 0.0
		[HideInInspector] _MaxSample("Maximum Sample", Float) = 64.0
	}

	// TODO: Reject or reproject history samples according to per object motion vectors?

	SubShader
	{
		// No culling or depth
		Cull Off ZWrite Off ZTest Always
		Blend SrcAlpha OneMinusSrcAlpha

		Pass
		{
			Name "Accumulation"
		    Tags { "LightMode" = "Accumulation" }

			HLSLPROGRAM
			#pragma vertex vert
			#pragma fragment frag

			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

			TEXTURE2D(_MainTex);
			SamplerState my_point_clamp_sampler;

			// Camera or Per Object motion vectors.
			TEXTURE2D(_MotionVectorTexture);

			CBUFFER_START(UnityPerMaterial)
			float _Sample;
			float _MaxSample;
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
				// TODO: Generate a history texture to store "_Sample" for each pixel, so that the accumulation will be usable for real-time rendering.

				// Will be per object motion in future URP.
				float2 prevUV = input.uv + SAMPLE_TEXTURE2D_LOD(_MotionVectorTexture, my_point_clamp_sampler, input.uv, 0).xy;

				half3 color = SAMPLE_TEXTURE2D_LOD(_MainTex, my_point_clamp_sampler, input.uv, 0).rgb;

				// When object or camera moves, we should re-accumulate the pixel.
				bool reAccumulate = (_Sample == 0.0) ? true : false;
				//bool reAccumulate = (_Sample == 0.0) || (input.uv.x != prevUV.x) || (input.uv.y != prevUV.y) ? true : false;
				if (reAccumulate)
					return half4(color, 1.0);
				else
					return half4(color, (1.0 / (_Sample + 1.0)));
			}
			ENDHLSL
		}

		Pass
		{
			Name "AccumulationBlit"
			Tags { "LightMode" = "AccumulationBlit" }

			Blend One Zero

			HLSLPROGRAM
			#pragma vertex vert
			#pragma fragment frag

			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"

			TEXTURE2D(_MainTex);
			SamplerState my_point_clamp_sampler;

			CBUFFER_START(UnityPerMaterial)
			float _Sample;
			float _MaxSample;
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
			void AddConvergenceCue(float2 screenUV, float currentSample, inout half3 color)
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
	}
}