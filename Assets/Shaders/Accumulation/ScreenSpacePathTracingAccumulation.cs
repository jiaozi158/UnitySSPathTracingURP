using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RendererUtils;
using Unity.Collections;

[DisallowMultipleRendererFeature("Screen Space Path Tracing Accumulation")]
[Tooltip("Add this Renderer Feature to accumulate path tracing results.")]
public class ScreenSpacePathTracingAccumulation : ScriptableRendererFeature
{
    public enum Accumulation
    {
        [InspectorName("Disable")]
        [Tooltip("Disable accumulation.")]
        None = 0,

        [InspectorName("Offline")]
        [Tooltip("Offline mode provides the best quality.")]
        Camera = 1,

        [InspectorName("Real-time")]
        [Tooltip("Real-time mode will only execute in play mode.")]
        PerObject = 2
    };

    [Tooltip("The material of accumulation shader.")]
    public Material m_AccumulationMaterial;
    [Tooltip("The material of path tracing shader.")]
    public Material m_PathTracingMaterial;

    [Header("Path Tracing Extensions")]
    [Tooltip("Render the backface depth of scene geometries. This improves the accuracy of screen space path tracing, but may not work well in scenes with lots of single-sided objects.")]
    public bool accurateThickness = false;

    [Header("Accumulation")]
    [Tooltip("The accumulation mode. Real-time mode will only execute in play mode.")]
    public Accumulation accumulation = Accumulation.Camera;
    [Tooltip("Add a progress bar to show the offline accumulation progress.")]
    public bool progressBar = true;
    [Tooltip("Controls the real-time accumulation denoising intensity.")]
    [Range(0.1f, 0.9f)]
    public float denoiserIntensity = 0.5f;

    private const string m_PathTracingShaderName = "Universal Render Pipeline/Screen Space Path Tracing";
    // This shader is also used by denoising.
    private const string m_AccumulationShaderName = "Hidden/AccumulateFrame";
    private AccumulationPass m_AccumulationPass;
    private BackfaceDepthPass m_BackfaceDepthPass;

    public override void Create()
    {
        // Check if the accumulation material uses the correct shader.
        if (m_AccumulationMaterial != null)
        {
            if (m_AccumulationMaterial.shader != Shader.Find(m_AccumulationShaderName))
            {
                Debug.LogErrorFormat("Screen Space Path Tracing: Accumulation material is not using {0} shader.", m_AccumulationShaderName);
                return;
            }
        }
        // No material applied.
        else
        {
            //Debug.LogError("Screen Space Path Tracing: Accumulation material is empty.");
            return;
        }

        if (m_PathTracingMaterial != null)
        {
            if (m_PathTracingMaterial.shader != Shader.Find(m_PathTracingShaderName))
            {
                Debug.LogErrorFormat("Screen Space Path Tracing: Path Tracing material is not using {0} shader.", m_PathTracingShaderName);
                return;
            }
        }
        else
        {
            Debug.LogError("Screen Space Path Tracing: Path Tracing material is empty.");
            return;
        }

        if (m_AccumulationPass == null)
        {
            m_AccumulationPass = new AccumulationPass(m_AccumulationMaterial, accumulation);
            if (accumulation != Accumulation.PerObject)
                m_AccumulationPass.renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;
            else
                m_AccumulationPass.renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing; // requires current frame Motion Vectors
        }
        m_AccumulationPass.m_Accumulation = accumulation;
        m_AccumulationPass.m_ProgressBar = progressBar;

        if (m_BackfaceDepthPass == null)
        {
            m_BackfaceDepthPass = new BackfaceDepthPass();
            m_BackfaceDepthPass.renderPassEvent = RenderPassEvent.AfterRenderingOpaques;
        }
        m_BackfaceDepthPass.m_AccurateThickness = accurateThickness;

        if (accurateThickness)
            m_PathTracingMaterial.SetFloat("_BackDepthEnabled", 1.0f);
        else
            m_PathTracingMaterial.SetFloat("_BackDepthEnabled", 0.0f);

        if (accumulation == Accumulation.PerObject)
            m_AccumulationMaterial.SetFloat("_DenoiserIntensity", denoiserIntensity);
    }


