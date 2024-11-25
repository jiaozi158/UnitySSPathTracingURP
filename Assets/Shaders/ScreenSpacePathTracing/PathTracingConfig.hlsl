#ifndef URP_SCREEN_SPACE_PATH_TRACING_CONFIG_HLSL
#define URP_SCREEN_SPACE_PATH_TRACING_CONFIG_HLSL

// Screen Space Path Tracing Configuration

// The unit of float values below is Unity unit (meter by default).
//===================================================================================================================================
// STEP_SIZE          : The ray's initial marching step size.
//                      Increasing this may improve performance but reduce the accuracy of ray intersection test.
//
// MAX_STEP           : The maximum marching steps of each ray.
//                      Increasing this may decrease performance but allows the ray to travel further. (if not decreasing STEP_SIZE)
// 
// MAX_SAMLL_STEP     : The maximum number of small steps for adaptive ray marching.
//                      When SSPT runs out of small steps, it will use medium step size to perform ray marching.
//                      This value should be less than MAX_STEP.
// 
// MAX_MEDIUM_STEP    : The maximum number of medium steps for adaptive ray marching.
//                      When SSPT runs out of medium steps, it will use large step size to perform ray marching.
//                      To set the medium steps to 2, you should set the "MAX_MEDIUM_STEP" to "MAX_SMALL_STEP + 2".
// 
// RAY_BOUNCE         : The maximum number of times each ray bounces. (should be at least 1)
//                      Increasing this may decrease performance but is necessary for recursive reflections.
//
// MARCHING_THICKNESS : The approximate thickness of scene objects.
//                      This will also be the fallback thickness when enabling "Accurate Thickness" in renderer feature.
// 
// RAY_BIAS           : The bias applied to ray's hit position to avoid self-intersection with hit position.
//                      Usually no need to adjust it.
// 
// RAY_COUNT          : The number of rays generated per pixel. (Samples Per Pixel)
//                      Increasing this may significantly decrease performance but will provide a more convergent result when moving camera. (less noise)
// 
//                      If you set this too high, the GPU Driver may restart and causing Unity to shut down. (swapchain error)
//                      In this case, consider using Temporal-AA or Accumulation Renderer Feature to denoise.
//===================================================================================================================================

//===================================================================================================================================
// Screen Space Path Tracing
//===================================================================================================================================
// Ray marching step counts
	#define MAX_STEP              _MaxSteps // [Total Steps] controlled in SSPT Volume
	#define MAX_SMALL_STEP        6
	#define MAX_MEDIUM_STEP       MAX_SMALL_STEP + 12 // The "MAX_SMALL_STEP + 12" represents 12 medium steps

// Initial size of each ray marching step (in meters)
	#define STEP_SIZE             _StepSize // Controlled in SSPT Volume
	#define SMALL_STEP_SIZE		  0.005
	#define MEDIUM_STEP_SIZE	  0.1

// Minimum thickness of scene objects (in meters)
	#define MARCHING_THICKNESS				0.4
	#define MARCHING_THICKNESS_SMALL_STEP   0.0075
	#define MARCHING_THICKNESS_MEDIUM_STEP  0.1

// The maximum bounces of each ray
	#define RAY_BOUNCE            _MaxBounce // Controlled in SSPT Volume

// Position bias to avoid self-intersecting
	#define RAY_BIAS              0.0001

// Samples per pixel
	#define RAY_COUNT             _RayCount // Controlled in SSPT Volume
//-----------------------------------------------------------------------------------------------------------------------------------

//===================================================================================================================================
// Rendering Settings
//===================================================================================================================================

// Lambert or Disney Diffuse BRDF
    #define USE_DISNEY_DIFFUSE (1)

//===================================================================================================================================
// Temporal Accumulation (Temporal and Spatial-Temporal)
//===================================================================================================================================
// Maximum history samples
	#define MAX_ACCUM_FRAME_NUM			8

// For Temporal and Spatial-Temporal Accumulation
	#define RAY_COUNT_LOW_SAMPLE  4			// The minimum number of rays to cast for pixels lacking a sufficient history of samples.

// Temporal re-projection rejection threshold
	#define MAX_REPROJECTION_DISTANCE	0.02
	#define MAX_PIXEL_TOLERANCE			4
	#define PROJECTION_EPSILON			0.000001

// Threshold at which we decide to reject the reflection history
	#define REFLECTION_HISTORY_REJECTION_THRESHOLD 0.75
// Threshold at which we go from accumulation to clamping
	#define ROUGHNESS_ACCUMULATION_THRESHOLD 0.5

// SPEC_ACCUM_CURVE = 1.0 (aggressiveness of history rejection depending on viewing angle: 1 = low, 0.66 = medium, 0.5 = high)
	#define SPEC_ACCUM_CURVE 1.0
// SPEC_ACCUM_BASE_POWER = 0.5-1.0 (greater values lead to less aggressive accumulation)
	#define SPEC_ACCUM_BASE_POWER 1.0
//-----------------------------------------------------------------------------------------------------------------------------------

	#define CLAMP_MAX       65472.0 // HALF_MAX minus one (2 - 2^-9) * 2^15

#endif