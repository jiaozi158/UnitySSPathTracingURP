using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

// Automatically add a dummy mesh renderer to the object if not exists.
[ExecuteInEditMode, RequireComponent(typeof(MeshRenderer)), RequireComponent(typeof(Camera))]
public class PathTracingSetReflectionProbe : MonoBehaviour
{
    public Material PathTracingMaterial;
    private const string SSPathTracingName = "Hidden/Universal Render Pipeline/Screen Space Path Tracing";
    private bool isValid = false;

    private new MeshRenderer renderer;
    private List<ReflectionProbeBlendInfo> probeList;

    void OnEnable()
    {
        // Check if the screen space path tracing material uses the correct shader.
        if (PathTracingMaterial != null)
        {
            Shader shader = Shader.Find(SSPathTracingName);
            if (PathTracingMaterial.shader != shader)
            {
                Debug.LogErrorFormat("Path Tracing Set Reflection Probe: Material is not using {0} shader.", SSPathTracingName);
                isValid = false;
            }
            else
            {
                isValid = true;
                renderer = GetComponent<MeshRenderer>();
                probeList = new List<ReflectionProbeBlendInfo>();
            }
        }
    }

    void OnDisable()
    {
        // Check if the screen space path tracing material uses the correct shader.
        if (PathTracingMaterial != null)
        {
            Shader shader = Shader.Find(SSPathTracingName);
            if (PathTracingMaterial.shader == shader)
            {
                PathTracingMaterial.SetFloat("_ProbeSet", 0.0f);
            }
        }
    }

    void Update()
    {
        if (isValid)
        {
            renderer.GetClosestReflectionProbes(probeList);
            if (probeList.Count > 0)
            {
                PathTracingMaterial.SetFloat("_ProbeSet", 1.0f);
                PathTracingMaterial.SetTexture("_SpecCube0", probeList[0].probe.texture);
                PathTracingMaterial.SetVector("_SpecCube0_HDR", probeList[0].probe.textureHDRDecodeValues);
                bool isBoxProjected = probeList[0].probe.boxProjection;
                if (isBoxProjected)
                {
                    Vector3 probe0Position = probeList[0].probe.transform.position;
                    float probe0Mode = isBoxProjected ? 1.0f : 0.0f;
                    PathTracingMaterial.SetVector("_SpecCube0_BoxMin", probeList[0].probe.bounds.min);
                    PathTracingMaterial.SetVector("_SpecCube0_BoxMax", probeList[0].probe.bounds.max);
                    PathTracingMaterial.SetVector("_SpecCube0_ProbePosition", new Vector4(probe0Position.x, probe0Position.y, probe0Position.z, probe0Mode));
                }
                
                if (probeList.Count > 1)
                {
                    PathTracingMaterial.SetTexture("_SpecCube1", probeList[1].probe.texture);
                    PathTracingMaterial.SetVector("_SpecCube1_HDR", probeList[1].probe.textureHDRDecodeValues);
                    PathTracingMaterial.SetFloat("_ProbeWeight", probeList[1].weight);
                    isBoxProjected = probeList[1].probe.boxProjection;
                    if (isBoxProjected)
                    {
                        Vector3 probe1Position = probeList[1].probe.transform.position;
                        float probe1Mode = isBoxProjected ? 1.0f : 0.0f;
                        PathTracingMaterial.SetVector("_SpecCube1_BoxMin", probeList[1].probe.bounds.min);
                        PathTracingMaterial.SetVector("_SpecCube1_BoxMax", probeList[1].probe.bounds.max);
                        PathTracingMaterial.SetVector("_SpecCube1_ProbePosition", new Vector4(probe1Position.x, probe1Position.y, probe1Position.z, probe1Mode));
                    }
                }
            }
            else
            {
                PathTracingMaterial.SetFloat("_ProbeSet", 0.0f);
            }
            
        }
        
    }
}