    protected override void Dispose(bool disposing)
    {
        if (m_AccumulationPass != null)
            m_AccumulationPass.Dispose();
        if (m_BackfaceDepthPass != null)
            m_BackfaceDepthPass.Dispose();
    }


    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        // No need to accumulate when rendering reflection probes, this will also break game view accumulation.
        bool shouldAccumulate = (accumulation == Accumulation.Camera) ? (renderingData.cameraData.camera.cameraType != CameraType.Reflection) : (renderingData.cameraData.camera.cameraType != CameraType.Reflection && renderingData.cameraData.camera.cameraType != CameraType.Preview);
        if (shouldAccumulate)
        {
#if UNITY_EDITOR
            // Motion Vectors of URP SceneView don't get updated each frame when not entering play mode. (Might be fixed when supporting scene view anti-aliasing)
            // Change the method to multi-frame accumulation if SceneView is not in play mode.
            bool isPlayMode = UnityEditor.EditorApplication.isPlaying;
            if (renderingData.cameraData.camera.cameraType == CameraType.SceneView && !isPlayMode && accumulation == Accumulation.PerObject)
                m_AccumulationPass.m_Accumulation = Accumulation.Camera;
            else if (renderingData.cameraData.camera.cameraType != CameraType.SceneView && !isPlayMode && accumulation == Accumulation.PerObject)
                m_AccumulationPass.m_Accumulation = Accumulation.PerObject;
#endif
            renderer.EnqueuePass(m_AccumulationPass);
        }

