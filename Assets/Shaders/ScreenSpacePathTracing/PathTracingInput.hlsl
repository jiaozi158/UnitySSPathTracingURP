#ifndef URP_SCREEN_SPACE_PATH_TRACING_INPUT_HLSL
#define URP_SCREEN_SPACE_PATH_TRACING_INPUT_HLSL

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

// Do not change, from URP's GBuffer hlsl.
//===================================================================================================================================
// Light flags (can shader graph access stencil buffer?)
#define kLightingInvalid  -1  // No dynamic lighting: can aliase any other material type as they are skipped using stencil
#define kLightingLit       1  // lit shader
#define kLightingSimpleLit 2  // Simple lit shader
#define kLightFlagSubtractiveMixedLighting    4 // The light uses subtractive mixed lighting.

// Material flags (customize Lit shader to add new lighting model?)
#define kMaterialFlagReceiveShadowsOff        1 // Does not receive dynamic shadows
#define kMaterialFlagSpecularHighlightsOff    2 // Does not receivce specular
#define kMaterialFlagSubtractiveMixedLighting 4 // The geometry uses subtractive mixed lighting
#define kMaterialFlagSpecularSetup            8 // Lit material use specular setup instead of metallic setup

// Path Tracing Surface Type flags
#define kSurfaceTypeRefraction        2

TEXTURE2D_X_HALF(_GBuffer0); // color.rgb + materialFlags.a
TEXTURE2D_X_HALF(_GBuffer1); // specular.rgb + oclusion.a
TEXTURE2D_X_HALF(_GBuffer2); // normalWS.rgb + smoothness.a
// _GBuffer3                 // indirectLighting.rgb (B10G11R11 / R16G16B16A16)

// GBuffers for transparent objects (stores the first layer only)
TEXTURE2D_X_HALF(_TransparentGBuffer0); // color.rgb + materialFlags.a
TEXTURE2D_X_HALF(_TransparentGBuffer1); // surfaceData.rgb + surfaceType.a
TEXTURE2D_X_HALF(_TransparentGBuffer2); // normalWS.rgb + smoothness.a

TEXTURE2D_X_FLOAT(_CameraDepthAttachment); // CameraTransparentDepthTexture (stores the first layer only)
SAMPLER(sampler_CameraDepthAttachment);

TEXTURE2D_X_FLOAT(_CameraBackDepthTexture);
SAMPLER(sampler_CameraBackDepthTexture);

TEXTURE2D_X_HALF(_CameraBackNormalsTexture);

// GBuffer 3 is the current render target, which means inaccessible.
// It's also the Emission GBuffer when there's no lighting in scene.
//TEXTURE2D_X(_BlitTexture);   // indirectLighting.rgb (B10G11R11 / R16G16B16A16)

SAMPLER(my_point_clamp_sampler);

#if _RENDER_PASS_ENABLED

#define GBUFFER0 0
#define GBUFFER1 1
#define GBUFFER2 2

FRAMEBUFFER_INPUT_HALF(GBUFFER0);
FRAMEBUFFER_INPUT_HALF(GBUFFER1);
FRAMEBUFFER_INPUT_HALF(GBUFFER2);
#endif

#endif