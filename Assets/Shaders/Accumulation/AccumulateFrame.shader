Shader "Hidden/AccumulateFrame"
{
	Properties
	{
		[HideInInspector] _MainTex("_MainTex", 2D) = "white" {}
		[HideInInspector] _Sample("Total Sample", Float) = 0.0
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

				// When object or camera moves, we should re-accumulate the pixel.
				bool reAccumulate = (_Sample == 0.0) ? true : false;
				//bool reAccumulate = (_Sample == 0.0) || (input.uv.x != prevUV.x) || (input.uv.y != prevUV.y) ? true : false;
				if (reAccumulate)
					return half4(SAMPLE_TEXTURE2D_LOD(_MainTex, my_point_clamp_sampler, input.uv, 0).rgb, 1.0);
				else
					return half4(SAMPLE_TEXTURE2D_LOD(_MainTex, my_point_clamp_sampler, input.uv, 0).rgb, (1.0 / (_Sample + 1.0)));
			}
			ENDHLSL
		}
	}
}