        if (accurateThickness)
        {
            renderer.EnqueuePass(m_BackfaceDepthPass);
        }
    }

    public class AccumulationPass : ScriptableRenderPass
    {
        private int sample = 0;

        private Material m_AccumulationMaterial;
        private RTHandle m_AccumulateColorHandle;
        private RTHandle m_AccumulateHistoryHandle;

        public Accumulation m_Accumulation;
        public bool m_ProgressBar;

        // Reset the accumulation when scene has changed.
        // This is not perfect because we cannot detect per mesh changes or per light changes.
        // (Reject history samples in accumulation shader according to per object motion vectors?)
        private Matrix4x4 prevCamWorldMatrix;
        private Matrix4x4 prevCamHClipMatrix;
        private NativeArray<VisibleLight> prevLightsList;
        private NativeArray<VisibleReflectionProbe> prevProbesList;

        public AccumulationPass(Material accuMaterial, Accumulation accumulation)
        {
            m_AccumulationMaterial = accuMaterial;
            m_Accumulation = accumulation;
        }

        public void Dispose()
        {
            if (m_Accumulation == Accumulation.Camera || m_Accumulation == Accumulation.PerObject)
                m_AccumulateColorHandle?.Release();
            if (m_Accumulation == Accumulation.PerObject)
                m_AccumulateHistoryHandle?.Release();
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0; // Color and depth cannot be combined in RTHandles

            if (m_Accumulation == Accumulation.Camera || m_Accumulation == Accumulation.PerObject)
                RenderingUtils.ReAllocateIfNeeded(ref m_AccumulateColorHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingAccumulationTexture");
            if (m_Accumulation == Accumulation.PerObject)
            {
                RenderingUtils.ReAllocateIfNeeded(ref m_AccumulateHistoryHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingHistoryTexture");
                cmd.SetGlobalTexture("_PathTracingHistoryTexture", m_AccumulateHistoryHandle);
            }

            ConfigureTarget(renderingData.cameraData.renderer.cameraColorTargetHandle);
            ConfigureClear(ClearFlag.None, Color.black);

            if (m_Accumulation == Accumulation.PerObject)
                ConfigureInput(ScriptableRenderPassInput.Motion);

            if (m_Accumulation == Accumulation.Camera)
            {
                Matrix4x4 camWorldMatrix = renderingData.cameraData.camera.cameraToWorldMatrix;
                Matrix4x4 camHClipMatrix = renderingData.cameraData.camera.projectionMatrix;

                bool haveMatrices = prevCamWorldMatrix != null && prevCamHClipMatrix != null;
                if (haveMatrices && prevCamWorldMatrix == camWorldMatrix && prevCamHClipMatrix == camHClipMatrix)
                {
                    prevCamWorldMatrix = camWorldMatrix;
                    prevCamHClipMatrix = camHClipMatrix;
                }
                else
                {
                    sample = 0;
                    prevCamWorldMatrix = camWorldMatrix;
                    prevCamHClipMatrix = camHClipMatrix;
                }
            }
        }

        public override void FrameCleanup(CommandBuffer cmd)
        {
            //cmd.ReleaseTemporaryRT(m_AccumulateColorHandle.GetInstanceID());
            if (m_Accumulation == Accumulation.Camera || m_Accumulation == Accumulation.PerObject)
                cmd.ReleaseTemporaryRT(Shader.PropertyToID(m_AccumulateColorHandle.name));
            if (m_Accumulation == Accumulation.PerObject)
                cmd.ReleaseTemporaryRT(Shader.PropertyToID(m_AccumulateHistoryHandle.name));
        }

        public override void OnCameraCleanup(CommandBuffer cmd)
        {
            if (m_Accumulation == Accumulation.Camera || m_Accumulation == Accumulation.PerObject)
                m_AccumulateColorHandle = null;
            if (m_Accumulation == Accumulation.PerObject)
                m_AccumulateHistoryHandle = null;

        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            CommandBuffer cmd = CommandBufferPool.Get();
            using (new ProfilingScope(cmd, new ProfilingSampler("Path Tracing Camera Accumulation")))
            {
                if (m_Accumulation == Accumulation.Camera)
                {
                    bool lightsNoUpdate = prevLightsList != null && prevLightsList == renderingData.lightData.visibleLights;
                    bool probesNoUpdate = prevProbesList != null && prevProbesList == renderingData.cullResults.visibleReflectionProbes;
                    if (!lightsNoUpdate || !probesNoUpdate)
                    {
                        sample = 0;
                    }

                    prevLightsList = renderingData.lightData.visibleLights;
                    prevProbesList = renderingData.cullResults.visibleReflectionProbes;

                    m_AccumulationMaterial.SetFloat("_Sample", sample);

                    // If the HDR precision is set to 64 Bits, the maximum sample can be 512.
                    UnityEngine.Experimental.Rendering.GraphicsFormat currentGraphicsFormat = m_AccumulateColorHandle.rt.graphicsFormat;
                    int maxSample = currentGraphicsFormat == UnityEngine.Experimental.Rendering.GraphicsFormat.B10G11R11_UFloatPack32 ? 64 : 512;
                    m_AccumulationMaterial.SetFloat("_MaxSample", maxSample);
                    if (sample < maxSample)
                        sample++;
                }

                // Using Blitter is better because it supports XR, dig deeper later.
                /*
                m_Material.SetTexture("_MainTex", renderingData.cameraData.renderer.cameraColorTargetHandle);
                // Load & Store actions are important to support acculumation.
                Blitter.BlitCameraTexture(cmd, renderingData.cameraData.renderer.cameraColorTargetHandle, m_AccumulateColorHandle, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store, m_AccumulationMaterial, 0);
                if (m_ProgressBar == true)
                    Blitter.BlitCameraTexture(cmd, m_AccumulateColorHandle, renderingData.cameraData.renderer.cameraColorTargetHandle, m_AccumulationMaterial, 1);
                else
                    Blitter.BlitCameraTexture(cmd, m_AccumulateColorHandle, renderingData.cameraData.renderer.cameraColorTargetHandle);
                */

                ///*
                // Load & Store actions are important to support acculumation.
                if (m_Accumulation == Accumulation.Camera)
                {
                    cmd.SetRenderTarget(
                    m_AccumulateColorHandle,
                    RenderBufferLoadAction.Load,
                    RenderBufferStoreAction.Store,
                    m_AccumulateColorHandle,
                    RenderBufferLoadAction.DontCare,
                    RenderBufferStoreAction.DontCare);

                    cmd.Blit(renderingData.cameraData.renderer.cameraColorTargetHandle.rt, m_AccumulateColorHandle, m_AccumulationMaterial, 0);

                    if (m_ProgressBar == true)
                        cmd.Blit(m_AccumulateColorHandle, renderingData.cameraData.renderer.cameraColorTargetHandle.rt, m_AccumulationMaterial, 1);
                    else
                        cmd.Blit(m_AccumulateColorHandle, renderingData.cameraData.renderer.cameraColorTargetHandle);
                }
                else if (m_Accumulation == Accumulation.PerObject)
                {
                    // Load & Store actions are important to support acculumation.
                    cmd.SetRenderTarget(
                        m_AccumulateColorHandle,
                        RenderBufferLoadAction.Load,
                        RenderBufferStoreAction.Store,
                        m_AccumulateColorHandle,
                        RenderBufferLoadAction.DontCare,
                        RenderBufferStoreAction.DontCare);

                    cmd.Blit(renderingData.cameraData.renderer.cameraColorTargetHandle, m_AccumulateColorHandle);

                    cmd.Blit(m_AccumulateColorHandle, renderingData.cameraData.renderer.cameraColorTargetHandle.rt, m_AccumulationMaterial, 2);

                    cmd.SetRenderTarget(
                        m_AccumulateHistoryHandle,
                        RenderBufferLoadAction.Load,
                        RenderBufferStoreAction.Store,
                        m_AccumulateHistoryHandle,
                        RenderBufferLoadAction.DontCare,
                        RenderBufferStoreAction.DontCare);

                    cmd.Blit(renderingData.cameraData.renderer.cameraColorTargetHandle.rt, m_AccumulateHistoryHandle);
                }
                //*/

            }
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            CommandBufferPool.Release(cmd);
        }
    }

    public class BackfaceDepthPass : ScriptableRenderPass
    {
        private RTHandle m_BackDepthHandle;
        public bool m_AccurateThickness;

        private RenderStateBlock m_DepthRenderStateBlock = new RenderStateBlock(RenderStateMask.Nothing);

        public void Dispose()
        {
            if (m_AccurateThickness)
                m_BackDepthHandle?.Release();
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            if (renderingData.cameraData.cameraTargetDescriptor.depthStencilFormat == UnityEngine.Experimental.Rendering.GraphicsFormat.D32_SFloat_S8_UInt)
                desc.depthStencilFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.D32_SFloat;
            else if (renderingData.cameraData.cameraTargetDescriptor.depthStencilFormat == UnityEngine.Experimental.Rendering.GraphicsFormat.D24_UNorm_S8_UInt)
                desc.depthStencilFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.D24_UNorm;
            else if (renderingData.cameraData.cameraTargetDescriptor.depthStencilFormat == UnityEngine.Experimental.Rendering.GraphicsFormat.D16_UNorm_S8_UInt)
                desc.depthStencilFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.D16_UNorm;
            else
                desc.depthStencilFormat = renderingData.cameraData.cameraTargetDescriptor.depthStencilFormat;

            if (m_AccurateThickness)
            {
                RenderingUtils.ReAllocateIfNeeded(ref m_BackDepthHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_CameraBackDepthTexture");
                cmd.SetGlobalTexture("_CameraBackDepthTexture", m_BackDepthHandle);

                ConfigureTarget(m_BackDepthHandle);
                ConfigureClear(ClearFlag.Depth, Color.black);
            }

        }
        
        public override void FrameCleanup(CommandBuffer cmd)
        {
            if (m_AccurateThickness)
                cmd.ReleaseTemporaryRT(Shader.PropertyToID(m_BackDepthHandle.name));
        }

        public override void OnCameraCleanup(CommandBuffer cmd)
        {
            if (m_AccurateThickness)
                m_BackDepthHandle = null;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            CommandBuffer cmd = CommandBufferPool.Get();

            // Render backface depth
            if (m_AccurateThickness)
            {
                using (new ProfilingScope(cmd, new ProfilingSampler("Path Tracing Backface Depth")))
                {
                    RendererListDesc rendererListDesc = new RendererListDesc(new ShaderTagId("DepthOnly"), renderingData.cullResults, renderingData.cameraData.camera);
                    m_DepthRenderStateBlock.depthState = new DepthState(true, CompareFunction.LessEqual);
                    m_DepthRenderStateBlock.mask |= RenderStateMask.Depth;
                    m_DepthRenderStateBlock.rasterState = new RasterState(CullMode.Front);
                    m_DepthRenderStateBlock.mask |= RenderStateMask.Raster;
                    rendererListDesc.stateBlock = m_DepthRenderStateBlock;
                    rendererListDesc.sortingCriteria = renderingData.cameraData.defaultOpaqueSortFlags;
                    rendererListDesc.renderQueueRange = new RenderQueueRange(2000, 3000);
                    RendererList rendererList = context.CreateRendererList(rendererListDesc);

                    cmd.DrawRendererList(rendererList);
                }
            }
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            CommandBufferPool.Release(cmd);
        }
    }
}