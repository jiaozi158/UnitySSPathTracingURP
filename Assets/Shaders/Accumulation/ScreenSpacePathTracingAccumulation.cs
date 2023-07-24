using System;
using System.Reflection;
using System.Collections.Generic;
using Unity.Collections;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RendererUtils;
using UnityEngine.Experimental.Rendering;

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
        PerObject = 2,

        [InspectorName("Real-time + Spatial Denoise")]
        [Tooltip("Real-time + Spatial Denoise mode will only execute in play mode.")]
        PerObjectBlur = 3
    };

    public enum AccurateThickness
    {
        [InspectorName("Disable")]
        [Tooltip("Do not render back-face data.")]
        None = 0,

        [InspectorName("Depth")]
        [Tooltip("Render back-face depth.")]
        DepthOnly = 1,

        [InspectorName("Depth + Normals")]
        [Tooltip("Render back-face depth and normals.")]
        DepthNormals = 2
    }

    public enum SpatialDenoise
    {
        [InspectorName("Low")]
        [Tooltip("1-Pass Denoiser.")]
        Low = 0,

        [InspectorName("Medium")]
        [Tooltip("3-Pass Denoiser.")]
        Medium = 1,

        [InspectorName("High")]
        [Tooltip("5-Pass Denoiser.")]
        High = 2,
    }

    [Tooltip("The material of accumulation shader.")]
    public Material m_AccumulationMaterial;
    [Tooltip("The material of path tracing shader.")]
    public Material m_PathTracingMaterial;

    [Header("Path Tracing Extensions")]
    [Tooltip("Render the backface depth of scene geometries. This improves the accuracy of screen space path tracing, but may not work well in scenes with lots of single-sided objects.")]
    public AccurateThickness accurateThickness = AccurateThickness.None;

    [Header("Additional Lighting Models")]
    [Tooltip("Enable this to support Path Tracing refraction.")]
    public bool refraction = false;

    [Header("Temporal Accumulation")]
    [Tooltip("The accumulation mode. Real-time mode will only execute in play mode.")]
    public Accumulation accumulation = Accumulation.Camera;
    [Tooltip("Add a progress bar to show the offline accumulation progress.")]
    public bool progressBar = true;
    [Tooltip("Controls the real-time accumulation denoising intensity.")]
    [Range(0.1f, 0.9f)]
    public float temporalIntensity = 0.5f;

    [Header("Spatial Accumulation")]
    [Tooltip("Enable Edge-Avoiding A-Trous Denoiser.")]
    public SpatialDenoise spatialDenoise = SpatialDenoise.Medium;
    [Tooltip("Use Opaque Texture to avoid blurring rasterized lighting. This requires URP Opaque Texture to be enabled (with any downsampling).")]
    public bool useOpaqueTexture = false;

    // Allow changing settings at runtime.
    public Accumulation AccumulationMode
    {
        get { return accumulation; }
        set
        {
            if (accumulation != value)
            { m_AccumulationPass.sample = 0; accumulation = value; } // Reaccumulate when changing the mode to ensure correct sample weights in offline mode.
        }
    }

    public AccurateThickness AccurateThicknessMode
    {
        get { return accurateThickness; }
        set
        {
            if (accurateThickness != value)
            { m_AccumulationPass.sample = 0; accurateThickness = value; } // Reaccumulate when changing the thickness mode to ensure correct visuals in offline mode.
        }
    }

    public SpatialDenoise SpatialDenoiseQuality
    {
        get { return spatialDenoise; }
        set { spatialDenoise = value; }
    }

    public bool SupportRefraction
    {
        get { return refraction; }
        set
        {
            if (refraction != value)
            { m_AccumulationPass.sample = 0; refraction = value; } // Reaccumulate when changing refraction mode to ensure correct visuals in offline mode.
        }
    }

    public bool ProgressBar
    {
        get { return progressBar; }
        set { progressBar = value; }
    }

    public bool UseOpaqueTexture
    {
        get { return useOpaqueTexture; }
        set { useOpaqueTexture = value; }
    }

    public float TemporalIntensity
    {
        get { return temporalIntensity; }
        set { temporalIntensity = Math.Clamp(value, 0.1f, 0.9f); }
    }

    private const string m_PathTracingShaderName = "Universal Render Pipeline/Screen Space Path Tracing";
    // This shader is also used by denoising.
    private const string m_AccumulationShaderName = "Hidden/AccumulateFrame";
    private SpatialDenoisePass m_SpatialDenoisePass;
    private AccumulationPass m_AccumulationPass;
    private BackfaceDepthPass m_BackfaceDepthPass;
    private TransparentGBufferPass m_TransparentGBufferPass;
    private readonly static FieldInfo renderingModeFieldInfo = typeof(UniversalRenderer).GetField("m_RenderingMode", BindingFlags.NonPublic | BindingFlags.Instance);

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
            m_AccumulationPass = new AccumulationPass(m_AccumulationMaterial, accumulation, progressBar);
            // URP Upscaling is done after "AfterRenderingPostProcessing".
            // Offline: avoid PP-effects (panini projection, ...) distorting the progress bar.
            // Real-time: requires current frame Motion Vectors.
            m_AccumulationPass.renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing;
        }

        if (m_SpatialDenoisePass == null)
        {
            m_SpatialDenoisePass = new SpatialDenoisePass(m_AccumulationMaterial, accumulation, m_AccumulationPass, spatialDenoise);
            // Before TAA and transparents rendering.
            m_SpatialDenoisePass.renderPassEvent = RenderPassEvent.BeforeRenderingTransparents;
        }

        if (m_BackfaceDepthPass == null)
        {
            m_BackfaceDepthPass = new BackfaceDepthPass();
            m_BackfaceDepthPass.renderPassEvent = RenderPassEvent.AfterRenderingOpaques - 1;
        }
        m_BackfaceDepthPass.m_AccurateThickness = accurateThickness;

        if (m_TransparentGBufferPass == null)
        {
            m_TransparentGBufferPass = new TransparentGBufferPass(new string[] { "UniversalGBuffer" });
            m_TransparentGBufferPass.renderPassEvent = RenderPassEvent.AfterRenderingSkybox + 1;
        }

    }

    protected override void Dispose(bool disposing)
    {
        if (m_SpatialDenoisePass != null)
            m_SpatialDenoisePass.Dispose();
        if (m_AccumulationPass != null)
            m_AccumulationPass.Dispose();
        if (m_BackfaceDepthPass != null)
        {
            // Turn off accurate thickness since the render pass is disabled.
            m_PathTracingMaterial.SetFloat("_BackDepthEnabled", 0.0f);
            m_BackfaceDepthPass.Dispose();
        }
        if (m_TransparentGBufferPass! != null)
            m_TransparentGBufferPass.Dispose();
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        var universalRenderer = renderingData.cameraData.renderer as UniversalRenderer;
        var renderingMode = (RenderingMode)renderingModeFieldInfo.GetValue(renderer);
        if (renderingMode == RenderingMode.ForwardPlus)
        {
            m_PathTracingMaterial.EnableKeyword("_FP_REFL_PROBE_ATLAS");
            if (renderingData.cameraData.camera.cameraType == CameraType.Reflection) { m_PathTracingMaterial.SetFloat("_IsProbeCamera", 1.0f); }
            else { m_PathTracingMaterial.SetFloat("_IsProbeCamera", 0.0f); }
        }
        else
        {
            m_PathTracingMaterial.DisableKeyword("_FP_REFL_PROBE_ATLAS");
            m_PathTracingMaterial.SetFloat("_IsProbeCamera", 0.0f);
        }
        // Update accumulation mode each frame since we support runtime changing of these properties.
        m_SpatialDenoisePass.m_Accumulation = accumulation;
        m_SpatialDenoisePass.m_SpatialDenoise = spatialDenoise;
        m_AccumulationPass.m_Accumulation = accumulation;

#if UNITY_EDITOR
        // Motion Vectors of URP SceneView don't get updated each frame when not entering play mode. (Might be fixed when supporting scene view anti-aliasing)
        // Change the method to multi-frame accumulation (offline mode) if SceneView is not in play mode.
        bool isPlayMode = UnityEditor.EditorApplication.isPlaying;
        if (renderingData.cameraData.camera.cameraType == CameraType.SceneView && !isPlayMode && (accumulation == Accumulation.PerObject || accumulation == Accumulation.PerObjectBlur))
        {
            m_SpatialDenoisePass.m_Accumulation = Accumulation.Camera;
            m_AccumulationPass.m_Accumulation = Accumulation.Camera;
        }
#endif

        // No need to accumulate when rendering reflection probes, this will also break game view accumulation.
        bool shouldAccumulate = (accumulation == Accumulation.Camera) ? (renderingData.cameraData.camera.cameraType != CameraType.Reflection) : (renderingData.cameraData.camera.cameraType != CameraType.Reflection && renderingData.cameraData.camera.cameraType != CameraType.Preview);
        if (shouldAccumulate)
        {
            renderer.EnqueuePass(m_SpatialDenoisePass);

            // Update progress bar toggle each frame since we support runtime changing of these properties.
            m_AccumulationPass.m_ProgressBar = progressBar;
            renderer.EnqueuePass(m_AccumulationPass);
        }

        if (accurateThickness != AccurateThickness.None)
        {
            renderer.EnqueuePass(m_BackfaceDepthPass);
            if (accurateThickness == AccurateThickness.DepthOnly)
                m_PathTracingMaterial.SetFloat("_BackDepthEnabled", 1.0f); // DepthOnly
            else
                m_PathTracingMaterial.SetFloat("_BackDepthEnabled", 2.0f); // DepthNormals
        }
        else
        {
            m_PathTracingMaterial.SetFloat("_BackDepthEnabled", 0.0f);
        }

        if (accumulation == Accumulation.PerObject || accumulation == Accumulation.PerObjectBlur)
        {
            m_AccumulationMaterial.SetFloat("_DenoiserIntensity", temporalIntensity);
            m_AccumulationMaterial.SetFloat("_UseOpaqueTexture", useOpaqueTexture ? 1.0f : 0.0f);
        }

        if (refraction)
        {
            m_PathTracingMaterial.SetFloat("_SupportRefraction", 1.0f);
            renderer.EnqueuePass(m_TransparentGBufferPass);
            m_AccumulationMaterial.SetFloat("_TransparentGBuffers", 1.0f);
        }
        else
        {
            m_PathTracingMaterial.SetFloat("_SupportRefraction", 0.0f);
            m_AccumulationMaterial.SetFloat("_TransparentGBuffers", 0.0f);
        }
            
    }

    public class SpatialDenoisePass : ScriptableRenderPass
    {
        private AccumulationPass m_AccumulationPass;
        private Material m_AccumulationMaterial;
        private RTHandle m_AccumulateColorHandle;

        public SpatialDenoise m_SpatialDenoise;
        public Accumulation m_Accumulation;

        public SpatialDenoisePass(Material accuMaterial, Accumulation accumulation, AccumulationPass accumulationPass, SpatialDenoise spatialDenoise)
        {
            m_AccumulationMaterial = accuMaterial;
            m_Accumulation = accumulation;
            m_AccumulationPass = accumulationPass;
            m_SpatialDenoise = spatialDenoise;
        }

        public void Dispose()
        {
            if (m_Accumulation != Accumulation.None)
                m_AccumulateColorHandle?.Release();
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0; // Color and depth cannot be combined in RTHandles

            if (m_Accumulation != Accumulation.None)
                RenderingUtils.ReAllocateIfNeeded(ref m_AccumulateColorHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingAccumulationTexture");

            if (m_AccumulationPass != null && m_AccumulationPass.m_AccumulateColorHandle == null)
                m_AccumulationPass.m_AccumulateColorHandle = m_AccumulateColorHandle;
        }

        public override void FrameCleanup(CommandBuffer cmd)
        {
            if (m_Accumulation != Accumulation.None)
                cmd.ReleaseTemporaryRT(Shader.PropertyToID(m_AccumulateColorHandle.name));
        }

        public override void OnCameraCleanup(CommandBuffer cmd)
        {
            if (m_Accumulation != Accumulation.None)
                m_AccumulateColorHandle = null;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (m_Accumulation == Accumulation.PerObjectBlur && m_SpatialDenoise != SpatialDenoise.Low)
            {
                CommandBuffer cmd = CommandBufferPool.Get();
                using (new ProfilingScope(cmd, new ProfilingSampler("Path Tracing Spatial Denoise")))
                {
                    // Load & Store actions are important to support acculumation.
                    cmd.SetRenderTarget(
                        m_AccumulateColorHandle,
                        RenderBufferLoadAction.DontCare,
                        RenderBufferStoreAction.Store,
                        m_AccumulateColorHandle,
                        RenderBufferLoadAction.DontCare,
                        RenderBufferStoreAction.DontCare);

                    for (int i = 0; i < ((int)m_SpatialDenoise); i++)
                    {
                        cmd.Blit(renderingData.cameraData.renderer.cameraColorTargetHandle, m_AccumulateColorHandle, m_AccumulationMaterial, 3);
                        cmd.Blit(m_AccumulateColorHandle, renderingData.cameraData.renderer.cameraColorTargetHandle.rt, m_AccumulationMaterial, 3);
                    }
                }
                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();
                CommandBufferPool.Release(cmd);
            }
        }
    }

    public class AccumulationPass : ScriptableRenderPass
    {
        public int sample = 0;

        private Material m_AccumulationMaterial;
        public RTHandle m_AccumulateColorHandle;
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

        public AccumulationPass(Material accuMaterial, Accumulation accumulation, bool progressBar)
        {
            m_AccumulationMaterial = accuMaterial;
            m_Accumulation = accumulation;
            m_ProgressBar = progressBar;
        }

        public void Dispose()
        {
            if (m_Accumulation != Accumulation.None)
                m_AccumulateColorHandle?.Release();
            if (m_Accumulation == Accumulation.PerObject || m_Accumulation == Accumulation.PerObjectBlur)
                m_AccumulateHistoryHandle?.Release();
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0; // Color and depth cannot be combined in RTHandles

            if (m_Accumulation != Accumulation.None)
                RenderingUtils.ReAllocateIfNeeded(ref m_AccumulateColorHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingAccumulationTexture");
            if (m_Accumulation == Accumulation.PerObject || m_Accumulation == Accumulation.PerObjectBlur)
            {
                RenderingUtils.ReAllocateIfNeeded(ref m_AccumulateHistoryHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingHistoryTexture");
                cmd.SetGlobalTexture("_PathTracingHistoryTexture", m_AccumulateHistoryHandle);
            }

            ConfigureTarget(renderingData.cameraData.renderer.cameraColorTargetHandle);
            ConfigureClear(ClearFlag.None, Color.black);

            if (m_Accumulation == Accumulation.PerObject || m_Accumulation == Accumulation.PerObjectBlur)
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
            if (m_Accumulation != Accumulation.None)
                cmd.ReleaseTemporaryRT(Shader.PropertyToID(m_AccumulateColorHandle.name));
            if (m_Accumulation == Accumulation.PerObject || m_Accumulation == Accumulation.PerObjectBlur)
                cmd.ReleaseTemporaryRT(Shader.PropertyToID(m_AccumulateHistoryHandle.name));
        }

        public override void OnCameraCleanup(CommandBuffer cmd)
        {
            if (m_Accumulation != Accumulation.None)
                m_AccumulateColorHandle = null;
            if (m_Accumulation == Accumulation.PerObject || m_Accumulation == Accumulation.PerObjectBlur)
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
                    GraphicsFormat currentGraphicsFormat = m_AccumulateColorHandle.rt.graphicsFormat;
                    int maxSample = currentGraphicsFormat == GraphicsFormat.B10G11R11_UFloatPack32 ? 64 : 512;
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
                else if (m_Accumulation == Accumulation.PerObject || m_Accumulation == Accumulation.PerObjectBlur)
                {
                    // Load & Store actions are important to support acculumation.
                    cmd.SetRenderTarget(
                        m_AccumulateColorHandle,
                        RenderBufferLoadAction.Load,
                        RenderBufferStoreAction.Store,
                        m_AccumulateColorHandle,
                        RenderBufferLoadAction.DontCare,
                        RenderBufferStoreAction.DontCare);

                    if (m_Accumulation == Accumulation.PerObjectBlur)
                        cmd.Blit(renderingData.cameraData.renderer.cameraColorTargetHandle, m_AccumulateColorHandle, m_AccumulationMaterial, 3);
                    else
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
        private RTHandle m_BackNormalsHandle;
        public AccurateThickness m_AccurateThickness;

        private RenderStateBlock m_DepthRenderStateBlock = new RenderStateBlock(RenderStateMask.Nothing);

        public void Dispose()
        {
            if (m_AccurateThickness != AccurateThickness.None)
                m_BackDepthHandle?.Release();
            if (m_AccurateThickness == AccurateThickness.DepthNormals)
                m_BackNormalsHandle?.Release();
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var depthDesc = renderingData.cameraData.cameraTargetDescriptor;
            if (renderingData.cameraData.cameraTargetDescriptor.depthStencilFormat == GraphicsFormat.D32_SFloat_S8_UInt)
                depthDesc.depthStencilFormat = GraphicsFormat.D32_SFloat;
            else if (renderingData.cameraData.cameraTargetDescriptor.depthStencilFormat == GraphicsFormat.D24_UNorm_S8_UInt)
                depthDesc.depthStencilFormat = GraphicsFormat.D24_UNorm;
            else if (renderingData.cameraData.cameraTargetDescriptor.depthStencilFormat == GraphicsFormat.D16_UNorm_S8_UInt)
                depthDesc.depthStencilFormat = GraphicsFormat.D16_UNorm;
            else
                depthDesc.depthStencilFormat = renderingData.cameraData.cameraTargetDescriptor.depthStencilFormat;

            if (m_AccurateThickness == AccurateThickness.DepthOnly)
            {
                RenderingUtils.ReAllocateIfNeeded(ref m_BackDepthHandle, depthDesc, FilterMode.Point, TextureWrapMode.Clamp, name: "_CameraBackDepthTexture");
                cmd.SetGlobalTexture("_CameraBackDepthTexture", m_BackDepthHandle);

                ConfigureTarget(m_BackDepthHandle, m_BackDepthHandle);
                ConfigureClear(ClearFlag.Depth, Color.clear);
            }
            else if (m_AccurateThickness == AccurateThickness.DepthNormals)
            {
                var normalsDesc = renderingData.cameraData.cameraTargetDescriptor;
                // normal normal normal packedSmoothness
                // NormalWS range is -1.0 to 1.0, so we need a signed render texture.
                normalsDesc.depthStencilFormat = GraphicsFormat.None;
                if (SystemInfo.IsFormatSupported(GraphicsFormat.R8G8B8A8_SNorm, FormatUsage.Render))
                    normalsDesc.graphicsFormat = GraphicsFormat.R8G8B8A8_SNorm;
                else
                    normalsDesc.graphicsFormat = GraphicsFormat.R16G16B16A16_SFloat;

                RenderingUtils.ReAllocateIfNeeded(ref m_BackDepthHandle, depthDesc, FilterMode.Point, TextureWrapMode.Clamp, name: "_CameraBackDepthTexture");
                cmd.SetGlobalTexture("_CameraBackDepthTexture", m_BackDepthHandle);

                RenderingUtils.ReAllocateIfNeeded(ref m_BackNormalsHandle, normalsDesc, FilterMode.Point, TextureWrapMode.Clamp, name: "_CameraBackNormalsTexture");
                cmd.SetGlobalTexture("_CameraBackNormalsTexture", m_BackNormalsHandle);

                ConfigureTarget(m_BackNormalsHandle, m_BackDepthHandle);
                ConfigureClear(ClearFlag.Color | ClearFlag.Depth, Color.clear);
            }
        }

        public override void FrameCleanup(CommandBuffer cmd)
        {
            if (m_AccurateThickness != AccurateThickness.None)
                cmd.ReleaseTemporaryRT(Shader.PropertyToID(m_BackDepthHandle.name));
            if (m_AccurateThickness == AccurateThickness.DepthNormals)
                cmd.ReleaseTemporaryRT(Shader.PropertyToID(m_BackNormalsHandle.name));
        }

        public override void OnCameraCleanup(CommandBuffer cmd)
        {
            if (m_AccurateThickness != AccurateThickness.None)
                m_BackDepthHandle = null;
            if (m_AccurateThickness == AccurateThickness.DepthNormals)
                m_BackNormalsHandle = null;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            CommandBuffer cmd = CommandBufferPool.Get();

            // Render backface depth
            if (m_AccurateThickness == AccurateThickness.DepthOnly)
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
                    rendererListDesc.renderQueueRange = RenderQueueRange.all;
                    RendererList rendererList = context.CreateRendererList(rendererListDesc);

                    cmd.DrawRendererList(rendererList);
                }
            }
            // Render backface depth + normals
            else if (m_AccurateThickness == AccurateThickness.DepthNormals)
            {
                using (new ProfilingScope(cmd, new ProfilingSampler("Path Tracing Backface Depth Normals")))
                {
                    RendererListDesc rendererListDesc = new RendererListDesc(new ShaderTagId("DepthNormals"), renderingData.cullResults, renderingData.cameraData.camera);
                    m_DepthRenderStateBlock.depthState = new DepthState(true, CompareFunction.LessEqual);
                    m_DepthRenderStateBlock.mask |= RenderStateMask.Depth;
                    m_DepthRenderStateBlock.rasterState = new RasterState(CullMode.Front);
                    m_DepthRenderStateBlock.mask |= RenderStateMask.Raster;
                    rendererListDesc.stateBlock = m_DepthRenderStateBlock;
                    rendererListDesc.sortingCriteria = renderingData.cameraData.defaultOpaqueSortFlags;
                    rendererListDesc.renderQueueRange = RenderQueueRange.all;
                    RendererList rendererList = context.CreateRendererList(rendererListDesc);

                    cmd.DrawRendererList(rendererList);
                }
            }
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            CommandBufferPool.Release(cmd);
        }
    }

    public class TransparentGBufferPass : ScriptableRenderPass
    {
        const string m_ProfilerTag = "Path Tracing Transparent GBuffer";
        private List<ShaderTagId> m_ShaderTagIdList = new List<ShaderTagId>();
        private FilteringSettings m_filter;

        // Depth Priming.
        private RenderStateBlock m_RenderStateBlock = new RenderStateBlock(RenderStateMask.Nothing);

        private RenderStateBlock m_DepthRenderStateBlock = new RenderStateBlock(RenderStateMask.Nothing);

        public RTHandle m_TransparentGBuffer0;
        public RTHandle m_TransparentGBuffer1;
        public RTHandle m_TransparentGBuffer2;
        private RTHandle[] m_TransparentGBuffers;

        //public RTHandle m_BackDepthBuffer;

        public TransparentGBufferPass(string[] PassNames)
        {
            RenderQueueRange queue = RenderQueueRange.transparent;// new RenderQueueRange(3000, 3000);
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
            /*
            using (new ProfilingScope(cmd, new ProfilingSampler("Path Tracing Back Depth")))
            {
                RendererListDesc rendererListDesc = new RendererListDesc(m_ShaderTagIdList[1], renderingData.cullResults, renderingData.cameraData.camera);
                m_DepthRenderStateBlock.depthState = new DepthState(true, CompareFunction.LessEqual);
                m_DepthRenderStateBlock.mask |= RenderStateMask.Depth;
                m_DepthRenderStateBlock.rasterState = new RasterState(CullMode.Front);
                m_DepthRenderStateBlock.mask |= RenderStateMask.Raster;
                rendererListDesc.stateBlock = m_DepthRenderStateBlock;
                rendererListDesc.sortingCriteria = sortingCriteria;
                rendererListDesc.renderQueueRange = m_filter.renderQueueRange;
                RendererList rendererList = context.CreateRendererList(rendererListDesc);

                cmd.SetRenderTarget(m_BackDepthBuffer);
                cmd.ClearRenderTarget(RTClearFlags.Depth, Color.black, 1, 0);

                cmd.DrawRendererList(rendererList);
            }
            */
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            CommandBufferPool.Release(cmd);
        }

        public void Dispose()
        {
            m_TransparentGBuffer0?.Release();
            m_TransparentGBuffer1?.Release();
            m_TransparentGBuffer2?.Release();
            //m_BackDepthBuffer?.Release();
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
            RenderingUtils.ReAllocateIfNeeded(ref m_TransparentGBuffer0, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_TransparentGBuffer0");
            cmd.SetGlobalTexture("_TransparentGBuffer0", m_TransparentGBuffer0);

            // Specular.rgb + Occlusion.a
            desc.graphicsFormat = GetGBufferFormat(1);
            RenderingUtils.ReAllocateIfNeeded(ref m_TransparentGBuffer1, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_TransparentGBuffer1");
            cmd.SetGlobalTexture("_TransparentGBuffer1", m_TransparentGBuffer1);

            // NormalWS.rgb + Smoothness.a
            desc.graphicsFormat = GetGBufferFormat(2);
            RenderingUtils.ReAllocateIfNeeded(ref m_TransparentGBuffer2, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_TransparentGBuffer2");
            cmd.SetGlobalTexture("_TransparentGBuffer2", m_TransparentGBuffer2);

            m_TransparentGBuffers = new RTHandle[] { m_TransparentGBuffer0, m_TransparentGBuffer1, m_TransparentGBuffer2 };

            //RenderingUtils.ReAllocateIfNeeded(ref m_BackDepthBuffer, renderingData.cameraData.cameraTargetDescriptor, FilterMode.Point, TextureWrapMode.Clamp, name: "_CameraBackDepthTexture");
            //cmd.SetGlobalTexture("_CameraBackDepthTexture", m_BackDepthBuffer);

            ConfigureTarget(m_TransparentGBuffers, renderingData.cameraData.renderer.cameraDepthTargetHandle);

            // Require Depth Texture in Forward pipeline.
            ConfigureInput(ScriptableRenderPassInput.Depth);

            // [OpenGL] Reusing the depth buffer seems to cause black glitching artifacts, so clear the existing depth.
            bool isOpenGL = (SystemInfo.graphicsDeviceType == GraphicsDeviceType.OpenGLES3) || (SystemInfo.graphicsDeviceType == GraphicsDeviceType.OpenGLCore); // GLES 2 is deprecated.
            if (isOpenGL)
                ConfigureClear(ClearFlag.Color | ClearFlag.Depth, Color.clear);
            else
                // We have to also clear previous color so that the "background" will remain empty (black) when moving the camera.
                ConfigureClear(ClearFlag.Color, Color.clear);

            // Reduce GBuffer overdraw using the depth from opaque pass. (excluding OpenGL platforms)
            if (!isOpenGL && (renderingData.cameraData.renderType == CameraRenderType.Base || renderingData.cameraData.clearDepth))
            {
                m_RenderStateBlock.depthState = new DepthState(true, CompareFunction.LessEqual);
                m_RenderStateBlock.mask |= RenderStateMask.Depth;
            }
            else if (m_RenderStateBlock.depthState.compareFunction == CompareFunction.Equal)
            {
                m_RenderStateBlock.depthState = new DepthState(true, CompareFunction.LessEqual);
                m_RenderStateBlock.mask |= RenderStateMask.Depth;
            }

            m_RenderStateBlock.blendState = new BlendState
            {
                blendState0 = new RenderTargetBlendState
                {

                    destinationColorBlendMode = BlendMode.Zero,
                    sourceColorBlendMode = BlendMode.One,
                    destinationAlphaBlendMode = BlendMode.Zero,
                    sourceAlphaBlendMode = BlendMode.One,
                    colorBlendOperation = BlendOp.Add,
                    alphaBlendOperation = BlendOp.Add,
                    writeMask = ColorWriteMask.All
                }
            };
            m_RenderStateBlock.mask |= RenderStateMask.Blend;
        }
    }
}