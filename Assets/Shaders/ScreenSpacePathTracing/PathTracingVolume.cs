using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

#if UNITY_2023_1_OR_NEWER
[Serializable, VolumeComponentMenu("Lighting/Path Tracing (URP)"), SupportedOnRenderPipeline(typeof(UniversalRenderPipelineAsset))]
#else
[Serializable, VolumeComponentMenuForRenderPipeline("Lighting/Path Tracing (URP)", typeof(UniversalRenderPipeline))]
#endif
public class ScreenSpacePathTracing: VolumeComponent, IPostProcessComponent
{
    /// <summary>
    /// Enables screen space path tracing.
    /// </summary>
    [Header("General"), Tooltip("Enables screen space path tracing.")]
    public BoolParameter state = new BoolParameter(false, BoolParameter.DisplayType.EnumPopup, overrideState: true);

    /// <summary>
    /// Defines the maximum number of paths cast within each pixel, over time in offline accumulation mode.
    /// </summary>
    [Tooltip("Defines the maximum number of paths cast within each pixel, over time in offline accumulation mode.")]
    public ClampedIntParameter maximumSamples = new ClampedIntParameter(256, 4, 512, overrideState: false);

    /// <summary>
    /// Defines the maximum number of bounces for each path, in [1, 16].
    /// </summary>
    [Tooltip("Defines the maximum number of bounces for each path, in [1, 16].")]
    public ClampedIntParameter maximumDepth = new ClampedIntParameter(4, 1, 16, overrideState: false);

    /// <summary>
    /// Defines the maximum luminance computed for path tracing.
    /// </summary>
    [Tooltip("Defines the maximum luminance computed for path tracing. Lower values help prevent noise and fireflies (very bright pixels), but introduce bias by darkening the overall result. Increase this value if your image looks too dark.")]
    public MinFloatParameter maximumIntensity = new MinFloatParameter(10f, 0.1f, overrideState: false);

    /// <summary>
    /// Defines the number of paths cast within each pixel per frame.
    /// </summary>
    [Tooltip("Defines the number of paths cast within each pixel per frame.")]
    public ClampedIntParameter samplesPerPixel = new ClampedIntParameter(1, 1, 16, overrideState: false);

    /// <summary>
    /// Defines the maximum number of steps a path can take during one bounce, affecting the precision and performance of path tracing.
    /// </summary>
    [Header("Ray Marching"), Tooltip("Defines the maximum number of steps a path can take during one bounce, affecting the performance of path tracing.")]
    public ClampedIntParameter maximumSteps = new ClampedIntParameter(24, 16, 64, overrideState: false);

    /// <summary>
    /// Defines the initial distance (in meters) covered by each large step.
    /// </summary>
    [Tooltip("Defines the initial distance (in meters) covered by each large step, affecting the precision of path tracing.")]
    public ClampedFloatParameter stepSize = new ClampedFloatParameter(0.4f, 0.1f, 1.0f, overrideState: false);

    /// <summary>
    /// Specifies the noise type used for random sampling.
    /// </summary>
    [Tooltip("Specifies the noise type used for random sampling.")]
    public NoiseParameter noiseMethod = new NoiseParameter(NoiseType.HashedRandom, overrideState: false);

    /// <summary>
    /// Specifies the denoiser used for screen space path tracing.
    /// </summary>
    [Header("Accumulation"), Tooltip("Specifies the denoiser used for screen space path tracing. Enter play mode to apply any real-time denoiser.")]
    public DenoiserParameter denoiser = new DenoiserParameter(DenoiserType.Offline, overrideState: false);

    /// <summary>
    /// The speed of accumulation convergence for Temporal and Spatial-Temporal denoiser.
    /// </summary>
    [InspectorName("Accumulation Factor"), Tooltip("The speed of accumulation convergence for Temporal and Spatial-Temporal denoiser.")]
    public ClampedFloatParameter accumFactor = new(value: 0.9f, min: 0.5f, max: 1.0f, overrideState: false);

