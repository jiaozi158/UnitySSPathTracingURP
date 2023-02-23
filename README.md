UnitySSPathTracingURP
=============

 Screen Space Path Tracing for Unity's URP (Universal Render Pipeline).

 This shader is created in Shader Graph with the new URP 14 Full Screen Pass Renderer Feature.

 This effect seems to be usable (stability, speed & noisiness) when I tested it on mobile device, so I decide to share it.

 **Please read the Documentation and Requirements before using this repository.**
 
Screenshots
------------
**(BoxScene + Reflection Probe Fallback)**

 ![ProbeFallBackOn1](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/ProbeFallBack1.jpg)

 ![ProbeFallBackOn2](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/ProbeFallBack2.jpg)

 ![ProbeFallBackOn3](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/EmissionFromReflectionProbe.jpg)

 ![Converged](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/URP_ScreenSpacePathTracing.jpg)

 ![Moving](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/BoxScene/URP_ScreenSpacePathTracing_Moving.jpg)

 **Note:** Enable URP Temporal Anti-aliasing is important for improving stability. (exists since latest URP 14)

**(Not Included)**

[Classroom](https://www.blender.org/download/demo-files/) by Christophe Seux (CC0)

 ![Classroom](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Others/Classroom.jpg)

[Stormtrooper Star Wars VII](https://www.blendswap.com/blend/13953) by ScottGraham (CC-BY-3.0)

 ![StormTrooper](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/Others/StormTrooper.jpg)

Documentation
------------
[Here](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Documentation.md).

Requirements
------------
- Unity 2022.2 and URP 14 (enable TAA is recommended)
- Deferred rendering path (OpenGL will always in Forward path)
- Forward rendering path ([need extra setup](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/ForwardPathSupport.md))
- Multiple Render Targets support (at least OpenGL ES 3.0 or equivalent)

License
------------
MIT ![MIT License](http://img.shields.io/badge/license-MIT-blue.svg?style=flat)

References
------------
[Three-Eyed-Games GPU-Ray-Tracing-in-Unity](http://three-eyed-games.com/2018/05/03/gpu-ray-tracing-in-unity-part-1/)

[Introduction to Path Tracing - Marc Sunet](https://shellblade.net/files/slides/path-tracing.pdf)

Please see [PathTracing.hlsl](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Assets/Shaders/ScreenSpacePathTracing/PathTracing.hlsl).
