extends Node


signal update_player_position_for_ropes(pos:Vector2,range:float,force:float)
signal light_map_updated
var sema=Semaphore.new()
var thread:Thread=Thread.new()
const rope_sim_speed:int=30
var half_update_speed:bool=false

var player_:Node=null

var compute_resource:ComputeResource

func _ready():
	var tim=Timer.new()
	tim.wait_time=(1.0/float(rope_sim_speed))
	tim.autostart=true
	add_child(tim)
	tim.timeout.connect(func():
		if len(computing_for)==0:return
		sema.post()
		)
	thread.start(rope_compute)
	
	
	compute_resource=ComputeResource.new(
		false,
		"res://Assets/Resources/compute_rope.glsl"
	)
	initialize_light()







#region rope compute management
var rd := RenderingServer.create_local_rendering_device()
var rope_shader_file := load("res://Assets/Resources/compute_rope.glsl")
var rope_spirv: RDShaderSPIRV = rope_shader_file.get_spirv()
var rope_shader := rd.shader_create_from_spirv(rope_spirv)

var returned_buffer;var rope_buffer;var data_buffer
var pipeline
var forces=PackedByteArray([]);var current_forces_applied:int=0
var do_process:bool=true;var total_segments:int=0


func load_rope_compute(full_rope_count:Array,collision_tex:Image)->void:
	while sema.try_wait():continue
	do_process=false
	computing_for=[]
	# create the processing data arrays
	var input:=PackedByteArray([])
	var data:=PackedByteArray([
	])
	var returned:=PackedByteArray([])
	detail_level=ProjectSettings.get_setting("performance/rope_quality")
	data.append_array(PackedFloat32Array([(2.0/float(rope_sim_speed)),1.0,detail_level,0.0]).to_byte_array())
	data.resize(512)
	current_forces_applied=0
	forces.fill(0)
	
	#var texture_format=compute_resource.replace_format(0,compute_resource.create_texture_format(
		#1,1,1,0,0,0,1,1
	#))
	
	
	var total_p_count=0
	for rope_id in len(full_rope_count):
		var rope_node=full_rope_count[rope_id]
		for point in rope_node.point_count:
			input.append_array(PackedFloat32Array([rope_node.points[point].x+rope_node.position.x*rope_node.global_scale.x,rope_node.points[point].y+rope_node.position.y*rope_node.global_scale.y,rope_node.max_length,0 if rope_node.point_weight[point]==0 else 1 / rope_node.point_weight[point],rope_node.points[point].x+rope_node.position.x*rope_node.global_scale.x,rope_node.points[point].y+rope_node.position.y*rope_node.global_scale.y,rope_id]).to_byte_array())
			returned.append_array(PackedFloat32Array([rope_node.points[point].x+rope_node.position.x*rope_node.global_scale.x,rope_node.points[point].y+rope_node.position.y*rope_node.global_scale.y,]).to_byte_array())
		total_p_count+=rope_node.point_count
	compute_amount=max(total_p_count/32,1)
	total_segments=total_p_count
	if len(input)==0:
		do_process=false;return
	do_process=true
	
	# now use the compute resource to manage it all
	#created buffers and their ids
	var positions_id=compute_resource.replace_buffer(0,compute_resource.create_storage_buffer_filled(len(input),input))
	var data_id=compute_resource.replace_buffer(1,compute_resource.create_storage_buffer_filled(len(data),data))
	var returned_id=compute_resource.replace_buffer(2,compute_resource.create_storage_buffer_filled(len(returned),returned))
	#var image_id=compute_resource.replace_buffer(3,compute_resource.create_texture(texture_format))
	
	#the uniforms
	var position_uniform_id=compute_resource.replace_uniform(0,compute_resource.create_uniform(
		RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,0,[positions_id]))
	var data_uniform_id=compute_resource.replace_uniform(1,compute_resource.create_uniform(
		RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,1,[data_id]))
	var returned_uniform_id=compute_resource.replace_uniform(2,compute_resource.create_uniform(
		RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,2,[returned_id]))
	var uniform_set_id=compute_resource.replace_uniform_set(0,compute_resource.create_uniform_set([
		position_uniform_id,data_uniform_id]))
	var uniform_set_id_out=compute_resource.replace_uniform_set(1,compute_resource.create_uniform_set([
		returned_uniform_id],1))
	var map_size=collision_tex.get_size()
	
	var map_format=compute_resource.replace_format(0,compute_resource.create_texture_format(
		map_size.x,map_size.y,1,RenderingDevice.TEXTURE_USAGE_STORAGE_BIT|RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT|RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT|RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT,
		RenderingDevice.TEXTURE_TYPE_2D,
		RenderingDevice.DATA_FORMAT_R8_UNORM
	)
	)
	
	var b_id=compute_resource.replace_buffer(3,compute_resource.create_texture_filled(map_format,[collision_tex.get_data()]))
	var uni=compute_resource.replace_uniform(3,compute_resource.create_uniform(
		RenderingDevice.UNIFORM_TYPE_IMAGE,0,[b_id]
	))
	compute_resource.replace_uniform_set(2,compute_resource.create_uniform_set(
		[uni],2
	))
	
	
	
	
	
	returned_buffer=returned_id
	data_buffer=data_id
	
	compute_resource.set_thread_dimensions(compute_amount,1,1)
	compute_resource.set_uniform_used_order([uniform_set_id,1,2])
	
	rope_buffer=compute_resource.get_buffer(positions_id)
	computing_for=full_rope_count;computing_for_data=[]
	
	for i in computing_for:computing_for_data.push_back([i.position,i.global_scale])
	compute_rope=true
	#don't process if the performance mode is set to disabled
	do_process=ProjectSettings.get_setting("performance/rope_level",0)!=0
	rope_texture_loaded=false
	