    // [WIP] Hidden Scene Ambient Settings
    // Make sure the "overrideState" is set to false
    [Header("Hidden Scene Ambient Settings"), HideInInspector] public BoolParameter ambientStored = new BoolParameter(false, overrideState: false);
    [HideInInspector] public NoInterpClampedFloatParameter ambientIntensity = new(value: 1.0f, min: 0.0f, max: 8.0f, overrideState: false);
    [HideInInspector] public NoInterpColorParameter ambientLight = new(Color.black, overrideState: false);
    [HideInInspector] public NoInterpColorParameter ambientGroundColor = new(Color.black, overrideState: false);
    [HideInInspector] public NoInterpColorParameter ambientEquatorColor = new(Color.black, overrideState: false);
    [HideInInspector] public NoInterpColorParameter ambientSkyColor = new(Color.black, overrideState: false);

    public bool IsActive()
    {
        return state.value;
    }

    /// <summary>
    /// Determines whether real-time accumulation is enabled.
    /// </summary>
    /// <returns>True if temporal or spatial-temporal accumulation is enabled, otherwise false.</returns>
    public bool IsRealtimeAccumulationEnabled()
    {
        return denoiser.value == DenoiserType.Temporal || denoiser.value == DenoiserType.SpatialTemporal;
    }

    /// <summary>
    /// Determines whether offline accumulation denoising is enabled.
    /// </summary>
    /// <returns>True if offline accumulation is enabled, otherwise false.</returns>
    public bool IsOfflineAccumulationEnabled()
    {
        return denoiser.value == DenoiserType.Offline;
    }

    // This is unused since 2023.1
    public bool IsTileCompatible() => false;

    /// <summary>
    /// Noise type for screen space path tracing.
    /// </summary>
    public enum NoiseType
    {
        /// <summary>Use uniformly distributed procedural noise for faster random sampling.</summary>
        [Tooltip("Use uniformly distributed procedural noise for faster random sampling.")]
        HashedRandom,
        /// <summary>Use low frequency blue noise textures for slower random sampling.</summary>
        [Tooltip("Use low frequency blue noise textures for slower random sampling.")]
        BlueNoise
    }

    /// <summary>
    /// A <see cref="VolumeParameter"/> that holds a <see cref="NoiseType"/> value.
    /// </summary>
    [Serializable]
    public sealed class NoiseParameter : VolumeParameter<NoiseType>
    {
        /// <summary>
        /// Creates a new <see cref="NoiseParameter"/> instance.
        /// </summary>
        /// <param name="value">The initial value to store in the parameter.</param>
        /// <param name="overrideState">The initial override state for the parameter.</param>
        public NoiseParameter(NoiseType value, bool overrideState = false) : base(value, overrideState) { }
    }

    /// <summary>
    /// Denoiser presets for screen space path tracing.
    /// </summary>
    public enum DenoiserType
    {
        /// <summary>No denoising applied.</summary>
        [Tooltip("No denoising applied.")]
        None,
        /// <summary>Accumulates over multiple frames and restarts the path accumulation when camera moves.</summary>
        [InspectorName("Offline"), Tooltip("Accumulates over multiple frames and restarts the path accumulation when camera moves.")]
        Offline,
        /// <summary>Applies temporal re-projection for real-time denoising.</summary>
        [InspectorName("Temporal"), Tooltip("Applies temporal re-projection for real-time denoising.")]
        Temporal,
        /// <summary>Combines spatial filtering and temporal re-projection for real-time denoising.</summary>
        [InspectorName("Spatial-Temporal"), Tooltip("Combines spatial filtering and temporal re-projection for real-time denoising.")]
        SpatialTemporal
    }

    /// <summary>
    /// A <see cref="VolumeParameter"/> that holds a <see cref="DenoiserType"/> value.
    /// </summary>
    [Serializable]
    public sealed class DenoiserParameter : VolumeParameter<DenoiserType>
    {
        /// <summary>
        /// Creates a new <see cref="DenoiserParameter"/> instance.
        /// </summary>
        /// <param name="value">The initial value to store in the parameter.</param>
        /// <param name="overrideState">The initial override state for the parameter.</param>
        public DenoiserParameter(DenoiserType value, bool overrideState = false) : base(value, overrideState) { }
    }
}