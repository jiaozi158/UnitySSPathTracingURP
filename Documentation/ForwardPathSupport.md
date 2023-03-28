Screen Space Path Tracing in Forward path
=============

Screen Space Path Tracing requires surface data (stored in Deferred GBuffer) to calculate lighting. It's suggested to use Deferred rendering path for better performance.

To render GBuffer in Forward path, please follow the instructions below.

 ![UseForwardPath](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/OpenGL/UseForwardPath_GL.jpg)

Global Setup
-------------

- Add "Screen Space Path Tracing Forward GBuffer" renderer feature to your URP project.

 ![AddForwardGBufferFeature](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/OpenGL/ForwardGBufferFeature.jpg)

- Make sure there is a URP renderer that uses Deferred path. This tells Unity to **compile shader variants** for GBuffer rendering.

 ![AddDeferredURPRenderer](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/OpenGL/AddDeferredRenderer.png)

OpenGL Platforms Extra Setup
-------------

By default, the GBuffer pass of URP shader ignores all OpenGL platforms. The modified copy of URP shader is (URP) version related, which means it cannot be included in this repository.

- Right-click URP's "Lit.shader" in the package folder and open the path in File Explorer.

 ![CustomLitShaderForGL_01](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/OpenGL/CustomLitForGL_01.jpg)

- Copy the shader to your project's Asset folder so that it's editable.

 ![CustomLitShaderForGL_02](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/OpenGL/CustomLitForGL_02.jpg)

- Open the copied shader and change the name to make it easier to recognize in the inspector.

 ![CustomLitShaderForGL_03](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/OpenGL/CustomLitForGL_03.jpg)

- Delete **all lines** with **"#pragma target 4.5"** or **"#pragma exclude_renderers gles gles3 glcore"**.

 ![CustomLitShaderForGL_04](https://github.com/jiaozi158/UnitySSPathTracingURP/blob/main/Documentation/Images/OpenGL/CustomLitForGL_04.jpg)

- Change the materials' shader to the modified shader.
