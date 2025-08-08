extends Node


func _ready() -> void:
	# Mock data we want to perform calculations with
	var mock_num_entities: int = 50000
	var mock_entity_array: Array[MockEntity] = []
	
	for i in range(mock_num_entities):
		var ent: MockEntity = MockEntity.new()
		ent.mock_direction = Vector3(randf_range(-100, 100), randf_range(-100, 100), randf_range(-100, 100))
		ent.mock_position = Vector3(randf_range(-100, 100), randf_range(-100, 100), randf_range(-100, 100))
		ent.mock_value = randf()
		mock_entity_array.append(ent)
	print("Entity " + str(100) + " direction: " + str(mock_entity_array[100].mock_direction))
	print("Entity " + str(100) + " position: " + str(mock_entity_array[100].mock_position))
	print("Entity " + str(100) + " value: " + str(mock_entity_array[100].mock_value))
	print("====================================================")
		
	# Create a local rendering device.
	var rd := RenderingServer.create_local_rendering_device()
	
	# Load GLSL shader
	var shader_file := load("res://test.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	var shader := rd.shader_create_from_spirv(shader_spirv)

	# The GPU wants data in a PackedByteArray. Let's build one.
	# IMPORTANT NOTE: Each buffer can only have ONE variable size array. We can pack everything into one array here and unpack on the gpu side, or pack directions and positions into 2 SSBOs here, which would probably be simpler but take up more CPU-GPU bandwidth. We'll pack direction, position, and value into one SSBO (Shader Storage Buffer Object), and entity count into another. Entity count should be a UBO, which is faster but has a 64KiB limit (more than enough for one 64bit integer), but the uniform set complains about mismatched uniform types, it's been hours, and I can't be bothered. Two SSBOs it is.
	
	# In order to keep the 'std430' alignment rules, we want to keep each set of data we send (all our "mock_" variables, except for the num entities, which will be a push constant) as a multiple of 16.
	# A Vector3 has 3 floats. Each float is 4 Bytes, meaning each Vector3 has 12 Bytes. Not a multiple of 16, so when we pack all our Vector3, only by luck would we end up with a total array size in bytes as a multiple of 16. Better if we send each Vector3 as a Vector4, which has 16 Bytes, and define the last element as mere padding. We'll get to the left over float later.
	# So, for what we want to send to the GPU, we have a total of 2 Vector3 and 1 float (mock_position, mock_direction, and mock value per mock entity) which we'll send as 2 Vector4 and 1 float, which adds up to:
	# Vector4 = 8 floats = 16 Bytes
	# 16 * 2 = 32
	# float = 4 Bytes
	# 32 + 4 = 38 Bytes -> invalid, not a multiple of 16. We can either send the float as another Vector4 with padding, in order to get the next multiple of 16above 32 (which would be 48 Bytes), assign it to the 'w' value of one of the already existing Vector4. We'll try the latter here, which leaves us with only 2 Vector4 sent to the GPU, which leaves us with a total of 32 Bytes.
	# Note that maybe we could use a Packed32FloatByteArray, but by using a generic array we have fine control over what goes where and it's easier to debug.
	const STRUCT_SIZE: int = 32 # We call this STRUCT_SIZE because we will build one struct per dataset (all the datapoints per entity) on the GPU side.
	var byte_array: PackedByteArray = PackedByteArray()
	byte_array.resize(STRUCT_SIZE * mock_num_entities) # The total size of the array will be the size of each struct (one per entity) multiplied by the number of entities.
	
	# Now we pack our data into the byte array. Remember, each set of data (2 Vector3 and 1 float that will be sent as 2 Vector4)
	for i in range(mock_num_entities):
		var dataset_offset = i * STRUCT_SIZE # Meaning each iteration of the byte array (1 dataset per entity, 32 Bytes) will be a multiple of 32 instead of the usual 1. We store 32 bytes, then 'i' increases by 32 so we can store the next dataset without overwriting what we just stored.
		
		var pos: Vector3 = mock_entity_array[i].mock_position
		var dir: Vector3 = mock_entity_array[i].mock_direction
		var val: float = mock_entity_array[i].mock_value
		
		# Pack vec4 position (bytes 0-15)
		byte_array.encode_float(dataset_offset + 0, dir.x)
		byte_array.encode_float(dataset_offset + 4, dir.y)
		byte_array.encode_float(dataset_offset + 8, dir.z)
		byte_array.encode_float(dataset_offset + 12, val) # Using the extra 4 bytes that would need to be padding to store our mock value 

		# Pack vec4 direction (bytes 16-31)
		byte_array.encode_float(dataset_offset + 16, pos.x)
		byte_array.encode_float(dataset_offset + 20, pos.y)
		byte_array.encode_float(dataset_offset + 24, pos.z)
		byte_array.encode_float(dataset_offset + 28, 0.0) # padding
		
	# Create a Storage Buffer (SSBO), which doesn't have limits as tight as a Uniform Buffer, for our mock directions, positions, and values
	var dir_pos_val_buffer: RID= rd.storage_buffer_create(byte_array.size(), byte_array)
	
	# With the buffer in place, we can now create a Uniform that will be carried by our storage buffer.
	var dir_pos_val_uniform: RDUniform = RDUniform.new()
	dir_pos_val_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	dir_pos_val_uniform.binding = 0 # this needs to match the "binding" in our shader file
	dir_pos_val_uniform.add_id(dir_pos_val_buffer) # Our buffer's RID is associated with the uniform.
	
	# We'll also send the total number of entities, which seems like a useful datum to have on the GPU side. Ints in Godot are signed 64 bits, which comes down to 16 Bytes. We COULD just add it to our buffer, and change the struct size to 32 + 16 = 48, maintaining the std430 Byte alignment rule of multiples of 16, but let's send it as a different type of buffer here, a very small one with a size limit of 64KiB TOTAL. Way smaller than our storage buffer, but this one will only need to store a single 16 Byte int.
	var num_entities_count_array: PackedByteArray = PackedByteArray()
	num_entities_count_array.resize(16)
	num_entities_count_array.encode_s64(0, mock_num_entities)
	var num_entities_buffer: RID= rd.storage_buffer_create(16, num_entities_count_array) # One Int is 64 bits, so 16 Bytes
	
	var num_entities_uniform: RDUniform = RDUniform.new()
	num_entities_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	num_entities_uniform.binding = 1 # this needs to match the "binding" in our shader file
	num_entities_uniform.add_id(num_entities_buffer) # Our buffer's RID is associated with the uniform.
	
	var uniform_set: RID = rd.uniform_set_create([num_entities_uniform, dir_pos_val_uniform], shader, 0) # the last parameter (the 0) needs to match the "set" in our shader file.
	
	#The next step is to create a set of instructions our GPU can execute. We need a pipeline and a compute list for that.

	#The steps we need to do to compute our result are:
	#1. Create a new pipeline.
	#2. Begin a list of instructions for our GPU to execute.
	#3. Bind our compute list to our pipeline
	#4. Bind our buffer uniform to our pipeline
	#5. Specify how many workgroups to use
	#6. End the list of instructions

	# Create a compute pipeline
	var pipeline: RID = rd.compute_pipeline_create(shader)
	var compute_list: int = rd.compute_list_begin()
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
	print("====================")
	# So, in the compute shader, x*y*z cannot go over this maximum. If we consider the maximum 1024, as it is for an RTX 3070, then:
	# layout(local_size_x = 1024, local_size_y = 1, local_size_z = 1) in; is valid -> 1024*1*1 = 1024 -> equal or below the maximum
	# layout(local_size_x = 512, local_size_y = 2, local_size_z = 1) in; is valid -> 512*2*1 = 1024 -> equal or below the maximum
	# layout(local_size_x = 256, local_size_y = 2, local_size_z = 2) in; is valid -> 256*2*2 = 1024 -> equal or below the maximum
	# layout(local_size_x = 512, local_size_y = 4, local_size_z = 2) in; is NOT valid -> 512*4*2 = 4096 -> above the maximum
	# As a rule of thumb, if we're dealing with 1D data structures, we might want to keep the workgroup count on one axis. And so on and so forth for other dimensions.
	
	var local_size: int = 128 #the size of the local groups we set in the shader. This is not dynamic and must be hard-coded. Going for 128 on a single axis, because 128 is the maximum amount of threads (invocations) weaker hardware can spawn. Could as well be "x=64, y=2, z=1" or any combination where x*y*z=128 
	var total_groups_x = (mock_num_entities + (local_size - 1)) / local_size #ceil(mock_num_entities/128) -> will spawn a minimum number of threads that is equal to or larger than the number of entities (each thread will receive one dataset, and there is one dataset per mock entity), but also a multiple of 128. This means that there will most likely be SOME threads that are inactive. This could be optimized with some more involved math.
	rd.compute_list_dispatch(compute_list, total_groups_x, 1, 1)
	rd.compute_list_end()
	
	var st: int = Time.get_ticks_msec()
	# Submit to GPU and wait for sync (causes CPU to wait for GPU) - this is where we find out if the calculations we're doing on the GPU are worth the waiting time CPU-side.
	rd.submit()
	rd.sync()
	var et: int = Time.get_ticks_msec()
	print("Compute time: " + str(et - st))
	
	# Read back the data from the buffer we care about. We don't need to unpack the data for the number of entities, we already know them.
	var output_dir_pos_val: PackedByteArray = rd.buffer_get_data(dir_pos_val_buffer)
	
	# Unpack the output
	for i in range(mock_entity_array.size()):
		var dataset_offset = i * STRUCT_SIZE
		
		# Unpack directions
		var dir_x: float = output_dir_pos_val.decode_float(dataset_offset + 0)
		var dir_y: float = output_dir_pos_val.decode_float(dataset_offset + 4)
		var dir_z: float = output_dir_pos_val.decode_float(dataset_offset + 8)
		
		# Unpack value
		var val: float = output_dir_pos_val.decode_float(dataset_offset + 12) # We stored this as the 'w' value of a vec4
		
		# Unpack positions
		var pos_x: float = output_dir_pos_val.decode_float(dataset_offset + 16)
		var pos_y: float = output_dir_pos_val.decode_float(dataset_offset + 20)
		var pos_z: float = output_dir_pos_val.decode_float(dataset_offset + 24)
		# No need to unpack the padding (bytes 25 - 28)
		
		
		# Apply directions to entities
		mock_entity_array[i].mock_direction = Vector3(dir_x, dir_y, dir_z)
		mock_entity_array[i].mock_position = Vector3(pos_x, pos_y, pos_z)
		mock_entity_array[i].mock_value = val
		
	print("Entity " + str(100) + " direction: " + str(mock_entity_array[100].mock_direction))
	print("Entity " + str(100) + " position: " + str(mock_entity_array[100].mock_position))
	print("Entity " + str(100) + " value: " + str(mock_entity_array[100].mock_value))
	print("Workgroups X: " + str(total_groups_x))
	
	#The buffer, pipeline, and uniform_set variables we've been using are each an RID. Because RenderingDevice is meant to be a lower-level API, RIDs aren't freed automatically. This means that once you're done using buffer or any other RID, you are responsible for freeing its memory manually using the RenderingDevice's free_rid() method.

	if rd == null:
		return

	# All resources must be freed after use to avoid memory leaks.
	
	rd.free_rid(dir_pos_val_buffer)
	dir_pos_val_buffer = RID()
	
	rd.free_rid(num_entities_buffer)
	shader = RID()
	
	rd.free_rid(pipeline)
	pipeline = RID()

	rd.free_rid(shader)
	shader = RID()

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

class MockEntity:
	var mock_position: Vector3
	var mock_direction: Vector3
	var mock_value: float
