using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using Unity.Collections;

[DisallowMultipleRendererFeature("Screen Space Path Tracing Accumulation")]
[Tooltip("Add this Renderer Feature to accumulate path tracing results.")]
public class ScreenSpacePathTracingAccumulation : ScriptableRendererFeature
{
    [Header("Camera Accumulation")]
    [Tooltip("The material of accumulation shader.")]
    public Material m_Material;
    private const string m_AccumulationShaderName = "Hidden/AccumulateFrame";
    private AccumulationPass m_AccumulationPass;
    public override void Create()
    {
        // Check if the accumulation material uses the correct shader.
        if (m_Material != null)
        {
            Shader shader = Shader.Find(m_AccumulationShaderName);
            if (m_Material.shader != shader)
            {
                Debug.LogErrorFormat("Screen Space Path Tracing: Material is not using {0} shader.", m_AccumulationShaderName);
                return;
            }
        }
        // No material applied.
        else
        {
            Debug.LogError("Screen Space Path Tracing: Accumulation material is empty.");
            return;
        }
        

        if (m_AccumulationPass == null)
        {
            m_AccumulationPass = new AccumulationPass(m_Material);
            // Before post-processing is suggested because of the Render Scale and Upscaling.
            m_AccumulationPass.renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;
        }
    }

    protected override void Dispose(bool disposing)
    {
        m_AccumulationPass.Dispose();
    }


    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        renderer.EnqueuePass(m_AccumulationPass);
    }

    public class AccumulationPass : ScriptableRenderPass
    {
        private int sample = 0;

        private Material m_Material;
        private RTHandle m_TmpColorHandle;

        // Reset the accumulation when scene has changed.
        // This is not perfect because we cannot detect per mesh changes or per light changes.
        // (Reject history samples in accumulation shader according to per object motion vetors?)
        private Matrix4x4 prevCamWorldMatrix;
        private Matrix4x4 prevCamHClipMatrix;
        private NativeArray<VisibleLight> prevLightsList;
        private NativeArray<VisibleReflectionProbe> prevProbesList;

        public AccumulationPass(Material material)
        {
            m_Material = material;
        }

        public void Dispose()
        {
            m_TmpColorHandle?.Release();
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var desc = renderingData.cameraData.cameraTargetDescriptor;
            desc.depthBufferBits = 0; // Color and depth cannot be combined in RTHandles

            RenderingUtils.ReAllocateIfNeeded(ref m_TmpColorHandle, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_PathTracingAccumulationTexture");

            ConfigureTarget(renderingData.cameraData.renderer.cameraColorTargetHandle);
            ConfigureClear(ClearFlag.None, Color.black);

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

        public override void FrameCleanup(CommandBuffer cmd)
        {
            //cmd.ReleaseTemporaryRT(m_TmpColorHandle.GetInstanceID());
            cmd.ReleaseTemporaryRT(Shader.PropertyToID(m_TmpColorHandle.name));
        }

        public override void OnCameraCleanup(CommandBuffer cmd)
        {
            m_TmpColorHandle = null;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            CommandBuffer cmd = CommandBufferPool.Get();
            using (new ProfilingScope(cmd, new ProfilingSampler("Path Tracing Camera Accumulation")))
            {
                bool lightsUpdated = prevLightsList != null && prevLightsList == renderingData.lightData.visibleLights;
                bool probesUpdated = prevProbesList != null && prevProbesList == renderingData.cullResults.visibleReflectionProbes;
                if (lightsUpdated || probesUpdated)
                {
                    prevLightsList = renderingData.lightData.visibleLights;
                }
                else
                {
                    sample = 0;
                    prevLightsList = renderingData.lightData.visibleLights;
                }

                m_Material.SetFloat("_Sample", sample);

                // If the HDR precision is set to 64 Bits, the maximum sample can be 2048.
                UnityEngine.Experimental.Rendering.GraphicsFormat currentGraphicsFormat = m_TmpColorHandle.rt.graphicsFormat;
                int maxSample = currentGraphicsFormat == UnityEngine.Experimental.Rendering.GraphicsFormat.B10G11R11_UFloatPack32 ? 256 : 2048;
                if (sample < maxSample)
                    sample++;

                //Using Blitter is better because it supports XR, dig deeper later.

                //m_Material.SetTexture("_MainTex", renderingData.cameraData.renderer.cameraColorTargetHandle);
                // Load & Store actions are important to support acculumation.
                //Blitter.BlitCameraTexture(cmd, renderingData.cameraData.renderer.cameraColorTargetHandle, m_TmpColorHandle, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store, m_Material, 0);
                //Blitter.BlitCameraTexture(cmd, m_TmpColorHandle, renderingData.cameraData.renderer.cameraColorTargetHandle);


                ///*
                // Load & Store actions are important to support acculumation.
                cmd.SetRenderTarget(
                m_TmpColorHandle,
                RenderBufferLoadAction.Load,
                RenderBufferStoreAction.Store,
                m_TmpColorHandle,
                RenderBufferLoadAction.DontCare,
                RenderBufferStoreAction.DontCare);
                cmd.Blit(renderingData.cameraData.renderer.cameraColorTargetHandle.rt, m_TmpColorHandle, m_Material, 0);
                cmd.Blit(m_TmpColorHandle, renderingData.cameraData.renderer.cameraColorTargetHandle);
                //*/

            }
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            CommandBufferPool.Release(cmd);
        }
    }
}
