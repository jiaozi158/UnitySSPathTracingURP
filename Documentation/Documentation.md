Documentation
=============

Global Setup
-------------

UnitySSPathTracingURP requires:

- Deferred rendering path in use. (OpenGL will always be in Forward)

 ![SetURPToDeferredPath](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Settings/URP_DeferredPath.png)

- Disable Environment Lighting if you would like Screen Space Path Tracing evaluating sky lighting.

 ![DisableEnvironmentLighting](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Settings/DisableEnvironmentLighting.png)

- Adding the following two Renderer Features with settings in the picture below.

 ![Setup_ScreenSpacePathTracing_RendererFeatures](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Settings/Setup_ScreenSpacePathTracing_RendererFeatures.png)

- 64 Bits HDR Precision is recomended for accumulating more samples.

Material Setup
-------------

Ray Marching Quality: Low should be enough for small scenes.

Dithering: Dithering can reduce the banding artifacts in sharp reflections.

Use Reflection Probe Instead: Using Reflection Probe as the environment lighting. (Need to add **"PathTracingSetReflectionProbe.cs"** to the camera)

 ![ScreenSpacePathTracing_MaterialSettings](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Settings/AddProbeSetter.jpg)

Ignore deferred 0 smoothness: Enable this to fix forward objects' rendering artifacts in deferred, but will require all (deferred) materials to have non-0 smoothness. (0.01 and above)

 ![ScreenSpacePathTracing_MaterialSettings](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Settings/ScreenSpacePathTracing_MaterialSettings.png)

In order to avoid double environment lighting, please disable Environment Reflection for all (Deferred) materials:

 ![Disable_All_Materials_EnvironmentReflection](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Settings/Disable_All_Materials_EnvironmentReflection.png)

Details
-------------

For more details including custom quality settings, please see [PathTracing.hlsl](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Assets/Shaders/ScreenSpacePathTracing/PathTracing.hlsl).
