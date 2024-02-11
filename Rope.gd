@tool
extends Line2D
class_name Rope2D

var point_forces:PackedVector2Array
var turbulence_forces:PackedVector2Array
@export var point_count:int=1:
	set(v):
		point_count=v
		if len (point_weight)>point_count:
			point_weight.resize(point_count)
		while len(point_weight)<point_count:
			point_weight.push_back(1)
		reload_rope_init()
@export var max_length:float=16.0:
	set(v):
		max_length=v
		reload_rope_init()

@export var rotation_amount:float=0.0
@export var rope_type:int=0:
	set(v):
		texture=load(rope_mapbuilder.rope_textures[v])
		rope_type=v

@export var point_weight:PackedFloat32Array=[]

@export var attach_on_end:Node2D
@export var offset_from_end:Vector2=Vector2.ZERO

var updated_rope_points:PackedVector2Array=PackedVector2Array([])

var already_changed:bool=false
#updates values when changed to keep synced
func update_line_info():
	points=updated_rope_points



const turbulence_scale:float=16.0
var cur_turbulence:float=0.0

const turbulence_update_rate=0.125

var interaction_level:int=0
var detail_level:float=0.5

func reload_rope_init():
	for point in get_point_count():
		remove_point(0)
	point_forces=PackedVector2Array([])
	point_forces.resize(point_count)
	turbulence_forces=PackedVector2Array([])
	turbulence_forces.resize(point_count)
	var rot_rad=deg_to_rad(rotation_amount)
	for point in point_count:
		add_point(Vector2(0,point*max_length).rotated(rot_rad))
	updated_rope_points=points.duplicate()
	#point_forces.fill(Vector2(1,0))

func clamp_rope()->void:
	for point in range(1,point_count):
		if point_weight[point]==0:continue
		updated_rope_points[point]=updated_rope_points[point-1]+Vector2(-max_length,0).rotated((updated_rope_points[point-1]-updated_rope_points[point]).angle())

func _init():
	add_to_group("COMPUTE_ROPE")

# Called when the node enters the scene tree for the first time.
func _ready():
	interaction_level=ProjectSettings.get_setting("performance/rope_level",0)
	detail_level=max(ProjectSettings.get_setting("performance/rope_quality",0),0.5)
	#ensures has prop weight amount
	if len (point_weight)>point_count:
		point_weight.resize(point_count)
	while len(point_weight)<point_count:
		point_weight.push_back(1)
	
	if !Engine.is_editor_hint():
		#so if it doesnt sim the rope it just makes it 1 segment
		if interaction_level==0:
			max_length*=point_count
			point_count=2
	begin_cap_mode=Line2D.LINE_CAP_ROUND
	texture_mode=Line2D.LINE_TEXTURE_TILE
	end_cap_mode=Line2D.LINE_CAP_ROUND
	reload_rope_init()
	
	if !Engine.is_editor_hint():
		for point in len(points):
			points[point]+=global_position*global_scale
		global_position=Vector2.ZERO
	z_index=-1



#handles special events such as updating anything attached to the rope
func rope_updated()->void:
	if attach_on_end:
		attach_on_end.global_position=global_position+updated_rope_points[point_count-1]*global_scale
		attach_on_end.rotation=(updated_rope_points[point_count-1]-updated_rope_points[point_count-2]).angle()-1.5708
		attach_on_end.global_position+=offset_from_end.rotated(attach_on_end.rotation)
	
