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
//                      When SSPT runs out of small steps, it will use large step size to perform ray marching.
//                      This value should be less than MAX_STEP.
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
#if defined(_RAY_MARCHING_HIGH)
	#define STEP_SIZE             0.2
	#define MAX_STEP              64
	#define MAX_SMALL_STEP        4
	#define RAY_BOUNCE            5
#elif defined(_RAY_MARCHING_MEDIUM)
	#define STEP_SIZE             0.25
	#define MAX_STEP              48
	#define MAX_SMALL_STEP        4
	#define RAY_BOUNCE            4
#elif defined(_RAY_MARCHING_VERY_LOW) // If the scene is quite "reflective" or "refractive", it is recommended to keep RAY_BOUNCE as 3 (or higher) for a good look.
	#define STEP_SIZE             0.4
	#define MAX_STEP              12
	#define MAX_SMALL_STEP        2
	#define RAY_BOUNCE            2
#else //defined(_RAY_MARCHING_LOW)
	#define STEP_SIZE             0.3
	#define MAX_STEP              32
	#define MAX_SMALL_STEP        4
	#define RAY_BOUNCE            3
#endif
// Global quality settings.
	#define MARCHING_THICKNESS    0.15
	#define RAY_BIAS              0.001
	#define RAY_COUNT             1
//===================================================================================================================================

#endif