var compute_rope:bool=false
var computing_for:Array=[]
var computing_for_data:Array=[]
var t=0.0
var compute_amount:int=1

func _process(delta):
	if run_light:light_update()
	if len(computing_for)==0:return
	t+=delta



var detail_level:float=0.0
var rope_texture_loaded:bool=false

func rope_compute()->void:
	var is_odd_run=false
	while true:
		sema.wait()
		if !do_process:continue
		var output_bytes := compute_resource.get_buffer_data(returned_buffer)
		var n=PackedFloat32Array([t]).to_byte_array()
		forces.resize(384)
		n.append_array(forces)
		forces.resize(0)
		current_forces_applied=0
		compute_resource.update_buffer(data_buffer,12,len(n),n)
		var constants=PackedByteArray()
		constants.resize(16)
		constants.encode_u32(0,0)
		constants.encode_u32(4,total_segments)
		
		
		compute_resource.set_constants(constants)
		compute_resource.run_compute()
		is_odd_run=!is_odd_run
		if !half_update_speed||is_odd_run:
			var output := output_bytes.to_float32_array()
			var cur_point_id:int=0
			for rope in computing_for:
				for p in rope.get_point_count():
					rope.updated_rope_points[p]=Vector2(
						output[cur_point_id*2],
						output[cur_point_id*2+1]
					)
					cur_point_id+=1
			for i in computing_for:
				i.clamp_rope()
				i.update_line_info.call_deferred()
				i.rope_updated.call_deferred()
#endregion


func rope_repulse_from(rope_pos,rope_range,rope_force)->void:
	if current_forces_applied>=24 or not do_process:return
	forces.append_array(PackedFloat32Array([
		rope_pos.x,rope_pos.y,rope_range,rope_force
	]).to_byte_array()
	)
	current_forces_applied+=1


#region light mapping compute
var light_compute:ComputeResource
var uniform_light_inputs
var light_input
var light_uniforms:Array=[]



func initialize_light()->void:
	light_compute=ComputeResource.new(
		true,
		"res://Assets/Resources/compute_light.glsl"
	)
	create_img()

var light_texture


