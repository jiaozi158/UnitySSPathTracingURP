using System.Collections.Generic;
using System.Reflection;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering.RendererUtils;

[DisallowMultipleRendererFeature("Screen Space Path Tracing Forward GBuffer")]
[Tooltip("Add this Renderer Feature to render GBuffers in Forward path.")]
public class PathTracingForwardGBuffer : ScriptableRendererFeature
{
    [Header("Advanced")]

    // Set this to "After Opaques" so that we can enable GBuffers Depth Priming on non-GL platforms.
    [HideInInspector] public RenderPassEvent PassEvent = RenderPassEvent.AfterRenderingOpaques;

    // Add the tag name here if your custom GBuffer pass tag name is not "UniversalGBuffer".
    [HideInInspector] public string[] PassNames = new string[] { "UniversalGBuffer" };

    // C# Reflection
    private readonly static FieldInfo gBufferFieldInfo = typeof(UniversalRenderer).GetField("m_GBufferPass", BindingFlags.NonPublic | BindingFlags.Instance);
    private readonly static FieldInfo normalsTextureFieldInfo = typeof(UniversalRenderer).GetField("m_NormalsTexture", BindingFlags.NonPublic | BindingFlags.Instance);

    public class ForwardGBufferPass : ScriptableRenderPass
    {
        const string m_ProfilerTag = "Path Tracing Forward GBuffer";
        private List<ShaderTagId> m_ShaderTagIdList = new List<ShaderTagId>();
        private FilteringSettings m_filter;

        // Depth Priming.
        private RenderStateBlock m_RenderStateBlock = new RenderStateBlock(RenderStateMask.Nothing);

        public RTHandle m_GBuffer0;
        public RTHandle m_GBuffer1;
        public RTHandle m_GBuffer2;
        private RTHandle[] m_GBuffers;

        public ForwardGBufferPass(string[] PassNames)
        {
            RenderQueueRange queue = new RenderQueueRange(2000, 3000);
            m_filter = new FilteringSettings(queue);
            if (PassNames != null && PassNames.Length > 0)
            {
                foreach (var passName in PassNames)
                    m_ShaderTagIdList.Add(new ShaderTagId(passName));
            }
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            // GBuffer cannot store surface data from transparent objects.
            SortingCriteria sortingCriteria = renderingData.cameraData.defaultOpaqueSortFlags;

            CommandBuffer cmd = CommandBufferPool.Get();
            using (new ProfilingScope(cmd, new ProfilingSampler(m_ProfilerTag)))
            {
                RendererListDesc rendererListDesc = new RendererListDesc(m_ShaderTagIdList[0], renderingData.cullResults, renderingData.cameraData.camera);
                rendererListDesc.stateBlock = m_RenderStateBlock;
                rendererListDesc.sortingCriteria = sortingCriteria;
                rendererListDesc.renderQueueRange = m_filter.renderQueueRange;
                RendererList rendererList = context.CreateRendererList(rendererListDesc);

                cmd.DrawRendererList(rendererList);
            }
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            CommandBufferPool.Release(cmd);
        }

        public void Dispose()
        {
            m_GBuffer0?.Release();
            m_GBuffer1?.Release();
            m_GBuffer2?.Release();
        }

