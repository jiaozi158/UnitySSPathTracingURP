UnitySSPathTracingURP
=============

 Screen Space Path Tracing for Unity's URP (Universal Render Pipeline).

 This shader is created in Shader Graph with the new URP 14 Full Screen Pass Renderer Feature.

 This effect seems to be usable (stability, speed & noisiness) when I tested it on mobile device, so I decide to share it.

 **Please read the Documentation and Requirements before using this repository.**
 
Screenshots
------------
**(BoxScene)**

 ![MixedLighting](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/URP_ScreenSpacePathTracing_MixedLighting.jpg)
 
 ![SkyLightingOnly](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/URP_ScreenSpacePathTracing_SkyLightingOnly.jpg)
 
 ![WithoutAccumulation](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/URP_ScreenSpacePathTracing_Moving.jpg)
 
 ![WithAccumulation](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/URP_ScreenSpacePathTracing.jpg)

 **Note:** Enable URP Temporal Anti-aliasing is important for improving stability. (exists since URP 15)

Documentation
------------
[Here](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Documentation.md).

Requirements
------------
- Unity 2022.2 and URP 14 (URP 15 is recomended with TAA enabled)
- Deferred rendering path (OpenGL will always in Forward path)

License
------------
MIT ![MIT License](http://img.shields.io/badge/license-MIT-blue.svg?style=flat)

References
------------
[Three-Eyed-Games GPU-Ray-Tracing-in-Unity](http://three-eyed-games.com/2018/05/03/gpu-ray-tracing-in-unity-part-1/)

Please see [PathTracing.hlsl](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Assets/Shaders/ScreenSpacePathTracing/PathTracing.hlsl).