func update_lighting_map(lightmap_texture:Image)->void:
	run_light=false
	current_shadow_mask_data=lightmap_texture.get_data()
	if light_texture.texture_rd_rid.is_valid():
		light_texture.texture_rd_rid=RID()
	var map_size=lightmap_texture.get_size()
	var map_format=light_compute.replace_format(0,light_compute.create_texture_format(
		map_size.x,map_size.y,1,RenderingDevice.TEXTURE_USAGE_STORAGE_BIT+RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT+RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT+RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT,
		RenderingDevice.TEXTURE_TYPE_2D,
		RenderingDevice.DATA_FORMAT_R8_UNORM
	)
	)
	var light_map_format=light_compute.replace_format(1,light_compute.create_texture_format(
		map_size.x*32,map_size.y*32,1,RenderingDevice.TEXTURE_USAGE_STORAGE_BIT+RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT+RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT+RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT+RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT,
		RenderingDevice.TEXTURE_TYPE_2D,
		RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	)
	)
	
	var map_buffer=light_compute.replace_buffer(
		0,
		light_compute.create_texture_filled(map_format,[lightmap_texture.get_data()])
		)
	
	var v=PackedByteArray()
	v.resize(1792)
	v.fill(0)
	var input_lights=light_compute.replace_buffer(
		1,light_compute.create_storage_buffer_filled(1792,v)
		)
	light_input=input_lights
	
	
	var img=Image.create(map_size.x*32,map_size.y*32,false,Image.FORMAT_RGBA8)
	img.fill(Color(0,0,0,0))
	var pre_filled:PackedByteArray=img.get_data()
	
	var light_map_buffer=light_compute.replace_buffer(
		2,light_compute.create_texture_filled(light_map_format,[pre_filled])
		)
	var light_map_other_buffer=light_compute.replace_buffer(
		3,light_compute.create_texture_filled(light_map_format,[pre_filled])
		)
	var map_uniform=light_compute.replace_uniform(
		0,light_compute.create_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,0,[map_buffer])
		)
	var light_uniform=light_compute.replace_uniform(
		1,light_compute.create_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,0,[light_map_buffer])
		)
	var light_other_uniform=light_compute.replace_uniform(
		2,light_compute.create_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,0,[light_map_other_buffer])
		)
	var light_buff_uni=light_compute.replace_uniform(
		3,light_compute.create_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,0,[input_lights])
		)
	
	var uniform_set=light_compute.replace_uniform_set(
		0,light_compute.create_uniform_set([map_uniform],0)
		)
	var uniform_set_light_a=light_compute.replace_uniform_set(
		1,light_compute.create_uniform_set([light_uniform],1)
		)
	var uniform_set_light_b=light_compute.replace_uniform_set(
		2,light_compute.create_uniform_set([light_other_uniform],1)
		)
	
	
	
	uniform_light_inputs=light_compute.replace_uniform_set(
		3,
		light_compute.create_uniform_set([light_buff_uni],2)
		)
	light_uniforms=[
		uniform_set_light_a,
		uniform_set_light_b,
		uniform_set,
		uniform_light_inputs
	]
	
	light_compute.set_uniform_used_order([uniform_set,uniform_set_light_a,uniform_light_inputs])
	
	#light_compute.set_thread_dimensions(floor(map_size.x),floor(map_size.y))
	light_compute.set_thread_dimensions(40,24)
	#compute_resource.set_thread_dimensions(8,8)
	#update_img()
	var constants=PackedByteArray()
	constants.resize(16)
	if get_viewport().get_camera_2d().has_method("get_constant"):
		light_compute.set_constants(get_viewport().get_camera_2d().get_constant())
	else:
		light_compute.set_constants(constants)
	
	light_compute.run_count=0
	light_compute.run_compute(update_img)
	#light_compute.run_compute(update_img)
	light_map_updated.emit()
	
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	
	run_light=true
	

var run_light:bool=false
var current_shadow_mask_data:PackedByteArray=PackedByteArray([])

func light_update()->void:
	if run_light:
		light_compute.run_compute(update_img)
		if !get_tree().current_scene.get_node("Sprite2D").visible&&light_compute.run_count%2==1:
			get_tree().current_scene.get_node("Sprite2D").set_deferred('visible',true)



func create_img():
	var t:=Texture2DRD.new()
	light_texture=t
	get_tree().current_scene.get_node("Sprite2D").texture=light_texture

func update_img():
	var ord=(light_compute.run_count)%2
	light_compute.set_uniform_used_order([0,ord+1,3])
	light_texture.texture_rd_rid=light_compute.get_buffer(ord+2)


#endregion