        // From "URP-Package/Runtime/DeferredLights.cs".
        public GraphicsFormat GetGBufferFormat(int index)
        {
            if (index == 0) // sRGB albedo, materialFlags
                return QualitySettings.activeColorSpace == ColorSpace.Linear ? GraphicsFormat.R8G8B8A8_SRGB : GraphicsFormat.R8G8B8A8_UNorm;
            else if (index == 1) // sRGB specular, occlusion
                return GraphicsFormat.R8G8B8A8_UNorm;
            else if (index == 2) // normal normal normal packedSmoothness
                // NormalWS range is -1.0 to 1.0, so we need a signed render texture.
                if (SystemInfo.IsFormatSupported(GraphicsFormat.R8G8B8A8_SNorm, FormatUsage.Render))
                    return GraphicsFormat.R8G8B8A8_SNorm;
                else
                    return GraphicsFormat.R16G16B16A16_SFloat;
            else
                return GraphicsFormat.None;
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            RenderTextureDescriptor desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0; // Color and depth cannot be combined in RTHandles
            desc.stencilFormat = GraphicsFormat.None;
            desc.msaaSamples = 1; // Do not enable MSAA for GBuffers.

            // Albedo.rgb + MaterialFlags.a
            desc.graphicsFormat = GetGBufferFormat(0);
            RenderingUtils.ReAllocateIfNeeded(ref m_GBuffer0, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_GBuffer0");
            cmd.SetGlobalTexture("_GBuffer0", m_GBuffer0);

            // Specular.rgb + Occlusion.a
            desc.graphicsFormat = GetGBufferFormat(1);
            RenderingUtils.ReAllocateIfNeeded(ref m_GBuffer1, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_GBuffer1");
            cmd.SetGlobalTexture("_GBuffer1", m_GBuffer1);
            
            // If "_CameraNormalsTexture" exists (lacking smoothness info), set the target to it instead of creating a new RT.
            if (normalsTextureFieldInfo.GetValue(renderingData.cameraData.renderer) is not RTHandle normalsTextureHandle)
            {
                // NormalWS.rgb + Smoothness.a
                desc.graphicsFormat = GetGBufferFormat(2);
                RenderingUtils.ReAllocateIfNeeded(ref m_GBuffer2, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_GBuffer2");
                cmd.SetGlobalTexture("_GBuffer2", m_GBuffer2);
                m_GBuffers = new RTHandle[] { m_GBuffer0, m_GBuffer1, m_GBuffer2 };
            }
            else
            {
                cmd.SetGlobalTexture("_GBuffer2", normalsTextureHandle);
                m_GBuffers = new RTHandle[] { m_GBuffer0, m_GBuffer1, normalsTextureHandle};
            }

            ConfigureTarget(m_GBuffers, renderingData.cameraData.renderer.cameraDepthTargetHandle);

            // Require Depth Texture in Forward pipeline.
            ConfigureInput(ScriptableRenderPassInput.Depth);

            // [OpenGL] Reusing the depth buffer seems to cause black glitching artifacts, so clear the existing depth.
            bool isOpenGL = (SystemInfo.graphicsDeviceType == GraphicsDeviceType.OpenGLES3) || (SystemInfo.graphicsDeviceType == GraphicsDeviceType.OpenGLCore); // GLES 2 is deprecated.
            if (isOpenGL)
                ConfigureClear(ClearFlag.Depth, Color.black);

            // Reduce GBuffer overdraw using the depth from opaque pass. (excluding OpenGL platforms)
            if (!isOpenGL && (renderingData.cameraData.renderType == CameraRenderType.Base || renderingData.cameraData.clearDepth))
            {
                m_RenderStateBlock.depthState = new DepthState(false, CompareFunction.Equal);
                m_RenderStateBlock.mask |= RenderStateMask.Depth;
            }
            else if (m_RenderStateBlock.depthState.compareFunction == CompareFunction.Equal)
            {
                m_RenderStateBlock.depthState = new DepthState(true, CompareFunction.LessEqual);
                m_RenderStateBlock.mask |= RenderStateMask.Depth;
            }
        }
    }

    ForwardGBufferPass m_ForwardGBufferPass;
    public override void Create()
    {
        m_ForwardGBufferPass = new ForwardGBufferPass(PassNames);
        m_ForwardGBufferPass.renderPassEvent = PassEvent;
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        // If GBuffer exists, URP is in Deferred path. (Actual rendering mode can be different from settings, such as URP forces Forward on OpenGL)
        bool isUsingDeferred = gBufferFieldInfo.GetValue(renderer) != null;
        // OpenGL won't use deferred path.
        isUsingDeferred &= (SystemInfo.graphicsDeviceType != GraphicsDeviceType.OpenGLES3) & (SystemInfo.graphicsDeviceType != GraphicsDeviceType.OpenGLCore);  // GLES 2 is deprecated.

        if (!isUsingDeferred)
            // This should be at least 4 on platforms with MRT support.
            if (SystemInfo.supportedRenderTargetCount >= 3 && !isUsingDeferred)
            {
                renderer.EnqueuePass(m_ForwardGBufferPass);
            }
            else
            {
                Debug.LogError("Screen Space Path Tracing (Forward): The current device does not support rendering to multiple render targets.");
            }
    }
}


