Documentation
=============

Global Setup
-------------

UnitySSPathTracingURP supports:

- Deferred rendering path.

- Forward or Forward+ (suggested) rendering path. (Please read [Forward path support](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/ForwardPathSupport.md))

 ![SetURPToDeferredPath](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Settings/URP_DeferredPath.png)

- Disable Environment Lighting.

 ![DisableEnvironmentLighting](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Settings/DisableEnvironmentLighting.png)

- Adding the following two Renderer Features with settings in the picture below.

 ![Setup_ScreenSpacePathTracing_RendererFeatures](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Settings/Setup_ScreenSpacePathTracing_RendererFeatures.png)

- 64 Bits HDR Precision is recomended for offline accumulating more samples.

Material Setup
-------------

Method: Blue Noise is more performance expensive, but is usually better.

Ray Marching Quality: Very Low should be enough for small scenes.

Dithering: Dithering can reduce the banding artifacts in sharp reflection & refraction.

Use Reflection Probe Instead: Using Reflection Probe as the environment lighting. (Need to add **"PathTracingSetReflectionProbe.cs"** to the camera if not in Forward+ rendering path)

 ![ScreenSpacePathTracing_MaterialSettings](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Settings/AddProbeSetter.jpg)

Ignore deferred 0 smoothness: Enable this to fix forward objects' rendering artifacts in deferred, but will require all (deferred) materials to have non-0 smoothness. (0.01 and above)

 ![ScreenSpacePathTracing_MaterialSettings](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Settings/ScreenSpacePathTracing_MaterialSettings.png)

In order to avoid double environment lighting, please disable Environment Reflection for all (Deferred) materials:

 ![Disable_All_Materials_EnvironmentReflection](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Settings/Disable_All_Materials_EnvironmentReflection.png)

Extensions
-------------

Accurate Thickness: Render the backface data of scene geometries to improve the accuracy of screen space path tracing.

- Disable: Do not render back-face data.

- Depth: Render back-face depth.

- Depth + Normals: Render back-face depth and normals. This is suggested when refraction is enabled.

 ![AccurateThickness](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Settings/AccurateThickness.png)

Details
-------------

For more details including custom quality settings, please see [PathTracingConfig.hlsl](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Assets/Shaders/ScreenSpacePathTracing/PathTracingConfig.hlsl).
