extends Node


func _ready() -> void:

	# Create a local rendering device.
	var rd := RenderingServer.create_local_rendering_device()
	print("Max Workgroup Count:")
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X))
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_Y))
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_Z))
	print("====================")
	print("Max Workgroup Size:")
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_X))
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_Y))
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_Z))
	print("====================")
	print("Max Workgroup Invocations:")
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_INVOCATIONS))
	# Load GLSL shader
	var shader_file := load("res://test.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	var shader := rd.shader_create_from_spirv(shader_spirv)

	# Prepare our data. We use floats in the shader, so we need 32 bit.
	# We will need at least as many threads on the gpu as there are values in the arrays we pass in there
	var input := PackedFloat32Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
	var input_bytes := input.to_byte_array()

	# Create a storage buffer that can hold our float values.
	# Each float has 4 bytes (32 bit) so 10 x 4 = 40 bytes
	var buffer := rd.storage_buffer_create(input_bytes.size(), input_bytes)

	# With the buffer in place we need to tell the rendering device to use it. To do that we will need to create a uniform (like in normal shaders) and assign it to a uniform set which we can pass to our shader later.
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = 0 # this needs to match the "binding" in our shader file
	uniform.add_id(buffer)
	var uniform_set := rd.uniform_set_create([uniform], shader, 0) # the last parameter (the 0) needs to match the "set" in our shader file
	
	#The next step is to create a set of instructions our GPU can execute. We need a pipeline and a compute list for that.

	#The steps we need to do to compute our result are:
	#1. Create a new pipeline.
	#2. Begin a list of instructions for our GPU to execute.
	#3. Bind our compute list to our pipeline
	#4. Bind our buffer uniform to our pipeline
	#5. Specify how many workgroups to use
	#6. End the list of instructions

	# Create a compute pipeline
	var pipeline := rd.compute_pipeline_create(shader)
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	# Now we dispatch a workgroup COUNT per "axis" that does not go over the MAX_WORKGROUP_COUNT for that axis. There is no problem if the hardware doesn't support all the workgroups. If they're too many, they will just be queued.
	print("Max Workgroup Count:")
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X))
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_Y))
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_Z))
	print("====================")
	# The harder limits come with workgroup SIZE and INVOCATIONS
	print("Max Workgroup Size:")
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_X))
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_Y))
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_Z))
	print("====================")
	# The workgroup size per axis, on an RTX 3070, can be 1024,1024,64. This is is the maximum EACH AXIS can have when we define the axes in GLSL (layout(local_size_x = 2, local_size_y = 1, local_size_z = 1) in;) BUT...
	# BUT the TOTAL number of threads/invocations cannot go over the MAX_WORKGROUP_INVOCATIONS
	print("Max Workgroup Invocations:")
	print(rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_INVOCATIONS))
	# So, in the compute shader, x*y*z cannot go over this maximum. If we consider the maximum 1024, as it is for an RTX 3070, then:
	# layout(local_size_x = 1024, local_size_y = 1, local_size_z = 1) in; is valid
	# layout(local_size_x = 512, local_size_y = 2, local_size_z = 1) in; is valid
	# layout(local_size_x = 256, local_size_y = 2, local_size_z = 2) in; is valid
	# layout(local_size_x = 512, local_size_y = 4, local_size_z = 2) in; is NOT valid, because X times Y times Z is greater than 1024
	# As a rule of thumb, if we're dealing with 1D data structures, we might want to keep the workgroup count on one axis. And so on and so forth for other dimensions.
	var num_datapoints: int = input.size() #I don't know what else to call this
	var local_size: int = 128#the size of the local groups we set in the shader. This is not dynamic and must be hard-coded. Going for 128 on a single axis, because 128 is the maximum amount of threads (invocations) weaker hardware can spawn. Could as well be "x=64, y=2, z=1" or any combination where x*y*z=128 
	var total_groups = (num_datapoints + (local_size -1)) / local_size #ceil(num_datapoints/128) -> in the case of an array of size 10, it is so few that it will only be 1 (1 * 128 = 128), which is the amount of threads/invocations we want to spawn, even though we could spawn as much as 1024 threads.
	rd.compute_list_dispatch(compute_list, 5, 1, 1)
	
	rd.compute_list_end()
	
	# Submit to GPU and wait for sync (causes CPU to wait for GPU) - this is where we find out if the calculations we're doing on the GPU are worth the waiting time CPU-side.
	rd.submit()
	rd.sync()
	
	# Read back the data from the buffer
	var output_bytes := rd.buffer_get_data(buffer)
	var output := output_bytes.to_float32_array()
	print("Input: ", input)
	print("Output: ", output)
	
	#The buffer, pipeline, and uniform_set variables we've been using are each an RID. Because RenderingDevice is meant to be a lower-level API, RIDs aren't freed automatically. This means that once you're done using buffer or any other RID, you are responsible for freeing its memory manually using the RenderingDevice's free_rid() method.

	if rd == null:
		return

	# All resources must be freed after use to avoid memory leaks.
	
	rd.free_rid(buffer)
	buffer = RID()
	
	rd.free_rid(pipeline)
	pipeline = RID()

	rd.free_rid(shader)
	shader = RID()

	rd.free_rid(uniform_set)
	uniform_set = RID()

	rd.free()
	rd = null

# For clearing RIDs, we get the predelete notification for the node the script is attached to and if it is of some type, we free all RIDs we created:
#func _notification(what: int) -> void:
	#if what == NOTIFICATION_PREDELETE:
		#rd.free_rid(buffers)
		#rd.free_rid(uniform_set)
		#rd.free_rid(shader_rid)
		#rd.free_rid(pipeline)
		#...
