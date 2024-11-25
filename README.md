UnitySSPathTracingURP
=============

 Screen Space Path Tracing for Unity's URP (Universal Render Pipeline).

 **Please read the Documentation and Requirements before using this repository.**
 
Screenshots
------------
**(BoxScene + Reflection Probe Fallback)**

 ![ProbeFallBackOn1](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/ProbeFallBack1.jpg)

 ![ProbeFallBackOn2](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/ProbeFallBack2.jpg)

<!-- 
 ![ProbeFallBackOn3](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/EmissionFromReflectionProbe.jpg)

Offline Accumulation

 ![Converged](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/URP_ScreenSpacePathTracing.jpg)

Real-time Accumulation

 ![Moving](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/URP_ScreenSpacePathTracing_Moving.jpg)

 **Note:** Enable URP Temporal Anti-aliasing is important for improving stability. (exists since latest URP 14)
-->

**(Not Included)**

Original Cornell Box

 ![OriginalCornellBox](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Others/OriginalCornellBox.jpg)

[Classroom](https://www.blender.org/download/demo-files/) by Christophe Seux (CC0)

 ![Classroom](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Others/Classroom.jpg)

[Stormtrooper Star Wars VII](https://www.blendswap.com/blend/13953) by ScottGraham (CC-BY-3.0)

 ![StormTrooper](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Others/StormTrooper.jpg)

Refraction (Lit by emission)

 ![Refraction](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Others/Refraction.jpg)

Documentation
------------
[Here](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Documentation.md).

Requirements
------------
- Unity 2022.2 and URP 14 (enable TAA is recommended)
- Deferred rendering path (OpenGL will always in Forward path)
- Forward rendering path ([need extra setup](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/ForwardPathSupport.md))
- Multiple Render Targets support (at least OpenGL ES 3.0 or equivalent)
- Lowering down the Render Scale (e.g. "0.5") on mobile devices and use upscaler (e.g. FSR 1.0) to reduce performance cost.
- Use "Refraction Lit" shader graph to render screen space path traced refraction.

License
------------
MIT ![MIT License](http://img.shields.io/badge/license-MIT-blue.svg?style=flat)

References
------------
[Three-Eyed-Games GPU-Ray-Tracing-in-Unity](http://three-eyed-games.com/2018/05/03/gpu-ray-tracing-in-unity-part-1/)

[Introduction to Path Tracing - Marc Sunet](https://shellblade.net/files/slides/path-tracing.pdf)

Please see [PathTracing.hlsl](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Assets/Shaders/ScreenSpacePathTracing/PathTracing.hlsl).
