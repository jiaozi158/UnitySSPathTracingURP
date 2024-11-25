using System.Reflection;
using System.Collections.Generic;
using Unity.Collections;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RendererUtils;
using UnityEngine.Experimental.Rendering;

#if UNITY_6000_0_OR_NEWER
using UnityEngine.Rendering.RenderGraphModule;
#endif

[DisallowMultipleRendererFeature("Screen Space Path Tracing Accumulation")]
[Tooltip("The Screen Space Path Tracing effect simulates how light rays interact with objects and materials to compute various effects in screen space.")]
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

    [Tooltip("The material of path tracing shader.")]
    [SerializeField] private Material m_PathTracingMaterial;

    [Header("Path Tracing Extensions")]
    [Tooltip("Render the backface depth of scene geometries. This improves the accuracy of screen space path tracing, but may not work well in scenes with lots of single-sided objects.")]
    [SerializeField] private AccurateThickness accurateThickness = AccurateThickness.DepthOnly;

    [Header("Additional Lighting Models")]
    [Tooltip("Specifies if the effect calculates path tracing refractions.")]
    [SerializeField] private bool refraction = false;

    [Header("Accumulation")]
    [Tooltip("Add a progress bar to show the offline accumulation progress.")]
    [SerializeField] private bool progressBar = true;

    [Tooltip("Specifies the quality of Edge-Avoiding Spatial Denoiser.")]
    [SerializeField] private SpatialDenoise spatialDenoise = SpatialDenoise.Medium;

    /// <summary>
    /// It is suggested to control the accumulation (denoise) mode through SRP volume system.
    /// </summary>
    public Accumulation AccumulationMode
    {
        get
        {
            ScreenSpacePathTracing ssptVolume = VolumeManager.instance.stack.GetComponent<ScreenSpacePathTracing>();
            if (ssptVolume == null) { return Accumulation.None; }
            else { return (Accumulation)ssptVolume.denoiser.value; }
        }
        set
        {
            ScreenSpacePathTracing ssptVolume = VolumeManager.instance.stack.GetComponent<ScreenSpacePathTracing>();
            if (ssptVolume != null && (Accumulation)ssptVolume.denoiser.value != value)
            { if (m_AccumulationPass != null) { m_AccumulationPass.sample = 0; } ssptVolume.denoiser.value = (ScreenSpacePathTracing.DenoiserType)value; } // Reaccumulate when changing the mode to ensure correct sample weights in offline mode.
        }
    }

    /// <summary>
    /// Gets or sets the material of screen space path tracing shader.
    /// </summary>
    /// <value>
    /// The material of screen space path tracing shader.
    /// </value>
    public Material PathTracingMaterial
    {
        get { return m_PathTracingMaterial; }
        set { m_PathTracingMaterial = (value.shader == Shader.Find(m_PathTracingShaderName)) ? value : m_PathTracingMaterial; }
    }

    /// <summary>
    /// Render backface data of scene geometries to improve the accuracy of screen space path tracing.
    /// </summary>
    public AccurateThickness AccurateThicknessMode
    {
        // Force render depth + normals if path tracing refraction is enabled
        get { return refraction ? AccurateThickness.DepthNormals : accurateThickness; }
        set
        {
            if (accurateThickness != value)
            { m_AccumulationPass.sample = 0; accurateThickness = value; } // Reaccumulate when changing the thickness mode to ensure correct visuals in offline mode.
        }
    }

    /// <summary>
    /// Specifies the quality of Edge-Avoiding Spatial Denoiser.
    /// </summary>
    public SpatialDenoise SpatialDenoiseQuality
    {
        get { return spatialDenoise; }
        set { spatialDenoise = value; }
    }

    /// <summary>
    /// Specifies if the effect calculates path tracing refractions.
    /// </summary>
    public bool SupportRefraction
    {
        get { return refraction; }
        set
        {
            if (refraction != value)
            { m_AccumulationPass.sample = 0; refraction = value; } // Reaccumulate when changing refraction mode to ensure correct visuals in offline mode.
        }
    }
    /// <summary>
    /// Add a progress bar to show the offline accumulation progress.
    /// </summary>
    public bool ProgressBar
    {
        get { return progressBar; }
        set { progressBar = value; }
    }

    /// <summary>
    /// SSPT: This method is no longer supported and will be removed in the future.
    /// </summary>
    [System.Obsolete("SSPT: This method is no longer supported and will be removed in the future.")]
    public bool UseOpaqueTexture
    {
        get { return false; }
        set { }
    }

    /// <summary>
    /// SSPT: This method is no longer supported and will be removed in the future. A similar setting has been added to the SSPT Volume.
    /// </summary>
    [System.Obsolete("SSPT: This method is no longer supported and will be removed in the future. A similar setting has been added to the SSPT Volume.")]
    public float TemporalIntensity
    {
        get { return 0.0f; }
        set {  }
    }

    private const string m_PathTracingShaderName = "Hidden/Universal Render Pipeline/Screen Space Path Tracing";
    private readonly string[] m_GBufferPassNames = new string[] { "UniversalGBuffer" };
    private PathTracingPass m_PathTracingPass;
    private AccumulationPass m_AccumulationPass;
    private BackfaceDepthPass m_BackfaceDepthPass;
    private TransparentGBufferPass m_TransparentGBufferPass;
    private ForwardGBufferPass m_ForwardGBufferPass;
    private readonly static FieldInfo renderingModeFieldInfo = typeof(UniversalRenderer).GetField("m_RenderingMode", BindingFlags.NonPublic | BindingFlags.Instance);

    // Used in Forward GBuffer render pass
    private readonly static FieldInfo gBufferFieldInfo = typeof(UniversalRenderer).GetField("m_GBufferPass", BindingFlags.NonPublic | BindingFlags.Instance);

    // [Resolve Later] The "_CameraNormalsTexture" still exists after disabling DepthNormals Prepass, which may cause issue during rendering.
    // So instead of checking the RTHandle, we need to check if DepthNormals Prepass is enqueued.
    //private readonly static FieldInfo normalsTextureFieldInfo = typeof(UniversalRenderer).GetField("m_NormalsTexture", BindingFlags.NonPublic | BindingFlags.Instance);

    // Avoid printing messages every frame
    private bool isMRTLogPrinted = false;
    private bool isMSAALogPrinted = false;
    private bool isMaterialMismatchLogPrinted = false;
    private bool isEmptyMaterialLogPrinted = false;

    // Shader Property IDs
    private static readonly int _MaxSample = Shader.PropertyToID("_MaxSample");
    private static readonly int _Sample = Shader.PropertyToID("_Sample");
    private static readonly int _MaxSteps = Shader.PropertyToID("_MaxSteps");
    private static readonly int _StepSize = Shader.PropertyToID("_StepSize");
    private static readonly int _MaxBounce = Shader.PropertyToID("_MaxBounce");
    private static readonly int _RayCount = Shader.PropertyToID("_RayCount");
    private static readonly int _TemporalIntensity = Shader.PropertyToID("_TemporalIntensity");
    private static readonly int _MaxBrightness = Shader.PropertyToID("_MaxBrightness");
    private static readonly int _IsProbeCamera = Shader.PropertyToID("_IsProbeCamera");
    private static readonly int _BackDepthEnabled = Shader.PropertyToID("_BackDepthEnabled");
    private static readonly int _IsAccumulationPaused = Shader.PropertyToID("_IsAccumulationPaused");
    private static readonly int _PrevInvViewProjMatrix = Shader.PropertyToID("_PrevInvViewProjMatrix");
    private static readonly int _PrevCameraPositionWS = Shader.PropertyToID("_PrevCameraPositionWS");
    private static readonly int _PixelSpreadAngleTangent = Shader.PropertyToID("_PixelSpreadAngleTangent");
    private static readonly int _FrameIndex = Shader.PropertyToID("_FrameIndex");

    private static readonly int _PathTracingEmissionTexture = Shader.PropertyToID("_PathTracingEmissionTexture");
    private static readonly int _CameraDepthTexture = Shader.PropertyToID("_CameraDepthTexture");
    private static readonly int _CameraDepthAttachment = Shader.PropertyToID("_CameraDepthAttachment");
    private static readonly int _CameraBackDepthTexture = Shader.PropertyToID("_CameraBackDepthTexture");
    private static readonly int _CameraBackNormalsTexture = Shader.PropertyToID("_CameraBackNormalsTexture");
    private static readonly int _PathTracingAccumulationTexture = Shader.PropertyToID("_PathTracingAccumulationTexture");
    private static readonly int _PathTracingHistoryTexture = Shader.PropertyToID("_PathTracingHistoryTexture");
    private static readonly int _PathTracingHistoryEmissionTexture = Shader.PropertyToID("_PathTracingHistoryEmissionTexture");
    private static readonly int _PathTracingSampleTexture = Shader.PropertyToID("_PathTracingSampleTexture");
    private static readonly int _PathTracingHistorySampleTexture = Shader.PropertyToID("_PathTracingHistorySampleTexture");
    private static readonly int _PathTracingHistoryDepthTexture = Shader.PropertyToID("_PathTracingHistoryDepthTexture");
    private static readonly int _TransparentGBuffer0 = Shader.PropertyToID("_TransparentGBuffer0");
    private static readonly int _TransparentGBuffer1 = Shader.PropertyToID("_TransparentGBuffer1");
    private static readonly int _TransparentGBuffer2 = Shader.PropertyToID("_TransparentGBuffer2");
    private static readonly int _GBuffer0 = Shader.PropertyToID("_GBuffer0");
    private static readonly int _GBuffer1 = Shader.PropertyToID("_GBuffer1");
    private static readonly int _GBuffer2 = Shader.PropertyToID("_GBuffer2");

    public override void Create()
    {
        if (m_PathTracingMaterial != null)
        {
            if (m_PathTracingMaterial.shader != Shader.Find(m_PathTracingShaderName))
            {
                if (!isMaterialMismatchLogPrinted) 
                { 
                    //Debug.LogErrorFormat("Screen Space Path Tracing: Path Tracing material is not using {0} shader.", m_PathTracingShaderName); 
                    isMaterialMismatchLogPrinted = true;
                }
                return;
            }
            else
                isMaterialMismatchLogPrinted = false;
        }
        else
        {
            if (!isEmptyMaterialLogPrinted) { Debug.LogError("Screen Space Path Tracing: Path Tracing material is empty."); isEmptyMaterialLogPrinted = true; }
            return;
        }
        isEmptyMaterialLogPrinted = false;

        if (m_PathTracingPass == null)
        {
            m_PathTracingPass = new PathTracingPass(m_PathTracingMaterial);
            m_PathTracingPass.renderPassEvent = RenderPassEvent.BeforeRenderingTransparents;
        }

        if (m_AccumulationPass == null)
        {
            m_AccumulationPass = new AccumulationPass(m_PathTracingMaterial, progressBar);
            // URP Upscaling is done after "AfterRenderingPostProcessing".
            // Offline: avoid PP-effects (panini projection, ...) distorting the progress bar.
            // Real-time: requires current frame Motion Vectors.
        #if UNITY_2023_3_OR_NEWER
            // The injection point between URP Post-processing and Final PP was fixed.
            m_AccumulationPass.renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing - 1;
        #else
            m_AccumulationPass.renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing;
        #endif
        }

        if (m_BackfaceDepthPass == null)
        {
            m_BackfaceDepthPass = new BackfaceDepthPass();
            m_BackfaceDepthPass.renderPassEvent = RenderPassEvent.AfterRenderingOpaques - 1;
        }

        m_BackfaceDepthPass.m_AccurateThickness = refraction ? AccurateThickness.DepthNormals : accurateThickness;

        if (m_TransparentGBufferPass == null)
        {
            m_TransparentGBufferPass = new TransparentGBufferPass(m_GBufferPassNames);
            m_TransparentGBufferPass.renderPassEvent = RenderPassEvent.AfterRenderingSkybox + 1;
        }

        if (m_ForwardGBufferPass == null)
        {
            m_ForwardGBufferPass = new ForwardGBufferPass(m_GBufferPassNames);
            // Set this to "After Opaques" so that we can enable GBuffers Depth Priming on non-GL platforms.
            m_ForwardGBufferPass.renderPassEvent = RenderPassEvent.AfterRenderingOpaques;
        }

    }

    protected override void Dispose(bool disposing)
    {
        if (m_PathTracingPass != null)
            m_PathTracingPass.Dispose();
        if (m_AccumulationPass != null)
            m_AccumulationPass.Dispose();
        if (m_BackfaceDepthPass != null)
        {
            // Turn off accurate thickness since the render pass is disabled.
            m_PathTracingMaterial.SetFloat(_BackDepthEnabled, 0.0f);
            m_BackfaceDepthPass.Dispose();
        }
        if (m_TransparentGBufferPass! != null)
            m_TransparentGBufferPass.Dispose();
        if (m_ForwardGBufferPass! != null)
            m_ForwardGBufferPass.Dispose();
    }

    void StoreAmbientSettings(ScreenSpacePathTracing ssptVolume)
    {
        if (!ssptVolume.ambientStored.value)
        {
            ssptVolume.ambientIntensity.value = RenderSettings.ambientIntensity;
            ssptVolume.ambientLight.value = RenderSettings.ambientLight;
            ssptVolume.ambientGroundColor.value = RenderSettings.ambientGroundColor;
            ssptVolume.ambientEquatorColor.value = RenderSettings.ambientEquatorColor;
            ssptVolume.ambientSkyColor.value = RenderSettings.ambientSkyColor;
            ssptVolume.ambientStored.value = true;
        }
    }

    void RestoreAmbientSettings(ScreenSpacePathTracing ssptVolume)
    {
        if (ssptVolume != null && ssptVolume.ambientStored.value)
        {
            RenderSettings.ambientIntensity = ssptVolume.ambientIntensity.value;
            RenderSettings.ambientLight = ssptVolume.ambientLight.value;
            RenderSettings.ambientGroundColor = ssptVolume.ambientGroundColor.value;
            RenderSettings.ambientEquatorColor = ssptVolume.ambientEquatorColor.value;
            RenderSettings.ambientSkyColor = ssptVolume.ambientSkyColor.value;
            ssptVolume.ambientStored.value = false;
        }
    }

    void DisableAmbientSettings(ScreenSpacePathTracing ssptVolume)
    {
        if (ssptVolume.ambientStored.value)
        {
            RenderSettings.ambientIntensity = 0.0f;
            RenderSettings.ambientLight = Color.black;
            RenderSettings.ambientGroundColor = Color.black;
            RenderSettings.ambientEquatorColor = Color.black;
            RenderSettings.ambientSkyColor = Color.black;
        }
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        // Do not add render passes if any error occurs.
        if (isMaterialMismatchLogPrinted || isEmptyMaterialLogPrinted || isMRTLogPrinted)
            return;

        // Currently MSAA is not supported, because we sample the camera depth buffer without resolving AA.
        if (renderingData.cameraData.cameraTargetDescriptor.msaaSamples != 1)
        {
            if (!isMSAALogPrinted) { Debug.LogError("Screen Space Path Tracing: Camera with MSAA enabled is not currently supported."); isMSAALogPrinted = true; }
            return;
        }
        else
            isMSAALogPrinted = false;

        var stack = VolumeManager.instance.stack;
        ScreenSpacePathTracing ssptVolume = stack.GetComponent<ScreenSpacePathTracing>();
        bool isActive = ssptVolume != null && ssptVolume.IsActive();

        // [WIP] Try to automatically adjust the ambient settings (vary by scene) to improve usability.
        if (isActive && this.isActive)
        {
            StoreAmbientSettings(ssptVolume);
            DisableAmbientSettings(ssptVolume);
        }
        else
        {
            RestoreAmbientSettings(ssptVolume);
            if (m_AccumulationPass != null) { m_AccumulationPass.sample = 0; }
            return;
        }

        m_PathTracingMaterial.SetFloat(_MaxSteps, ssptVolume.maximumSteps.value);
        m_PathTracingMaterial.SetFloat(_StepSize, ssptVolume.stepSize.value);
        m_PathTracingMaterial.SetFloat(_MaxBounce, ssptVolume.maximumDepth.value);
        m_PathTracingMaterial.SetFloat(_RayCount, ssptVolume.samplesPerPixel.value);
        m_PathTracingMaterial.SetFloat(_TemporalIntensity, Mathf.Lerp(0.8f, 0.97f, ssptVolume.accumFactor.value * 2.0f - 1.0f));
        m_PathTracingMaterial.SetFloat(_MaxBrightness, ssptVolume.maximumIntensity.value);

        m_AccumulationPass.maximumSample = ssptVolume.maximumSamples.value;
        m_AccumulationPass.ssptVolume = ssptVolume;

        if (ssptVolume.noiseMethod.value == ScreenSpacePathTracing.NoiseType.HashedRandom)
        {
            m_PathTracingMaterial.EnableKeyword("_METHOD_HASHED_RANDOM");
            m_PathTracingMaterial.DisableKeyword("_METHOD_BLUE_NOISE");
        }
        else
        {
            m_PathTracingMaterial.EnableKeyword("_METHOD_BLUE_NOISE");
            m_PathTracingMaterial.DisableKeyword("_METHOD_HASHED_RANDOM");
        }

        if (ssptVolume.denoiser.value == ScreenSpacePathTracing.DenoiserType.Temporal || ssptVolume.denoiser.value == ScreenSpacePathTracing.DenoiserType.SpatialTemporal)
            m_PathTracingMaterial.EnableKeyword("_TEMPORAL_ACCUMULATION");
        else
            m_PathTracingMaterial.DisableKeyword("_TEMPORAL_ACCUMULATION");

        var universalRenderer = renderingData.cameraData.renderer as UniversalRenderer;
        var renderingMode = (RenderingMode)renderingModeFieldInfo.GetValue(renderer);
        if (renderingMode == RenderingMode.ForwardPlus) { m_PathTracingMaterial.EnableKeyword("_FP_REFL_PROBE_ATLAS"); }
        else { m_PathTracingMaterial.DisableKeyword("_FP_REFL_PROBE_ATLAS"); }

        // Update accumulation mode each frame since we support runtime changing of these properties.
        m_AccumulationPass.m_Accumulation = (Accumulation)ssptVolume.denoiser.value;
        m_AccumulationPass.m_SpatialDenoise = spatialDenoise;

        if (renderingData.cameraData.camera.cameraType == CameraType.Reflection) { m_PathTracingMaterial.SetFloat(_IsProbeCamera, 1.0f); }
        else { m_PathTracingMaterial.SetFloat(_IsProbeCamera, 0.0f); }

    #if UNITY_EDITOR
        // Motion Vectors of URP SceneView don't get updated each frame when not entering play mode. (Might be fixed when supporting scene view anti-aliasing)
        // Change the method to multi-frame accumulation (offline mode) if SceneView is not in play mode.
        bool isPlayMode = UnityEditor.EditorApplication.isPlaying;
        if (renderingData.cameraData.camera.cameraType == CameraType.SceneView && !isPlayMode && ((Accumulation)ssptVolume.denoiser.value == Accumulation.PerObject || (Accumulation)ssptVolume.denoiser.value == Accumulation.PerObjectBlur))
            m_AccumulationPass.m_Accumulation = Accumulation.Camera;
    #endif
        // Stop path tracing after reaching the maximum number of offline accumulation samples.
        if (renderingData.cameraData.camera.cameraType != CameraType.Preview && !(m_AccumulationPass.m_Accumulation == Accumulation.Camera && m_AccumulationPass.sample == m_AccumulationPass.maximumSample))
            renderer.EnqueuePass(m_PathTracingPass);

        // No need to accumulate when rendering reflection probes, this will also break game view accumulation.
        bool shouldAccumulate = ((Accumulation)ssptVolume.denoiser.value == Accumulation.Camera) ? (renderingData.cameraData.camera.cameraType != CameraType.Reflection) : (renderingData.cameraData.camera.cameraType != CameraType.Reflection && renderingData.cameraData.camera.cameraType != CameraType.Preview);
        if (shouldAccumulate)
        {
            // Update progress bar toggle each frame since we support runtime changing of these properties.
            m_AccumulationPass.m_ProgressBar = progressBar;
        #if UNITY_6000_0_OR_NEWER
            // [Solution 1]
            // There seems to be a bug related to CopyDepthPass
            // the "After Transparent" option behaves the same as "After Opaque", 
            // and "CopyDepthMode" returns the correct value ("After Transparent") only once, then "After Opaque" every time.
            /*
            FieldInfo copyDepthModeFieldInfo = typeof(UniversalRenderer).GetField("m_CopyDepthMode", BindingFlags.NonPublic | BindingFlags.Instance);
            var copyDepthMode = (CopyDepthMode)copyDepthModeFieldInfo.GetValue(universalRenderer);
            RenderPassEvent accumulationPassEvent = (copyDepthMode != CopyDepthMode.AfterTransparent) ? RenderPassEvent.BeforeRenderingTransparents : RenderPassEvent.AfterRenderingPostProcessing - 1;
            */

            // [Solution 2]
            // Change back to solution 1 when the bug is fixed.
            FieldInfo motionVectorPassFieldInfo = typeof(UniversalRenderer).GetField("m_MotionVectorPass", BindingFlags.NonPublic | BindingFlags.Instance);
            var motionVectorPass = motionVectorPassFieldInfo.GetValue(universalRenderer);
            PropertyInfo renderPassEventPropertyInfo = motionVectorPass.GetType().GetProperty("renderPassEvent", BindingFlags.Public | BindingFlags.Instance);
            if (renderPassEventPropertyInfo != null)
            {
                RenderPassEvent renderPassEvent = (RenderPassEvent)renderPassEventPropertyInfo.GetValue(motionVectorPass);
                m_AccumulationPass.renderPassEvent = (renderPassEvent < RenderPassEvent.AfterRenderingTransparents) ? RenderPassEvent.BeforeRenderingTransparents : RenderPassEvent.AfterRenderingPostProcessing - 1;
            }
            else
                m_AccumulationPass.renderPassEvent = RenderPassEvent.AfterRenderingPostProcessing - 1;
        #endif

        #if UNITY_EDITOR
            // Disable real-time accumulation when motion vectors are not updated (playing & paused) in editor
            if (!(UnityEditor.EditorApplication.isPlaying && UnityEditor.EditorApplication.isPaused && (m_AccumulationPass.m_Accumulation == Accumulation.PerObject || m_AccumulationPass.m_Accumulation == Accumulation.PerObjectBlur)))
                renderer.EnqueuePass(m_AccumulationPass);
        #else
            renderer.EnqueuePass(m_AccumulationPass);
        #endif
        }

        if (m_BackfaceDepthPass.m_AccurateThickness != AccurateThickness.None)
        {
            renderer.EnqueuePass(m_BackfaceDepthPass);
            m_PathTracingMaterial.EnableKeyword("_BACKFACE_TEXTURES");
            if (m_BackfaceDepthPass.m_AccurateThickness == AccurateThickness.DepthOnly)
                m_PathTracingMaterial.SetFloat(_BackDepthEnabled, 1.0f); // DepthOnly
            else
                m_PathTracingMaterial.SetFloat(_BackDepthEnabled, 2.0f); // DepthNormals
        }
        else
        {
            m_PathTracingMaterial.DisableKeyword("_BACKFACE_TEXTURES");
            m_PathTracingMaterial.SetFloat(_BackDepthEnabled, 0.0f);
        }

        if (refraction)
        {
            m_PathTracingMaterial.EnableKeyword("_SUPPORT_REFRACTION");
            renderer.EnqueuePass(m_TransparentGBufferPass);
        }
        else
        {
            m_PathTracingMaterial.DisableKeyword("_SUPPORT_REFRACTION");
        }

        // If GBuffer exists, URP is in Deferred path. (Actual rendering mode can be different from settings, such as URP forces Forward on OpenGL)
        bool isUsingDeferred = gBufferFieldInfo.GetValue(renderer) != null;
        // OpenGL won't use deferred path.
        isUsingDeferred &= (SystemInfo.graphicsDeviceType != GraphicsDeviceType.OpenGLES3) & (SystemInfo.graphicsDeviceType != GraphicsDeviceType.OpenGLCore);  // GLES 2 is deprecated.

        // Render Forward GBuffer pass if the current device supports MRT.
        if (!isUsingDeferred)
        {
            if (SystemInfo.supportedRenderTargetCount >= 3) { renderer.EnqueuePass(m_ForwardGBufferPass); isMRTLogPrinted = false; }
            else { Debug.LogError("Screen Space Path Tracing: The current device does not support rendering to multiple render targets."); isMRTLogPrinted = true; }
        }

    }

    public class PathTracingPass : ScriptableRenderPass
    {
        const string m_ProfilerTag = "Screen Space Path Tracing";
        private readonly ProfilingSampler m_ProfilingSampler = new ProfilingSampler(m_ProfilerTag);

        public Material m_PathTracingMaterial;
        private RTHandle sourceHandle;

        // Time
        private int frameCount = 0;

        public PathTracingPass(Material material)
        {
            m_PathTracingMaterial = material;
        }

        #region Non Render Graph Pass
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            RTHandle colorHandle = renderingData.cameraData.renderer.cameraColorTargetHandle;

            CommandBuffer cmd = CommandBufferPool.Get();
            using (new ProfilingScope(cmd, m_ProfilingSampler))
            {
                Blitter.BlitCameraTexture(cmd, colorHandle, sourceHandle);
                Blitter.BlitCameraTexture(cmd, sourceHandle, colorHandle, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store, m_PathTracingMaterial, pass: 0);
            }
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            CommandBufferPool.Release(cmd);
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            m_PathTracingMaterial.SetFloat(_FrameIndex, frameCount);
            frameCount += 33;
            frameCount %= 64000;

            RenderTextureDescriptor desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0; // Color and depth cannot be combined in RTHandles
            desc.stencilFormat = GraphicsFormat.None;
            desc.msaaSamples = 1; // Do not enable MSAA for GBuffers.

            // Albedo.rgb + MaterialFlags.a
            //desc.graphicsFormat = GetGBufferFormat(0);
            RenderingUtils.ReAllocateIfNeeded(ref sourceHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingEmissionTexture");
            cmd.SetGlobalTexture(_PathTracingEmissionTexture, sourceHandle);
            m_PathTracingMaterial.SetTexture(_PathTracingEmissionTexture, sourceHandle);
            m_PathTracingMaterial.SetTexture(_CameraDepthAttachment, renderingData.cameraData.renderer.cameraDepthTargetHandle);

            ConfigureInput(ScriptableRenderPassInput.Depth);
        }
        #endregion

    #if UNITY_6000_0_OR_NEWER
        #region Render Graph Pass
        // This class stores the data needed by the pass, passed as parameter to the delegate function that executes the pass
        private class PassData
        {
            internal Material pathTracingMaterial;

            internal TextureHandle cameraColorTargetHandle;
            internal TextureHandle cameraDepthTargetHandle;
            internal TextureHandle cameraDepthTextureHandle;
            internal TextureHandle emissionHandle;

            // GBuffers created by URP
            internal bool localGBuffers;
            internal TextureHandle gBuffer0Handle;
            internal TextureHandle gBuffer1Handle;
            internal TextureHandle gBuffer2Handle;
        }

        // This static method is used to execute the pass and passed as the RenderFunc delegate to the RenderGraph render pass
        static void ExecutePass(PassData data, UnsafeGraphContext context)
        {
            CommandBuffer cmd = CommandBufferHelpers.GetNativeCommandBuffer(context.cmd);

            if (data.cameraDepthTextureHandle.IsValid())
                data.pathTracingMaterial.SetTexture(_CameraDepthTexture, data.cameraDepthTextureHandle);

            if (data.localGBuffers)
            {
                data.pathTracingMaterial.SetTexture(_GBuffer0, data.gBuffer0Handle);
                data.pathTracingMaterial.SetTexture(_GBuffer1, data.gBuffer1Handle);
                data.pathTracingMaterial.SetTexture(_GBuffer2, data.gBuffer2Handle);
            }
            else
            {
                // Global gbuffer textures
                data.pathTracingMaterial.SetTexture(_GBuffer0, null);
                data.pathTracingMaterial.SetTexture(_GBuffer1, null);
                data.pathTracingMaterial.SetTexture(_GBuffer2, null);
            }

            data.pathTracingMaterial.SetTexture(_CameraDepthAttachment, data.cameraDepthTargetHandle);
            data.pathTracingMaterial.SetTexture(_PathTracingEmissionTexture, data.emissionHandle);

            Blitter.BlitCameraTexture(cmd, data.cameraColorTargetHandle, data.emissionHandle);

            Blitter.BlitCameraTexture(cmd, data.emissionHandle, data.cameraColorTargetHandle, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store, data.pathTracingMaterial, pass: 0);
        }

        // This is where the renderGraph handle can be accessed.
        // Each ScriptableRenderPass can use the RenderGraph handle to add multiple render passes to the render graph
        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            // add an unsafe render pass to the render graph, specifying the name and the data type that will be passed to the ExecutePass function
            using (var builder = renderGraph.AddUnsafePass<PassData>(m_ProfilerTag, out var passData))
            {
                // UniversalResourceData contains all the texture handles used by the renderer, including the active color and depth textures
                // The active color and depth textures are the main color and depth buffers that the camera renders into
                UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
                UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();

                m_PathTracingMaterial.SetFloat(_FrameIndex, frameCount);
                frameCount += 33;
                frameCount %= 64000;

                RenderTextureDescriptor desc = cameraData.cameraTargetDescriptor;
                desc.depthBufferBits = 0; // Color and depth cannot be combined in RTHandles
                desc.stencilFormat = GraphicsFormat.None;
                desc.msaaSamples = 1;

                TextureHandle emissionHandle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, desc, name: "_PathTracingEmissionTexture", false, FilterMode.Point, TextureWrapMode.Clamp);
                builder.SetGlobalTextureAfterPass(emissionHandle, _PathTracingEmissionTexture);

                ConfigureInput(ScriptableRenderPassInput.Depth);

                // Fill up the passData with the data needed by the pass
                passData.pathTracingMaterial = m_PathTracingMaterial;
                passData.cameraColorTargetHandle = resourceData.activeColorTexture;
                passData.cameraDepthTargetHandle = resourceData.activeDepthTexture;
                passData.emissionHandle = emissionHandle;

                // UnsafePasses don't setup the outputs using UseTextureFragment/UseTextureFragmentDepth, you should specify your writes with UseTexture instead
                builder.UseTexture(passData.cameraColorTargetHandle, AccessFlags.ReadWrite);
                builder.UseTexture(passData.cameraDepthTargetHandle, AccessFlags.Write);
                builder.UseTexture(passData.emissionHandle, AccessFlags.ReadWrite);

                passData.localGBuffers = resourceData.gBuffer[0].IsValid();

                if (passData.localGBuffers)
                {
                    passData.gBuffer0Handle = resourceData.gBuffer[0];
                    passData.gBuffer1Handle = resourceData.gBuffer[1];
                    passData.gBuffer2Handle = resourceData.gBuffer[2];

                    builder.UseTexture(passData.gBuffer0Handle, AccessFlags.Read);
                    builder.UseTexture(passData.gBuffer1Handle, AccessFlags.Read);
                    builder.UseTexture(passData.gBuffer2Handle, AccessFlags.Read);
                }

                // We disable culling for this pass for the demonstrative purpose of this sample, as normally this pass would be culled,
                // since the destination texture is not used anywhere else
                //builder.AllowGlobalStateModification(true);
                //builder.AllowPassCulling(false);

                // Assign the ExecutePass function to the render pass delegate, which will be called by the render graph when executing the pass
                builder.SetRenderFunc((PassData data, UnsafeGraphContext context) => ExecutePass(data, context));
            }
        }
        #endregion
    #endif

        #region Shared
        public void Dispose()
        {
            sourceHandle?.Release();
        }
        #endregion
    }

    public class AccumulationPass : ScriptableRenderPass
    {
        const string m_ProfilerTag = "Path Tracing Accumulation";
        private readonly ProfilingSampler m_ProfilingSampler = new ProfilingSampler(m_ProfilerTag);

        // Curren Sample
        public int sample = 0;
        // Maximum Sample
        public int maximumSample = 64;

        public ScreenSpacePathTracing ssptVolume;

        private Material m_PathTracingMaterial;

        public RTHandle m_AccumulateColorHandle;
        private RTHandle m_AccumulateHistoryHandle;
        private RTHandle m_HistoryEmissionHandle;
        private RTHandle m_AccumulateSampleHandle;
        private RTHandle m_AccumulateHistorySampleHandle;
        private RTHandle m_HistoryDepthHandle;

        public SpatialDenoise m_SpatialDenoise;
        public Accumulation m_Accumulation;
        public bool m_ProgressBar;

        // Reset the offline accumulation when scene has changed.
        // This is not perfect because we cannot detect per mesh changes or per light changes.
        private Matrix4x4 prevCamWorldMatrix;
        private Matrix4x4 prevCamHClipMatrix;
        private NativeArray<VisibleLight> prevLightsList;
        private NativeArray<VisibleReflectionProbe> prevProbesList;

        private Matrix4x4 prevCamInvVPMatrix;
        private Vector3 prevCameraPositionWS;

    #if UNITY_EDITOR
        private bool prevPlayState;
    #endif

        public AccumulationPass(Material pathTracingMaterial, bool progressBar)
        {
            m_PathTracingMaterial = pathTracingMaterial;
            m_ProgressBar = progressBar;
        }

        #region Non Render Graph Pass

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0; // Color and depth cannot be combined in RTHandles

            if (m_Accumulation != Accumulation.None)
                RenderingUtils.ReAllocateIfNeeded(ref m_AccumulateColorHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingAccumulationTexture");
            if (m_Accumulation == Accumulation.PerObject || m_Accumulation == Accumulation.PerObjectBlur)
            {
                RenderingUtils.ReAllocateIfNeeded(ref m_AccumulateHistoryHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingHistoryTexture");
                cmd.SetGlobalTexture(_PathTracingHistoryTexture, m_AccumulateHistoryHandle);

                RenderingUtils.ReAllocateIfNeeded(ref m_HistoryEmissionHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingHistoryEmissionTexture");
                cmd.SetGlobalTexture(_PathTracingHistoryEmissionTexture, m_HistoryEmissionHandle);

                desc.colorFormat = RenderTextureFormat.RHalf;
                RenderingUtils.ReAllocateIfNeeded(ref m_AccumulateSampleHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingSampleTexture");
                cmd.SetGlobalTexture(_PathTracingSampleTexture, m_AccumulateSampleHandle);

                RenderingUtils.ReAllocateIfNeeded(ref m_AccumulateHistorySampleHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingHistorySampleTexture");
                cmd.SetGlobalTexture(_PathTracingHistorySampleTexture, m_AccumulateHistorySampleHandle);

                desc.colorFormat = RenderTextureFormat.RFloat;
                RenderingUtils.ReAllocateIfNeeded(ref m_HistoryDepthHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingHistoryDepthTexture");
                cmd.SetGlobalTexture(_PathTracingHistoryDepthTexture, m_HistoryDepthHandle);
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

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            CommandBuffer cmd = CommandBufferPool.Get();
            using (new ProfilingScope(cmd, m_ProfilingSampler))
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

                    m_PathTracingMaterial.SetFloat(_Sample, sample);

                    // If the HDR precision is set to 64 Bits, the maximum sample can be 512.
                    GraphicsFormat currentGraphicsFormat = m_AccumulateColorHandle.rt.graphicsFormat;
                    int maxSample = currentGraphicsFormat == GraphicsFormat.B10G11R11_UFloatPack32 ? 64 : maximumSample;
                    m_PathTracingMaterial.SetFloat(_MaxSample, maxSample);
                    bool isPaused = false;
                #if UNITY_EDITOR
                    if (prevPlayState != UnityEditor.EditorApplication.isPlaying) { sample = 0; }
                    prevPlayState = UnityEditor.EditorApplication.isPlaying;
                    isPaused = UnityEditor.EditorApplication.isPlaying && UnityEditor.EditorApplication.isPaused;
                #endif
                    m_PathTracingMaterial.SetFloat(_IsAccumulationPaused, isPaused ? 1.0f : 0.0f);
                    if (sample < maxSample && !isPaused)
                        sample++;
                }

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

                    Blitter.BlitCameraTexture(cmd, renderingData.cameraData.renderer.cameraColorTargetHandle, m_AccumulateColorHandle, m_PathTracingMaterial, pass: 3);

                    if (m_ProgressBar == true)
                        Blitter.BlitCameraTexture(cmd, m_AccumulateColorHandle, renderingData.cameraData.renderer.cameraColorTargetHandle, m_PathTracingMaterial, pass: 4);
                    else
                        Blitter.BlitCameraTexture(cmd, m_AccumulateColorHandle, renderingData.cameraData.renderer.cameraColorTargetHandle);
                }
                else if (m_Accumulation == Accumulation.PerObject || m_Accumulation == Accumulation.PerObjectBlur)
                {
                    // Load & Store actions are important to support acculumation.
                    /*
                    cmd.SetRenderTarget(
                        m_AccumulateSampleHandle,
                        RenderBufferLoadAction.Load,
                        RenderBufferStoreAction.Store,
                        m_AccumulateSampleHandle,
                        RenderBufferLoadAction.DontCare,
                        RenderBufferStoreAction.DontCare);
                    */

                    cmd.SetRenderTarget(
                        m_AccumulateColorHandle,
                        RenderBufferLoadAction.Load,
                        RenderBufferStoreAction.Store,
                        m_AccumulateColorHandle,
                        RenderBufferLoadAction.DontCare,
                        RenderBufferStoreAction.DontCare);

                    // [Spatial Denoise]
                    if (m_Accumulation == Accumulation.PerObjectBlur)
                    {
                        for (int i = 0; i < ((int)m_SpatialDenoise); i++)
                        {
                            Blitter.BlitCameraTexture(cmd, renderingData.cameraData.renderer.cameraColorTargetHandle, m_AccumulateColorHandle, m_PathTracingMaterial, pass: 5);
                            Blitter.BlitCameraTexture(cmd, m_AccumulateColorHandle, renderingData.cameraData.renderer.cameraColorTargetHandle, m_PathTracingMaterial, pass: 5);
                        }

                        Blitter.BlitCameraTexture(cmd, renderingData.cameraData.renderer.cameraColorTargetHandle, m_AccumulateColorHandle, m_PathTracingMaterial, pass: 5);
                    }
                    else
                        Blitter.BlitCameraTexture(cmd, renderingData.cameraData.renderer.cameraColorTargetHandle, m_AccumulateColorHandle);

                    // [Temporal Accumulation]
                    var camera = renderingData.cameraData.camera;
                    if (prevCamInvVPMatrix != null)
                        m_PathTracingMaterial.SetMatrix(_PrevInvViewProjMatrix, prevCamInvVPMatrix);
                    else
                    {
                        m_PathTracingMaterial.SetMatrix(_PrevInvViewProjMatrix, camera.previousViewProjectionMatrix.inverse);
                    }
                    if (prevCameraPositionWS != null)
                        m_PathTracingMaterial.SetVector(_PrevCameraPositionWS, prevCameraPositionWS);
                    else
                        m_PathTracingMaterial.SetVector(_PrevCameraPositionWS, camera.transform.position);

                    prevCamInvVPMatrix = (renderingData.cameraData.GetGPUProjectionMatrix() * renderingData.cameraData.GetViewMatrix()).inverse;
                    prevCameraPositionWS = camera.transform.position;

                    m_PathTracingMaterial.SetFloat(_PixelSpreadAngleTangent, Mathf.Tan(camera.fieldOfView * Mathf.Deg2Rad * 0.5f) * 2.0f / Mathf.Min(camera.scaledPixelWidth, camera.scaledPixelHeight));

                    RenderTargetIdentifier[] rTHandles = new RenderTargetIdentifier[2];
                    rTHandles[0] = renderingData.cameraData.renderer.cameraColorTargetHandle;
                    rTHandles[1] = m_AccumulateSampleHandle;
                    // RT-1: accumulated results
                    // RT-2: accumulated sample count
                    cmd.SetRenderTarget(rTHandles, m_AccumulateSampleHandle);
                    Blitter.BlitTexture(cmd, m_AccumulateColorHandle, new Vector4(1.0f, 1.0f, 0.0f, 0.0f), m_PathTracingMaterial, pass: 1);

                    cmd.SetRenderTarget(
                        m_AccumulateHistoryHandle,
                        RenderBufferLoadAction.Load,
                        RenderBufferStoreAction.Store,
                        m_AccumulateHistoryHandle,
                        RenderBufferLoadAction.DontCare,
                        RenderBufferStoreAction.DontCare);
                    // Copy history emission color
                    Blitter.BlitCameraTexture(cmd, renderingData.cameraData.renderer.cameraColorTargetHandle, m_HistoryEmissionHandle, m_PathTracingMaterial, pass: 6);
                    // Copy history color
                    Blitter.BlitCameraTexture(cmd, renderingData.cameraData.renderer.cameraColorTargetHandle, m_AccumulateHistoryHandle);
                    // Copy history sample count
                    Blitter.BlitCameraTexture(cmd, m_AccumulateSampleHandle, m_AccumulateHistorySampleHandle);
                    // Copy history depth
                    Blitter.BlitCameraTexture(cmd, m_HistoryDepthHandle, m_HistoryDepthHandle, m_PathTracingMaterial, pass: 2);
                }
                //*/

            }
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            CommandBufferPool.Release(cmd);
        }
    #endregion

    #if UNITY_6000_0_OR_NEWER
        #region Render Graph Pass
        // This class stores the data needed by the pass, passed as parameter to the delegate function that executes the pass
        private class PassData
        {
            internal Material pathTracingMaterial;

            internal bool progressBar;
            internal Accumulation accumulationMode;
            internal SpatialDenoise spatialDenoiseMode;

            internal TextureHandle cameraColorTargetHandle;
            internal TextureHandle cameraDepthTargetHandle;

            internal TextureHandle accumulateColorHandle;
            internal TextureHandle accumulateHistoryHandle;
            internal TextureHandle historyEmissionHandle;
            internal TextureHandle accumulateSampleHandle;
            internal TextureHandle accumulateHistorySampleHandle;
            internal TextureHandle historyDepthHandle;
        }

        // This static method is used to execute the pass and passed as the RenderFunc delegate to the RenderGraph render pass
        static void ExecutePass(PassData data, UnsafeGraphContext context)
        {
            CommandBuffer cmd = CommandBufferHelpers.GetNativeCommandBuffer(context.cmd);

            // Load & Store actions are important to support acculumation.
            if (data.accumulationMode == Accumulation.Camera)
            {
                cmd.SetRenderTarget(
                data.accumulateColorHandle,
                RenderBufferLoadAction.Load,
                RenderBufferStoreAction.Store,
                data.accumulateColorHandle,
                RenderBufferLoadAction.DontCare,
                RenderBufferStoreAction.DontCare);

                Blitter.BlitCameraTexture(cmd, data.cameraColorTargetHandle, data.accumulateColorHandle, data.pathTracingMaterial, pass: 3);

                if (data.progressBar)
                    Blitter.BlitCameraTexture(cmd, data.accumulateColorHandle, data.cameraColorTargetHandle, data.pathTracingMaterial, pass: 4);
                else
                    Blitter.BlitCameraTexture(cmd, data.accumulateColorHandle, data.cameraColorTargetHandle);
            }
            else if (data.accumulationMode == Accumulation.PerObject || data.accumulationMode == Accumulation.PerObjectBlur)
            {
                // Load & Store actions are important to support acculumation.
                cmd.SetRenderTarget(
                    data.accumulateColorHandle,
                    RenderBufferLoadAction.Load,
                    RenderBufferStoreAction.Store,
                    data.accumulateColorHandle,
                    RenderBufferLoadAction.DontCare,
                    RenderBufferStoreAction.DontCare);

                // [Spatial Denoise]
                if (data.accumulationMode == Accumulation.PerObjectBlur)
                {
                    for (int i = 0; i < ((int)data.spatialDenoiseMode); i++)
                    {
                        Blitter.BlitCameraTexture(cmd, data.cameraColorTargetHandle, data.accumulateColorHandle, data.pathTracingMaterial, pass: 5);
                        Blitter.BlitCameraTexture(cmd, data.accumulateColorHandle, data.cameraColorTargetHandle, data.pathTracingMaterial, pass: 5);
                    }

                    Blitter.BlitCameraTexture(cmd, data.cameraColorTargetHandle, data.accumulateColorHandle, data.pathTracingMaterial, pass: 5);
                }
                else
                    Blitter.BlitCameraTexture(cmd, data.cameraColorTargetHandle, data.accumulateColorHandle);

                cmd.SetRenderTarget(
                    data.accumulateSampleHandle,
                    RenderBufferLoadAction.Load,
                    RenderBufferStoreAction.Store,
                    data.accumulateSampleHandle,
                    RenderBufferLoadAction.DontCare,
                    RenderBufferStoreAction.DontCare);

                RenderTargetIdentifier[] rTHandles = new RenderTargetIdentifier[2];
                rTHandles[0] = data.cameraColorTargetHandle;
                rTHandles[1] = data.accumulateSampleHandle;
                // RT-1: accumulated results
                // RT-2: accumulated sample count
                cmd.SetRenderTarget(rTHandles, data.accumulateSampleHandle);
                Blitter.BlitTexture(cmd, data.accumulateColorHandle, new Vector4(1.0f, 1.0f, 0.0f, 0.0f), data.pathTracingMaterial, pass: 1);

                cmd.SetRenderTarget(
                    data.accumulateHistoryHandle,
                    RenderBufferLoadAction.Load,
                    RenderBufferStoreAction.Store,
                    data.accumulateHistoryHandle,
                    RenderBufferLoadAction.DontCare,
                    RenderBufferStoreAction.DontCare);
                // Copy history emission color
                Blitter.BlitCameraTexture(cmd, data.historyEmissionHandle, data.historyEmissionHandle, data.pathTracingMaterial, pass: 6);
                // Copy history color
                Blitter.BlitCameraTexture(cmd, data.cameraColorTargetHandle, data.accumulateHistoryHandle);
                // Copy history sample count
                cmd.SetRenderTarget(
                    data.accumulateHistorySampleHandle,
                    RenderBufferLoadAction.Load,
                    RenderBufferStoreAction.Store,
                    data.accumulateHistorySampleHandle,
                    RenderBufferLoadAction.DontCare,
                    RenderBufferStoreAction.DontCare);

                Blitter.BlitCameraTexture(cmd, data.accumulateSampleHandle, data.accumulateHistorySampleHandle);
                // Copy history depth
                Blitter.BlitCameraTexture(cmd, data.historyDepthHandle, data.historyDepthHandle, data.pathTracingMaterial, pass: 2);
            }
        }

        // This is where the renderGraph handle can be accessed.
        // Each ScriptableRenderPass can use the RenderGraph handle to add multiple render passes to the render graph
        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            // add an unsafe render pass to the render graph, specifying the name and the data type that will be passed to the ExecutePass function
            using (var builder = renderGraph.AddUnsafePass<PassData>(m_ProfilerTag, out var passData))
            {
                // UniversalResourceData contains all the texture handles used by the renderer, including the active color and depth textures
                // The active color and depth textures are the main color and depth buffers that the camera renders into
                UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
                UniversalRenderingData universalRenderingData = frameData.Get<UniversalRenderingData>();
                UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
                UniversalLightData lightData = frameData.Get<UniversalLightData>();

                RenderTextureDescriptor desc = cameraData.cameraTargetDescriptor;
                desc.msaaSamples = 1;
                desc.depthBufferBits = 0;

                if (m_Accumulation == Accumulation.Camera)
                {
                    Matrix4x4 camWorldMatrix = cameraData.camera.cameraToWorldMatrix;
                    Matrix4x4 camHClipMatrix = cameraData.camera.projectionMatrix;

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

                    bool lightsNoUpdate = prevLightsList != null && prevLightsList == lightData.visibleLights;
                    bool probesNoUpdate = prevProbesList != null && prevProbesList == universalRenderingData.cullResults.visibleReflectionProbes;
                    if (!lightsNoUpdate || !probesNoUpdate)
                    {
                        sample = 0;
                    }

                    prevLightsList = lightData.visibleLights;
                    prevProbesList = universalRenderingData.cullResults.visibleReflectionProbes;

                    m_PathTracingMaterial.SetFloat(_Sample, sample);

                    // If the HDR precision is set to 64 Bits, the maximum sample can be 512.
                    GraphicsFormat currentGraphicsFormat = cameraData.cameraTargetDescriptor.graphicsFormat;
                    int maxSample = currentGraphicsFormat == GraphicsFormat.B10G11R11_UFloatPack32 ? 64 : maximumSample;
                    m_PathTracingMaterial.SetFloat(_MaxSample, maxSample);
                    bool isPaused = false;
                #if UNITY_EDITOR
                    if (prevPlayState != UnityEditor.EditorApplication.isPlaying) { sample = 0; }
                    prevPlayState = UnityEditor.EditorApplication.isPlaying;
                    isPaused = UnityEditor.EditorApplication.isPlaying && UnityEditor.EditorApplication.isPaused;
                #endif
                    m_PathTracingMaterial.SetFloat(_IsAccumulationPaused, isPaused ? 1.0f : 0.0f);
                    if (sample < maxSample && !isPaused)
                        sample++;
                }
                else
                {
                    sample = 0;
                }

                passData.pathTracingMaterial = m_PathTracingMaterial;
                passData.progressBar = m_ProgressBar;
                passData.accumulationMode = m_Accumulation;
                passData.spatialDenoiseMode = m_SpatialDenoise;

                passData.cameraColorTargetHandle = resourceData.activeColorTexture;
                builder.UseTexture(passData.cameraColorTargetHandle, AccessFlags.ReadWrite);

                passData.cameraDepthTargetHandle = resourceData.activeDepthTexture;
                builder.UseTexture(passData.cameraDepthTargetHandle, AccessFlags.Write);

                TextureHandle accumulateHistoryHandle;
                TextureHandle historyEmissionHandle;
                TextureHandle accumulateSampleHandle;
                TextureHandle accumulateHistorySampleHandle;
                TextureHandle historyDepthHandle;

                // We decide to directly allocate RTHandles because these textures are stored across frames, which means they cannot be reused in other passes.
                RenderingUtils.ReAllocateHandleIfNeeded(ref m_AccumulateColorHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingAccumulationTexture");
                m_PathTracingMaterial.SetTexture(_PathTracingAccumulationTexture, m_AccumulateColorHandle);
                TextureHandle accumulateColorHandle = renderGraph.ImportTexture(m_AccumulateColorHandle);
                passData.accumulateColorHandle = accumulateColorHandle;

                builder.UseTexture(accumulateColorHandle, AccessFlags.ReadWrite);

                if (m_Accumulation == Accumulation.PerObject || m_Accumulation == Accumulation.PerObjectBlur)
                {
                    // [Temporal Accumulation]
                    var camera = cameraData.camera;
                    if (prevCamInvVPMatrix != null)
                        m_PathTracingMaterial.SetMatrix(_PrevInvViewProjMatrix, prevCamInvVPMatrix);
                    else
                        m_PathTracingMaterial.SetMatrix(_PrevInvViewProjMatrix, camera.previousViewProjectionMatrix.inverse);

                    if (prevCameraPositionWS != null)
                        m_PathTracingMaterial.SetVector(_PrevCameraPositionWS, prevCameraPositionWS);
                    else
                        m_PathTracingMaterial.SetVector(_PrevCameraPositionWS, camera.transform.position);

                    prevCamInvVPMatrix = (GL.GetGPUProjectionMatrix(camera.nonJitteredProjectionMatrix, true) * cameraData.GetViewMatrix()).inverse;// (cameraData.GetGPUProjectionMatrix() * cameraData.GetViewMatrix()).inverse;
                    prevCameraPositionWS = camera.transform.position;

                    m_PathTracingMaterial.SetFloat(_PixelSpreadAngleTangent, Mathf.Tan(camera.fieldOfView * Mathf.Deg2Rad * 0.5f) * 2.0f / Mathf.Min(camera.scaledPixelWidth, camera.scaledPixelHeight));

                    RenderingUtils.ReAllocateHandleIfNeeded(ref m_AccumulateHistoryHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingHistoryTexture");
                    RenderingUtils.ReAllocateHandleIfNeeded(ref m_HistoryEmissionHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingHistoryEmissionTexture");
                    m_PathTracingMaterial.SetTexture(_PathTracingHistoryTexture, m_AccumulateHistoryHandle);
                    m_PathTracingMaterial.SetTexture(_PathTracingHistoryEmissionTexture, m_HistoryEmissionHandle);
                    accumulateHistoryHandle = renderGraph.ImportTexture(m_AccumulateHistoryHandle);
                    historyEmissionHandle = renderGraph.ImportTexture(m_HistoryEmissionHandle);

                    desc.colorFormat = RenderTextureFormat.RHalf;
                    RenderingUtils.ReAllocateHandleIfNeeded(ref m_AccumulateSampleHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingSampleTexture");
                    RenderingUtils.ReAllocateHandleIfNeeded(ref m_AccumulateHistorySampleHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingHistorySampleTexture");
                    m_PathTracingMaterial.SetTexture(_PathTracingSampleTexture, m_AccumulateSampleHandle);
                    m_PathTracingMaterial.SetTexture(_PathTracingHistorySampleTexture, m_AccumulateHistorySampleHandle);
                    accumulateSampleHandle = renderGraph.ImportTexture(m_AccumulateSampleHandle);
                    accumulateHistorySampleHandle = renderGraph.ImportTexture(m_AccumulateHistorySampleHandle);

                    desc.colorFormat = RenderTextureFormat.RFloat;
                    RenderingUtils.ReAllocateHandleIfNeeded(ref m_HistoryDepthHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingHistoryDepthTexture");
                    m_PathTracingMaterial.SetTexture(_PathTracingHistoryDepthTexture, m_HistoryDepthHandle);
                    historyDepthHandle = renderGraph.ImportTexture(m_HistoryDepthHandle);

                    passData.accumulateHistoryHandle = accumulateHistoryHandle;
                    passData.historyEmissionHandle = historyEmissionHandle;
                    passData.accumulateSampleHandle = accumulateSampleHandle;
                    passData.accumulateHistorySampleHandle = accumulateHistorySampleHandle;
                    passData.historyDepthHandle = historyDepthHandle;

                    ConfigureInput(ScriptableRenderPassInput.Motion);

                    builder.UseTexture(accumulateHistoryHandle, AccessFlags.ReadWrite);
                    builder.UseTexture(historyEmissionHandle, AccessFlags.ReadWrite);
                    builder.UseTexture(accumulateSampleHandle, AccessFlags.ReadWrite);
                    builder.UseTexture(accumulateHistorySampleHandle, AccessFlags.ReadWrite);
                    builder.UseTexture(historyDepthHandle, AccessFlags.ReadWrite);
                    builder.UseTexture(resourceData.motionVectorColor, AccessFlags.Read);

                    builder.SetGlobalTextureAfterPass(accumulateHistoryHandle, _PathTracingHistoryTexture);
                    builder.SetGlobalTextureAfterPass(historyEmissionHandle, _PathTracingHistoryEmissionTexture);
                    builder.SetGlobalTextureAfterPass(accumulateSampleHandle, _PathTracingSampleTexture);
                    builder.SetGlobalTextureAfterPass(accumulateHistorySampleHandle, _PathTracingHistorySampleTexture);
                    builder.SetGlobalTextureAfterPass(historyDepthHandle, _PathTracingHistoryDepthTexture);
                }

                builder.SetGlobalTextureAfterPass(accumulateColorHandle, _PathTracingAccumulationTexture);

                // We disable culling for this pass for the demonstrative purpose of this sample, as normally this pass would be culled,
                // since the destination texture is not used anywhere else
                //builder.AllowGlobalStateModification(true);
                //builder.AllowPassCulling(false);

                // Assign the ExecutePass function to the render pass delegate, which will be called by the render graph when executing the pass
                builder.SetRenderFunc((PassData data, UnsafeGraphContext context) => ExecutePass(data, context));
            }
        }
        #endregion
    #endif

        #region Shared
        public void Dispose()
        {
            if (m_Accumulation != Accumulation.None)
                m_AccumulateColorHandle?.Release();
            if (m_Accumulation == Accumulation.PerObject || m_Accumulation == Accumulation.PerObjectBlur)
            {
                m_AccumulateHistoryHandle?.Release();
                m_HistoryEmissionHandle?.Release();
                m_AccumulateSampleHandle?.Release();
                m_HistoryDepthHandle?.Release();
            }
        }
        #endregion
    }

    public class BackfaceDepthPass : ScriptableRenderPass
    {
        const string m_ProfilerTag = "Path Tracing Backface Data";
        private readonly ProfilingSampler m_ProfilingSampler = new ProfilingSampler(m_ProfilerTag);

        private RTHandle m_BackDepthHandle;
        private RTHandle m_BackNormalsHandle;
        public AccurateThickness m_AccurateThickness;

        private RenderStateBlock m_DepthRenderStateBlock = new RenderStateBlock(RenderStateMask.Nothing);

        #region Non Render Graph Pass

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
                cmd.SetGlobalTexture(_CameraBackDepthTexture, m_BackDepthHandle);

                ConfigureTarget(m_BackDepthHandle, m_BackDepthHandle);
                ConfigureClear(ClearFlag.Depth, Color.clear);
            }
            else if (m_AccurateThickness == AccurateThickness.DepthNormals)
            {
                var normalsDesc = renderingData.cameraData.cameraTargetDescriptor;
                // normal normal normal packedSmoothness
                // NormalWS range is -1.0 to 1.0, so we need a signed render texture.
                normalsDesc.depthStencilFormat = GraphicsFormat.None;
            #if UNITY_2023_2_OR_NEWER
                if (SystemInfo.IsFormatSupported(GraphicsFormat.R8G8B8A8_SNorm, GraphicsFormatUsage.Render))
            #else
                if (SystemInfo.IsFormatSupported(GraphicsFormat.R8G8B8A8_SNorm, FormatUsage.Render))
            #endif
                    normalsDesc.graphicsFormat = GraphicsFormat.R8G8B8A8_SNorm;
                else
                    normalsDesc.graphicsFormat = GraphicsFormat.R16G16B16A16_SFloat;

                RenderingUtils.ReAllocateIfNeeded(ref m_BackDepthHandle, depthDesc, FilterMode.Point, TextureWrapMode.Clamp, name: "_CameraBackDepthTexture");
                cmd.SetGlobalTexture(_CameraBackDepthTexture, m_BackDepthHandle);

                RenderingUtils.ReAllocateIfNeeded(ref m_BackNormalsHandle, normalsDesc, FilterMode.Point, TextureWrapMode.Clamp, name: "_CameraBackNormalsTexture");
                cmd.SetGlobalTexture(_CameraBackNormalsTexture, m_BackNormalsHandle);

                ConfigureTarget(m_BackNormalsHandle, m_BackDepthHandle);
                ConfigureClear(ClearFlag.Color | ClearFlag.Depth, Color.clear);
            }
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            CommandBuffer cmd = CommandBufferPool.Get();

            // Render backface depth
            if (m_AccurateThickness == AccurateThickness.DepthOnly)
            {
                using (new ProfilingScope(cmd, m_ProfilingSampler))
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
                using (new ProfilingScope(cmd, m_ProfilingSampler))
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
        #endregion

    #if UNITY_6000_0_OR_NEWER
        #region Render Graph Pass
        // This class stores the data needed by the pass, passed as parameter to the delegate function that executes the pass
        private class PassData
        {
            internal RendererListHandle rendererListHandle;
        }

        // This static method is used to execute the pass and passed as the RenderFunc delegate to the RenderGraph render pass
        static void ExecutePass(PassData data, RasterGraphContext context)
        {
            context.cmd.DrawRendererList(data.rendererListHandle);
        }

        // This is where the renderGraph handle can be accessed.
        // Each ScriptableRenderPass can use the RenderGraph handle to add multiple render passes to the render graph
        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            // add a raster render pass to the render graph, specifying the name and the data type that will be passed to the ExecutePass function
            using (var builder = renderGraph.AddRasterRenderPass<PassData>(m_ProfilerTag, out var passData))
            {
                // UniversalResourceData contains all the texture handles used by the renderer, including the active color and depth textures
                // The active color and depth textures are the main color and depth buffers that the camera renders into
                UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
                UniversalRenderingData universalRenderingData = frameData.Get<UniversalRenderingData>();
                UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
                UniversalLightData lightData = frameData.Get<UniversalLightData>();

                var depthDesc = cameraData.cameraTargetDescriptor;
                depthDesc.msaaSamples = 1;

                // Render backface depth
                if (m_AccurateThickness == AccurateThickness.DepthOnly)
                {
                    TextureHandle backDepthHandle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, depthDesc, name: "_CameraBackDepthTexture", true, FilterMode.Point, TextureWrapMode.Clamp);

                    RendererListDesc rendererListDesc = new RendererListDesc(new ShaderTagId("DepthOnly"), universalRenderingData.cullResults, cameraData.camera);
                    m_DepthRenderStateBlock.depthState = new DepthState(true, CompareFunction.LessEqual);
                    m_DepthRenderStateBlock.mask |= RenderStateMask.Depth;
                    m_DepthRenderStateBlock.rasterState = new RasterState(CullMode.Front);
                    m_DepthRenderStateBlock.mask |= RenderStateMask.Raster;
                    rendererListDesc.stateBlock = m_DepthRenderStateBlock;
                    rendererListDesc.sortingCriteria = cameraData.defaultOpaqueSortFlags;
                    rendererListDesc.renderQueueRange = RenderQueueRange.all;

                    passData.rendererListHandle = renderGraph.CreateRendererList(rendererListDesc);

                    // We declare the RendererList we just created as an input dependency to this pass, via UseRendererList()
                    builder.UseRendererList(passData.rendererListHandle);

                    builder.SetRenderAttachmentDepth(backDepthHandle);

                    builder.SetGlobalTextureAfterPass(backDepthHandle, _CameraBackDepthTexture);

                    // We disable culling for this pass for the demonstrative purpose of this sample, as normally this pass would be culled,
                    // since the destination texture is not used anywhere else
                    //builder.AllowGlobalStateModification(true);
                    //builder.AllowPassCulling(false);

                    // Assign the ExecutePass function to the render pass delegate, which will be called by the render graph when executing the pass
                    builder.SetRenderFunc((PassData data, RasterGraphContext context) => ExecutePass(data, context));
                }
                // Render backface depth + normals
                else if (m_AccurateThickness == AccurateThickness.DepthNormals)
                {
                    TextureHandle backDepthHandle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, depthDesc, name: "_CameraBackDepthTexture", true, FilterMode.Point, TextureWrapMode.Clamp);

                    var normalsDesc = cameraData.cameraTargetDescriptor;
                    normalsDesc.msaaSamples = 1;
                    // normal normal normal packedSmoothness
                    // NormalWS range is -1.0 to 1.0, so we need a signed render texture.
                    normalsDesc.depthStencilFormat = GraphicsFormat.None;
                #if UNITY_2023_2_OR_NEWER
                    if (SystemInfo.IsFormatSupported(GraphicsFormat.R8G8B8A8_SNorm, GraphicsFormatUsage.Render))
                #else
                    if (SystemInfo.IsFormatSupported(GraphicsFormat.R8G8B8A8_SNorm, FormatUsage.Render))
                #endif
                        normalsDesc.graphicsFormat = GraphicsFormat.R8G8B8A8_SNorm;
                    else
                        normalsDesc.graphicsFormat = GraphicsFormat.R16G16B16A16_SFloat;

                    TextureHandle backNormalsHandle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, normalsDesc, name: "_CameraBackNormalsTexture", true, FilterMode.Point, TextureWrapMode.Clamp);

                    RendererListDesc rendererListDesc = new RendererListDesc(new ShaderTagId("DepthNormals"), universalRenderingData.cullResults, cameraData.camera);
                    m_DepthRenderStateBlock.depthState = new DepthState(true, CompareFunction.LessEqual);
                    m_DepthRenderStateBlock.mask |= RenderStateMask.Depth;
                    m_DepthRenderStateBlock.rasterState = new RasterState(CullMode.Front);
                    m_DepthRenderStateBlock.mask |= RenderStateMask.Raster;
                    rendererListDesc.stateBlock = m_DepthRenderStateBlock;
                    rendererListDesc.sortingCriteria = cameraData.defaultOpaqueSortFlags;
                    rendererListDesc.renderQueueRange = RenderQueueRange.all;

                    passData.rendererListHandle = renderGraph.CreateRendererList(rendererListDesc);

                    // We declare the RendererList we just created as an input dependency to this pass, via UseRendererList()
                    builder.UseRendererList(passData.rendererListHandle);

                    builder.SetRenderAttachment(backNormalsHandle, 0);
                    builder.SetRenderAttachmentDepth(backDepthHandle);

                    builder.SetGlobalTextureAfterPass(backNormalsHandle, _CameraBackNormalsTexture);
                    builder.SetGlobalTextureAfterPass(backDepthHandle, _CameraBackDepthTexture);

                    // We disable culling for this pass for the demonstrative purpose of this sample, as normally this pass would be culled,
                    // since the destination texture is not used anywhere else
                    //builder.AllowGlobalStateModification(true);
                    //builder.AllowPassCulling(false);

                    // Assign the ExecutePass function to the render pass delegate, which will be called by the render graph when executing the pass
                    builder.SetRenderFunc((PassData data, RasterGraphContext context) => ExecutePass(data, context));
                }
            }
        }
        #endregion
    #endif

        #region Shared
        public void Dispose()
        {
            if (m_AccurateThickness != AccurateThickness.None)
                m_BackDepthHandle?.Release();
            if (m_AccurateThickness == AccurateThickness.DepthNormals)
                m_BackNormalsHandle?.Release();
        }
        #endregion
    }

    public class TransparentGBufferPass : ScriptableRenderPass
    {
        const string m_ProfilerTag = "Path Tracing Transparent GBuffer";
        private readonly ProfilingSampler m_ProfilingSampler = new ProfilingSampler(m_ProfilerTag);

        private List<ShaderTagId> m_ShaderTagIdList = new List<ShaderTagId>();
        private FilteringSettings m_filter;

        // Depth Priming.
        private RenderStateBlock m_RenderStateBlock = new RenderStateBlock(RenderStateMask.Nothing);

        public RTHandle m_TransparentGBuffer0;
        public RTHandle m_TransparentGBuffer1;
        public RTHandle m_TransparentGBuffer2;
        private RTHandle[] m_TransparentGBuffers;

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

        // From "URP-Package/Runtime/DeferredLights.cs".
        public GraphicsFormat GetGBufferFormat(int index)
        {
            if (index == 0) // sRGB albedo, materialFlags
                return QualitySettings.activeColorSpace == ColorSpace.Linear ? GraphicsFormat.R8G8B8A8_SRGB : GraphicsFormat.R8G8B8A8_UNorm;
            else if (index == 1) // sRGB specular, occlusion
                return GraphicsFormat.R8G8B8A8_UNorm;
            else if (index == 2) // normal normal normal packedSmoothness
                // NormalWS range is -1.0 to 1.0, so we need a signed render texture.
            #if UNITY_2023_2_OR_NEWER
                if (SystemInfo.IsFormatSupported(GraphicsFormat.R8G8B8A8_SNorm, GraphicsFormatUsage.Render))
            #else
                if (SystemInfo.IsFormatSupported(GraphicsFormat.R8G8B8A8_SNorm, FormatUsage.Render))
            #endif
                    return GraphicsFormat.R8G8B8A8_SNorm;
                else
                    return GraphicsFormat.R16G16B16A16_SFloat;
            else
                return GraphicsFormat.None;
        }

        #region Non Render Graph Pass
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            // GBuffer cannot store surface data from transparent objects.
            SortingCriteria sortingCriteria = renderingData.cameraData.defaultOpaqueSortFlags;

            CommandBuffer cmd = CommandBufferPool.Get();
            using (new ProfilingScope(cmd, m_ProfilingSampler))
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

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            RenderTextureDescriptor desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0; // Color and depth cannot be combined in RTHandles
            desc.stencilFormat = GraphicsFormat.None;
            desc.msaaSamples = 1; // Do not enable MSAA for GBuffers.

            // Albedo.rgb + MaterialFlags.a
            desc.graphicsFormat = GetGBufferFormat(0);
            RenderingUtils.ReAllocateIfNeeded(ref m_TransparentGBuffer0, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_TransparentGBuffer0");
            cmd.SetGlobalTexture(_TransparentGBuffer0, m_TransparentGBuffer0);

            // Specular.rgb + Occlusion.a
            desc.graphicsFormat = GetGBufferFormat(1);
            RenderingUtils.ReAllocateIfNeeded(ref m_TransparentGBuffer1, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_TransparentGBuffer1");
            cmd.SetGlobalTexture(_TransparentGBuffer1, m_TransparentGBuffer1);

            // NormalWS.rgb + Smoothness.a
            desc.graphicsFormat = GetGBufferFormat(2);
            RenderingUtils.ReAllocateIfNeeded(ref m_TransparentGBuffer2, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_TransparentGBuffer2");
            cmd.SetGlobalTexture(_TransparentGBuffer2, m_TransparentGBuffer2);

            m_TransparentGBuffers = new RTHandle[] { m_TransparentGBuffer0, m_TransparentGBuffer1, m_TransparentGBuffer2 };

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
                },

                blendState1 = new RenderTargetBlendState
                {

                    destinationColorBlendMode = BlendMode.Zero,
                    sourceColorBlendMode = BlendMode.One,
                    destinationAlphaBlendMode = BlendMode.Zero,
                    sourceAlphaBlendMode = BlendMode.One,
                    colorBlendOperation = BlendOp.Add,
                    alphaBlendOperation = BlendOp.Add,
                    writeMask = ColorWriteMask.All
                },

                blendState2 = new RenderTargetBlendState
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
        #endregion

    #if UNITY_6000_0_OR_NEWER
        #region Render Graph Pass
        // This class stores the data needed by the pass, passed as parameter to the delegate function that executes the pass
        private class PassData
        {
            internal bool isOpenGL;

            internal RendererListHandle rendererListHandle;
        }

        // This static method is used to execute the pass and passed as the RenderFunc delegate to the RenderGraph render pass
        static void ExecutePass(PassData data, RasterGraphContext context)
        {
            if (data.isOpenGL)
                context.cmd.ClearRenderTarget(true, true, Color.black);
            else
                // We have to also clear previous color so that the "background" will remain empty (black) when moving the camera.
                context.cmd.ClearRenderTarget(false, true, Color.clear);

            context.cmd.DrawRendererList(data.rendererListHandle);
        }

        // This is where the renderGraph handle can be accessed.
        // Each ScriptableRenderPass can use the RenderGraph handle to add multiple render passes to the render graph
        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            // add a raster render pass to the render graph, specifying the name and the data type that will be passed to the ExecutePass function
            using (var builder = renderGraph.AddRasterRenderPass<PassData>(m_ProfilerTag, out var passData))
            {
                // UniversalResourceData contains all the texture handles used by the renderer, including the active color and depth textures
                // The active color and depth textures are the main color and depth buffers that the camera renders into
                UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
                UniversalRenderingData universalRenderingData = frameData.Get<UniversalRenderingData>();
                UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
                UniversalLightData lightData = frameData.Get<UniversalLightData>();

                RenderTextureDescriptor desc = cameraData.cameraTargetDescriptor;
                desc.msaaSamples = 1;
                desc.depthBufferBits = 0;

                // Albedo.rgb + MaterialFlags.a
                desc.graphicsFormat = GetGBufferFormat(0);
                TextureHandle gBuffer0Handle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, desc, name: "_TransparentGBuffer0", false, FilterMode.Point, TextureWrapMode.Clamp);

                // Specular.rgb + Occlusion.a
                desc.graphicsFormat = GetGBufferFormat(1);
                TextureHandle gBuffer1Handle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, desc, name: "_TransparentGBuffer1", false, FilterMode.Point, TextureWrapMode.Clamp);

                // NormalWS.rgb + Smoothness.a
                desc.graphicsFormat = GetGBufferFormat(2);
                TextureHandle gBuffer2Handle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, desc, name: "_TransparentGBuffer2", false, FilterMode.Point, TextureWrapMode.Clamp);

                // [OpenGL] Reusing the depth buffer seems to cause black glitching artifacts, so clear the existing depth.
                bool isOpenGL = (SystemInfo.graphicsDeviceType == GraphicsDeviceType.OpenGLES3) || (SystemInfo.graphicsDeviceType == GraphicsDeviceType.OpenGLCore); // GLES 2 is deprecated.

                m_RenderStateBlock.depthState = new DepthState(true, CompareFunction.LessEqual);
                m_RenderStateBlock.mask |= RenderStateMask.Depth;

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
                    },

                    blendState1 = new RenderTargetBlendState
                    {

                        destinationColorBlendMode = BlendMode.Zero,
                        sourceColorBlendMode = BlendMode.One,
                        destinationAlphaBlendMode = BlendMode.Zero,
                        sourceAlphaBlendMode = BlendMode.One,
                        colorBlendOperation = BlendOp.Add,
                        alphaBlendOperation = BlendOp.Add,
                        writeMask = ColorWriteMask.All
                    },

                    blendState2 = new RenderTargetBlendState
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

                // GBuffer cannot store surface data from transparent objects.
                SortingCriteria sortingCriteria = cameraData.defaultOpaqueSortFlags;
                RendererListDesc rendererListDesc = new RendererListDesc(m_ShaderTagIdList[0], universalRenderingData.cullResults, cameraData.camera);
                rendererListDesc.stateBlock = m_RenderStateBlock;
                rendererListDesc.sortingCriteria = sortingCriteria;
                rendererListDesc.renderQueueRange = m_filter.renderQueueRange;

                // Setup pass data
                passData.isOpenGL = isOpenGL;
                passData.rendererListHandle = renderGraph.CreateRendererList(rendererListDesc);

                // We declare the RendererList we just created as an input dependency to this pass, via UseRendererList()
                builder.UseRendererList(passData.rendererListHandle);

                builder.SetRenderAttachment(gBuffer0Handle, 0);
                builder.SetRenderAttachment(gBuffer1Handle, 1);
                builder.SetRenderAttachment(gBuffer2Handle, 2);
                builder.SetRenderAttachmentDepth(resourceData.activeDepthTexture, AccessFlags.ReadWrite);

                builder.SetGlobalTextureAfterPass(gBuffer0Handle, _TransparentGBuffer0);
                builder.SetGlobalTextureAfterPass(gBuffer1Handle, _TransparentGBuffer1);
                builder.SetGlobalTextureAfterPass(gBuffer2Handle, _TransparentGBuffer2);

                // We disable culling for this pass for the demonstrative purpose of this sample, as normally this pass would be culled,
                // since the destination texture is not used anywhere else
                //builder.AllowGlobalStateModification(true);
                //builder.AllowPassCulling(false);

                // Assign the ExecutePass function to the render pass delegate, which will be called by the render graph when executing the pass
                builder.SetRenderFunc((PassData data, RasterGraphContext context) => ExecutePass(data, context));
            }
        }
        #endregion
    #endif

        #region Shared
        public void Dispose()
        {
            m_TransparentGBuffer0?.Release();
            m_TransparentGBuffer1?.Release();
            m_TransparentGBuffer2?.Release();
        }
        #endregion
    }

    public class ForwardGBufferPass : ScriptableRenderPass
    {
        const string m_ProfilerTag = "Path Tracing Forward GBuffer";
        private readonly ProfilingSampler m_ProfilingSampler = new ProfilingSampler(m_ProfilerTag);

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
            RenderQueueRange queue = RenderQueueRange.opaque;
            m_filter = new FilteringSettings(queue);
            if (PassNames != null && PassNames.Length > 0)
            {
                foreach (var passName in PassNames)
                    m_ShaderTagIdList.Add(new ShaderTagId(passName));
            }
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
            #if UNITY_2023_2_OR_NEWER
                if (SystemInfo.IsFormatSupported(GraphicsFormat.R8G8B8A8_SNorm, GraphicsFormatUsage.Render))
            #else
                if (SystemInfo.IsFormatSupported(GraphicsFormat.R8G8B8A8_SNorm, FormatUsage.Render))
            #endif
                    return GraphicsFormat.R8G8B8A8_SNorm;
                else
                    return GraphicsFormat.R16G16B16A16_SFloat;
            else
                return GraphicsFormat.None;
        }

        #region Non Render Graph Pass
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            // GBuffer cannot store surface data from transparent objects.
            SortingCriteria sortingCriteria = renderingData.cameraData.defaultOpaqueSortFlags;

            CommandBuffer cmd = CommandBufferPool.Get();
            using (new ProfilingScope(cmd, m_ProfilingSampler))
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

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            RenderTextureDescriptor desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0; // Color and depth cannot be combined in RTHandles
            desc.stencilFormat = GraphicsFormat.None;
            desc.msaaSamples = 1; // Do not enable MSAA for GBuffers.

            // Albedo.rgb + MaterialFlags.a
            desc.graphicsFormat = GetGBufferFormat(0);
            RenderingUtils.ReAllocateIfNeeded(ref m_GBuffer0, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_GBuffer0");
            cmd.SetGlobalTexture(_GBuffer0, m_GBuffer0);

            // Specular.rgb + Occlusion.a
            desc.graphicsFormat = GetGBufferFormat(1);
            RenderingUtils.ReAllocateIfNeeded(ref m_GBuffer1, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_GBuffer1");
            cmd.SetGlobalTexture(_GBuffer1, m_GBuffer1);

            // [Resolve Later] The "_CameraNormalsTexture" still exists after disabling DepthNormals Prepass, which may cause issue during rendering.
            // So instead of checking the RTHandle, we need to check if DepthNormals Prepass is enqueued.

            /*
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
                m_GBuffers = new RTHandle[] { m_GBuffer0, m_GBuffer1, normalsTextureHandle };
            }
            */

            // NormalWS.rgb + Smoothness.a
            desc.graphicsFormat = GetGBufferFormat(2);
            RenderingUtils.ReAllocateIfNeeded(ref m_GBuffer2, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_GBuffer2");
            cmd.SetGlobalTexture(_GBuffer2, m_GBuffer2);
            m_GBuffers = new RTHandle[] { m_GBuffer0, m_GBuffer1, m_GBuffer2 };

            ConfigureTarget(m_GBuffers, renderingData.cameraData.renderer.cameraDepthTargetHandle);

            // Require Depth Texture in Forward pipeline.
            ConfigureInput(ScriptableRenderPassInput.Depth);

            // [OpenGL] Reusing the depth buffer seems to cause black glitching artifacts, so clear the existing depth.
            bool isOpenGL = (SystemInfo.graphicsDeviceType == GraphicsDeviceType.OpenGLES3) || (SystemInfo.graphicsDeviceType == GraphicsDeviceType.OpenGLCore); // GLES 2 is deprecated.
            if (isOpenGL)
                ConfigureClear(ClearFlag.Color | ClearFlag.Depth, Color.black);
            else
                // We have to also clear previous color so that the "background" will remain empty (black) when moving the camera.
                ConfigureClear(ClearFlag.Color, Color.clear);

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
        #endregion

    #if UNITY_6000_0_OR_NEWER
        #region Render Graph Pass

        // This class stores the data needed by the pass, passed as parameter to the delegate function that executes the pass
        private class PassData
        {
            internal bool isOpenGL;

            internal RendererListHandle rendererListHandle;
        }

        // This static method is used to execute the pass and passed as the RenderFunc delegate to the RenderGraph render pass
        static void ExecutePass(PassData data, RasterGraphContext context)
        {
            if (data.isOpenGL)
                context.cmd.ClearRenderTarget(true, true, Color.black);
            else
                // We have to also clear previous color so that the "background" will remain empty (black) when moving the camera.
                context.cmd.ClearRenderTarget(false, true, Color.clear);

            context.cmd.DrawRendererList(data.rendererListHandle);
        }

        // This is where the renderGraph handle can be accessed.
        // Each ScriptableRenderPass can use the RenderGraph handle to add multiple render passes to the render graph
        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            // add a raster render pass to the render graph, specifying the name and the data type that will be passed to the ExecutePass function
            using (var builder = renderGraph.AddRasterRenderPass<PassData>(m_ProfilerTag, out var passData))
            {
                // UniversalResourceData contains all the texture handles used by the renderer, including the active color and depth textures
                // The active color and depth textures are the main color and depth buffers that the camera renders into
                UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
                UniversalRenderingData universalRenderingData = frameData.Get<UniversalRenderingData>();
                UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
                UniversalLightData lightData = frameData.Get<UniversalLightData>();

                RenderTextureDescriptor desc = cameraData.cameraTargetDescriptor;
                desc.msaaSamples = 1;
                desc.depthBufferBits = 0;

                // Albedo.rgb + MaterialFlags.a
                desc.graphicsFormat = GetGBufferFormat(0);
                TextureHandle gBuffer0Handle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, desc, name: "_GBuffer0", false, FilterMode.Point, TextureWrapMode.Clamp);

                // Specular.rgb + Occlusion.a
                desc.graphicsFormat = GetGBufferFormat(1);
                TextureHandle gBuffer1Handle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, desc, name: "_GBuffer1", false, FilterMode.Point, TextureWrapMode.Clamp);

                // [Resolve Later] The "_CameraNormalsTexture" still exists after disabling DepthNormals Prepass, which may cause issue during rendering.
                // So instead of checking the RTHandle, we need to check if DepthNormals Prepass is enqueued.

                /*
                TextureHandle gBuffer2Handle;
                // If "_CameraNormalsTexture" exists (lacking smoothness info), set the target to it instead of creating a new RT.
                if (normalsTextureFieldInfo.GetValue(cameraData.renderer) is not RTHandle normalsTextureHandle)
                {
                    // NormalWS.rgb + Smoothness.a
                    desc.graphicsFormat = GetGBufferFormat(2);
                    gBuffer2Handle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, desc, name: "_GBuffer2", false, FilterMode.Point, TextureWrapMode.Clamp);
                }
                else
                {
                    gBuffer2Handle = resourceData.cameraNormalsTexture;
                }
                */

                // NormalWS.rgb + Smoothness.a
                desc.graphicsFormat = GetGBufferFormat(2);
                TextureHandle gBuffer2Handle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, desc, name: "_GBuffer2", false, FilterMode.Point, TextureWrapMode.Clamp);

                // [OpenGL] Reusing the depth buffer seems to cause black glitching artifacts, so clear the existing depth.
                bool isOpenGL = (SystemInfo.graphicsDeviceType == GraphicsDeviceType.OpenGLES3) || (SystemInfo.graphicsDeviceType == GraphicsDeviceType.OpenGLCore); // GLES 2 is deprecated.

                // Reduce GBuffer overdraw using the depth from opaque pass. (excluding OpenGL platforms)
                if (!isOpenGL && (cameraData.renderType == CameraRenderType.Base || cameraData.clearDepth))
                {
                    m_RenderStateBlock.depthState = new DepthState(false, CompareFunction.Equal);
                    m_RenderStateBlock.mask |= RenderStateMask.Depth;
                }
                else if (m_RenderStateBlock.depthState.compareFunction == CompareFunction.Equal)
                {
                    m_RenderStateBlock.depthState = new DepthState(true, CompareFunction.LessEqual);
                    m_RenderStateBlock.mask |= RenderStateMask.Depth;
                }

                // GBuffer cannot store surface data from transparent objects.
                SortingCriteria sortingCriteria = cameraData.defaultOpaqueSortFlags;
                RendererListDesc rendererListDesc = new RendererListDesc(m_ShaderTagIdList[0], universalRenderingData.cullResults, cameraData.camera);
                DrawingSettings drawSettings = RenderingUtils.CreateDrawingSettings(m_ShaderTagIdList[0], universalRenderingData, cameraData, lightData, sortingCriteria);
                var param = new RendererListParams(universalRenderingData.cullResults, drawSettings, m_filter);
                rendererListDesc.stateBlock = m_RenderStateBlock;
                rendererListDesc.sortingCriteria = sortingCriteria;
                rendererListDesc.renderQueueRange = m_filter.renderQueueRange;

                // Set pass data
                passData.isOpenGL = isOpenGL;
                passData.rendererListHandle = renderGraph.CreateRendererList(rendererListDesc);

                // We declare the RendererList we just created as an input dependency to this pass, via UseRendererList()
                builder.UseRendererList(passData.rendererListHandle);

                // Set render targets
                builder.SetRenderAttachment(gBuffer0Handle, 0);
                builder.SetRenderAttachment(gBuffer1Handle, 1);
                builder.SetRenderAttachment(gBuffer2Handle, 2);
                builder.SetRenderAttachmentDepth(resourceData.activeDepthTexture, AccessFlags.ReadWrite);

                // Set global textures after this pass
                builder.SetGlobalTextureAfterPass(gBuffer0Handle, _GBuffer0);
                builder.SetGlobalTextureAfterPass(gBuffer1Handle, _GBuffer1);
                builder.SetGlobalTextureAfterPass(gBuffer2Handle, _GBuffer2);

                // We disable culling for this pass for the demonstrative purpose of this sample, as normally this pass would be culled,
                // since the destination texture is not used anywhere else
                //builder.AllowGlobalStateModification(true);
                //builder.AllowPassCulling(false);

                // Assign the ExecutePass function to the render pass delegate, which will be called by the render graph when executing the pass
                builder.SetRenderFunc((PassData data, RasterGraphContext context) => ExecutePass(data, context));
            }
        }

        #endregion
    #endif

        #region Shared
        public void Dispose()
        {
            m_GBuffer0?.Release();
            m_GBuffer1?.Release();
            m_GBuffer2?.Release();
        }
        #endregion
    }
}